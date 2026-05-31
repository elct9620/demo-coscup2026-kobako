# frozen_string_literal: true

require "test_helper"

# Integration tests for EndpointReplay context.
#
# These tests exercise the real Kobako WASM sandbox (no mocks) to verify:
#
#   1. Happy path — replay returns JSON-serializable result using Service + params.
#   2. Error isolation — sandbox errors return structured error, never raise.
#   3. Invalid params — non-string keys/values return structured error, no DB access.
#   4. Fresh state — each replay uses a new sandbox; no state leaks between calls.
#   5. Shared execution path — EndpointReplay uses the same ReadOnlySandbox as submit_endpoint.
#
# Interface under test:
#   EndpointReplay.new(endpoint, params).call
#   => { ok: true,  result: <wire-representable value> }
#   => { ok: false, error: { type:, message: } }
class EndpointReplayTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @endpoint = Endpoint.create!(script: "Service::Events.count")
  end

  # ---------------------------------------------------------------------------
  # Happy path — plain script (no params)
  # ---------------------------------------------------------------------------

  test "replays a script and returns ok: true with the result" do
    result = EndpointReplay.new(@endpoint, {}).call

    assert result[:ok], "expected ok: true, got #{result.inspect}"
    assert_equal 0, result[:result]
  end

  test "result reflects current database state at replay time" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    result = EndpointReplay.new(@endpoint, {}).call

    assert result[:ok]
    assert_equal 1, result[:result]
  end

  # ---------------------------------------------------------------------------
  # Query parameter injection — Service::Params
  # ---------------------------------------------------------------------------

  test "script can access query params via Service::Params.fetch" do
    endpoint = Endpoint.create!(script: 'Service::Params.fetch("name")')

    result = EndpointReplay.new(endpoint, { "name" => "page_view" }).call

    assert result[:ok], "expected ok: true, got #{result.inspect}"
    assert_equal "page_view", result[:result]
  end

  test "script can use params to filter EventQuery" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")

    endpoint = Endpoint.create!(
      script: 'Service::Events.by_name(Service::Params.fetch("name")).count'
    )

    result = EndpointReplay.new(endpoint, { "name" => "page_view" }).call

    assert result[:ok], "expected ok: true, got #{result.inspect}"
    assert_equal 1, result[:result]
  end

  test "Service::Params.fetch returns nil for a missing key" do
    endpoint = Endpoint.create!(script: 'Service::Params.fetch("missing_key")')

    result = EndpointReplay.new(endpoint, {}).call

    assert result[:ok], "expected ok: true for missing key (returns nil), got #{result.inspect}"
    assert_nil result[:result]
  end

  test "multiple params are independently accessible" do
    endpoint = Endpoint.create!(
      script: '[Service::Params.fetch("a"), Service::Params.fetch("b")]'
    )

    result = EndpointReplay.new(endpoint, { "a" => "hello", "b" => "world" }).call

    assert result[:ok]
    assert_equal %w[hello world], result[:result]
  end

  # ---------------------------------------------------------------------------
  # Invalid / untrusted params — structured error, no crash
  # ---------------------------------------------------------------------------

  test "non-string key in params returns structured error" do
    result = EndpointReplay.new(@endpoint, { 42 => "value" }).call

    refute result[:ok], "expected ok: false for non-string key"
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "non-string value in params returns structured error" do
    result = EndpointReplay.new(@endpoint, { "key" => Object.new }).call

    refute result[:ok], "expected ok: false for non-string value"
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "params that is not a Hash returns structured error" do
    result = EndpointReplay.new(@endpoint, "not_a_hash").call

    refute result[:ok], "expected ok: false for non-Hash params"
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "integer value in params is accepted (wire-representable)" do
    endpoint = Endpoint.create!(script: 'Service::Params.fetch("limit")')

    result = EndpointReplay.new(endpoint, { "limit" => 10 }).call

    assert result[:ok], "Integer values are wire-representable and must be accepted"
    assert_equal 10, result[:result]
  end

  # ---------------------------------------------------------------------------
  # Error isolation — sandbox errors return structured error
  # ---------------------------------------------------------------------------

  test "script syntax error returns ok: false with structured error" do
    endpoint = Endpoint.create!(script: "def foo(")

    result = EndpointReplay.new(endpoint, {}).call

    refute result[:ok]
    assert_equal "SandboxError", result[:error][:type]
  end

  test "script runtime error returns ok: false with structured error" do
    endpoint = Endpoint.create!(script: "raise 'boom'")

    result = EndpointReplay.new(endpoint, {}).call

    refute result[:ok]
    assert_equal "SandboxError", result[:error][:type]
  end

  test "sandbox error does not raise — caller always receives structured result" do
    endpoint = Endpoint.create!(script: "raise 'crash'")

    assert_nothing_raised do
      EndpointReplay.new(endpoint, {}).call
    end
  end

  test "timeout returns ok: false with TimeoutError type" do
    endpoint = Endpoint.create!(script: "loop { }")
    replay   = EndpointReplay.new(endpoint, {}, timeout: 0.001)

    result = replay.call

    refute result[:ok]
    assert_equal "TimeoutError", result[:error][:type]
  end

  # ---------------------------------------------------------------------------
  # Fresh state per invocation (invariant)
  # ---------------------------------------------------------------------------

  test "each replay uses a fresh sandbox — no state leaks between calls" do
    endpoint_a = Endpoint.create!(script: "x = 42")
    endpoint_b = Endpoint.create!(script: "x")

    EndpointReplay.new(endpoint_a, {}).call
    result = EndpointReplay.new(endpoint_b, {}).call

    refute result[:ok], "x must not be defined in a separate replay invocation"
  end

  test "a failed replay does not affect a subsequent successful replay" do
    failing  = Endpoint.create!(script: "raise 'first'")
    passing  = Endpoint.create!(script: "1 + 1")

    EndpointReplay.new(failing, {}).call
    result = EndpointReplay.new(passing, {}).call

    assert result[:ok]
    assert_equal 2, result[:result]
  end

  # ---------------------------------------------------------------------------
  # Shared execution path — same ReadOnlySandbox as submit_endpoint (invariant)
  # ---------------------------------------------------------------------------

  test "replay of a submit_endpoint-validated script produces the same result" do
    # Simulate what submit_endpoint does: run the same script through ReadOnlySandbox.
    script   = "Service::Events.count"
    endpoint = Endpoint.create!(script: script)

    sandbox_result = ReadOnlySandbox.new.call(script)
    replay_result  = EndpointReplay.new(endpoint, {}).call

    assert sandbox_result[:ok]
    assert replay_result[:ok]
    assert_equal sandbox_result[:result], replay_result[:result],
                 "ReadOnlySandbox and EndpointReplay must produce identical results (驗證即上線)"
  end

  # ---------------------------------------------------------------------------
  # Result interface contract
  # ---------------------------------------------------------------------------

  test "success result has :ok and :result keys" do
    result = EndpointReplay.new(@endpoint, {}).call

    assert result.key?(:ok)
    assert result.key?(:result)
    refute result.key?(:error)
  end

  test "error result has :ok and :error keys" do
    endpoint = Endpoint.create!(script: "raise 'oops'")

    result = EndpointReplay.new(endpoint, {}).call

    assert result.key?(:ok)
    assert result.key?(:error)
    refute result.key?(:result)
  end

  test "error hash contains :type and :message" do
    endpoint = Endpoint.create!(script: "raise 'oops'")

    result = EndpointReplay.new(endpoint, {}).call

    assert result[:error].key?(:type)
    assert result[:error].key?(:message)
  end
end
