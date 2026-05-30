# frozen_string_literal: true

require "test_helper"

# Integration tests for ReadOnlySandbox — the shared Kobako sandbox builder.
#
# Tests exercise the real Kobako WASM sandbox; they are intentionally
# slower than unit tests and cover the three invariants from docs/architecture.md:
#
#   1. Capability boundary — scripts can only reach EventQuery / MetricQuery;
#      no write path is exposed.
#   2. Shared execution path — the same builder is used for both validation
#      (RunScriptTool) and replay (EndpointReplay).
#   3. Fresh state per invocation — each call() builds a new Kobako::Sandbox
#      so no state leaks across calls.
#
# Kobako error taxonomy tested here:
#   TrapError (+ TimeoutError, MemoryLimitError) — wasm engine layer
#   SandboxError — script error / unrepresentable return value
#   ServiceError — service capability failure not rescued in script
class ReadOnlySandboxTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @sandbox = ReadOnlySandbox.new
  end

  # ---------------------------------------------------------------------------
  # Successful execution
  # ---------------------------------------------------------------------------

  test "call returns ok: true with a representable Integer result" do
    result = @sandbox.call("Service::Events.count")
    assert result[:ok], "expected ok: true, got #{result.inspect}"
    assert_equal 0, result[:result]
  end

  test "call returns ok: true with an Array result from EventQuery" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    result = @sandbox.call("Service::Events.to_a")
    assert result[:ok]
    assert_kind_of Array, result[:result]
    assert_equal 1, result[:result].size
  end

  test "call returns ok: true with MetricQuery total_count" do
    Event.create!(occurred_at: Time.current, name: "ping")
    result = @sandbox.call("Service::Metrics.total_count")
    assert result[:ok]
    assert_equal 1, result[:result]
  end

  test "call returns ok: true with chained EventQuery expression" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")
    result = @sandbox.call('Service::Events.by_name("page_view").count')
    assert result[:ok]
    assert_equal 1, result[:result]
  end

  test "call returns ok: true with MetricQuery top_names" do
    3.times { Event.create!(occurred_at: Time.current, name: "page_view") }
    result = @sandbox.call("Service::Metrics.top_names(limit: 1)")
    assert result[:ok]
    assert_equal [ [ "page_view", 3 ] ], result[:result]
  end

  # ---------------------------------------------------------------------------
  # Structured error — SandboxError (script error / unrepresentable value)
  # ---------------------------------------------------------------------------

  test "call returns ok: false with error hash on syntax error" do
    result = @sandbox.call("def foo(")
    refute result[:ok], "expected ok: false for syntax error"
    assert result[:error].is_a?(Hash), "expected :error to be a Hash"
    assert_equal "SandboxError", result[:error][:type]
    assert result[:error][:message].is_a?(String)
  end

  test "call returns ok: false with error hash on runtime NameError" do
    result = @sandbox.call("UndefinedConstant.call")
    refute result[:ok]
    assert_equal "SandboxError", result[:error][:type]
  end

  test "call returns ok: false when script returns an unrepresentable value" do
    # An mruby object that is not in the MessagePack closed set is unrepresentable.
    # Kobako 0.6.0+ rejects unrepresentable values as SandboxError instead of
    # stringifying — the result is a structured error (error-as-feedback).
    result = @sandbox.call("Object.new")
    refute result[:ok]
    assert_equal "SandboxError", result[:error][:type]
  end

  # ---------------------------------------------------------------------------
  # Structured error — TrapError subtypes
  # ---------------------------------------------------------------------------

  test "call returns ok: false with TimeoutError type on timeout" do
    # Use a very short timeout to trigger TimeoutError reliably.
    sandbox = ReadOnlySandbox.new(timeout: 0.001)
    result = sandbox.call("i = 0; loop { i += 1 }")
    refute result[:ok]
    assert_equal "TimeoutError", result[:error][:type]
  end

  # ---------------------------------------------------------------------------
  # Capability boundary — no write path exposed (invariant 1)
  # ---------------------------------------------------------------------------

  test "script cannot call Event.create! — constant not accessible" do
    # The sandbox has no access to AR models; attempting to call Event.create!
    # raises NameError inside the sandbox (SandboxError to the host).
    result = @sandbox.call('Event.create!(occurred_at: Time.now, name: "injected")')
    refute result[:ok], "expected script to fail; no AR models in sandbox scope"
    assert_equal 0, Event.count, "no events should have been created"
  end

  test "script cannot call ApplicationRecord — constant not accessible" do
    result = @sandbox.call("ApplicationRecord.connection.execute('SELECT 1')")
    refute result[:ok]
  end

  test "script cannot require files" do
    result = @sandbox.call("require 'open3'")
    refute result[:ok]
  end

  # ---------------------------------------------------------------------------
  # Fresh state per invocation (invariant 3)
  # ---------------------------------------------------------------------------

  test "two successive calls on the same builder each use a fresh sandbox" do
    # Define a local in the first call; a second call must not see it.
    @sandbox.call("x = 42")
    result = @sandbox.call("x")    # x is not defined in the second fresh sandbox
    refute result[:ok], "expected NameError because x is not defined in a fresh sandbox"
  end

  test "builder is reusable after a failed script" do
    failed = @sandbox.call("raise 'boom'")
    refute failed[:ok]

    success = @sandbox.call("1 + 1")
    assert success[:ok]
    assert_equal 2, success[:result]
  end

  test "builder is reusable after a TimeoutError" do
    sandbox = ReadOnlySandbox.new(timeout: 0.001)
    sandbox.call("loop { }")   # trigger TimeoutError; discard sandbox internally
    success = sandbox.call("2 + 2")
    assert success[:ok]
    assert_equal 4, success[:result]
  end

  # ---------------------------------------------------------------------------
  # Result interface contract (#6 / #9 compatibility)
  # ---------------------------------------------------------------------------

  test "successful result Hash has :ok and :result keys" do
    result = @sandbox.call("42")
    assert result.key?(:ok)
    assert result.key?(:result)
    refute result.key?(:error)
  end

  test "error result Hash has :ok and :error keys" do
    result = @sandbox.call("raise 'oops'")
    assert result.key?(:ok)
    assert result.key?(:error)
    refute result.key?(:result)
  end

  test "error hash contains :type and :message" do
    result = @sandbox.call("raise 'oops'")
    assert result[:error].key?(:type)
    assert result[:error].key?(:message)
  end

  test "SandboxError surfaces the guest panic envelope under :details" do
    # A script raise produces a structured panic envelope carrying the mruby
    # class — #6 feeds this back to the LLM for self-correction.
    result = @sandbox.call("raise 'oops'")
    refute result[:ok]
    assert result[:error].key?(:details), "expected structured :details for SandboxError"
    assert_kind_of Hash, result[:error][:details]
    assert result[:error][:details].key?(:klass), "expected mruby :klass in details"
  end

  # ---------------------------------------------------------------------------
  # params: keyword — validate_params gate and Service::Params in-script access
  # ---------------------------------------------------------------------------

  test "call with valid params makes value accessible via Service::Params.fetch in script" do
    result = @sandbox.call('Service::Params.fetch("key")', params: { "key" => "value" })
    assert result[:ok], "expected ok: true, got #{result.inspect}"
    assert_equal "value", result[:result]
  end

  test "call with valid Integer param returns Integer from Service::Params.fetch" do
    result = @sandbox.call('Service::Params.fetch("limit")', params: { "limit" => 5 })
    assert result[:ok]
    assert_equal 5, result[:result]
  end

  test "call with absent param key returns nil from Service::Params.fetch" do
    result = @sandbox.call('Service::Params.fetch("missing")', params: {})
    assert result[:ok]
    assert_nil result[:result]
  end

  test "call with non-Hash params returns InvalidParamsError result" do
    result = @sandbox.call("1 + 1", params: "not_a_hash")
    refute result[:ok]
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "call with non-String key returns InvalidParamsError result" do
    result = @sandbox.call("1 + 1", params: { 42 => "v" })
    refute result[:ok]
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "call with disallowed value type returns InvalidParamsError result" do
    result = @sandbox.call("1 + 1", params: { "k" => Object.new })
    refute result[:ok]
    assert_equal "InvalidParamsError", result[:error][:type]
  end

  test "call with empty params: {} succeeds and Service::Params.fetch returns nil" do
    result = @sandbox.call('Service::Params.fetch("x")', params: {})
    assert result[:ok]
    assert_nil result[:result]
  end

  test "InvalidParamsError result never enters the sandbox — script is never executed" do
    # If the sandbox were entered, Service::Events.count would execute and the
    # result would have :result.  Instead, validate_params short-circuits before
    # build_sandbox, so no :result key appears.
    result = @sandbox.call("Service::Events.count", params: "bad")
    refute result[:ok]
    refute result.key?(:result), "script must not have run when params are invalid"
  end

  # ---------------------------------------------------------------------------
  # Default options
  # ---------------------------------------------------------------------------

  test "default timeout is 5 seconds" do
    assert_equal 5.0, ReadOnlySandbox::DEFAULT_TIMEOUT
  end

  test "default memory_limit is 16 MiB" do
    assert_equal 16 * 1024 * 1024, ReadOnlySandbox::DEFAULT_MEMORY_LIMIT
  end
end
