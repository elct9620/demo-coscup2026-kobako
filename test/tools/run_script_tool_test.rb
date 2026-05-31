# frozen_string_literal: true

require "test_helper"

# Integration tests for RunScriptTool — the RubyLLM::Tool that bridges the
# LLM agent and the ReadOnlySandbox.
#
# These tests use the real Kobako WASM sandbox (same as ReadOnlySandboxTest)
# to verify the error-as-feedback contract from docs/architecture.md:
#
#   • Success path  — execute returns a hash the LLM can read as confirmation.
#   • Failure path  — execute returns a hash with structured error details that
#                     give the LLM enough context to self-correct the script.
#
# Shared execution path invariant: RunScriptTool delegates to ReadOnlySandbox,
# so the same execution path used during validation also serves live replay.
class RunScriptToolTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @tool = RunScriptTool.new
  end

  # ---------------------------------------------------------------------------
  # RubyLLM::Tool contract
  # ---------------------------------------------------------------------------

  test "inherits from RubyLLM::Tool" do
    assert_kind_of RubyLLM::Tool, @tool
  end

  test "has a non-empty description" do
    assert @tool.description.present?
  end

  test "declares a required :script parameter" do
    param = @tool.parameters[:script]
    assert param, "expected a :script parameter"
    assert param.required, "expected :script to be required"
  end

  # ---------------------------------------------------------------------------
  # Success path — LLM learns the script worked and sees the return value.
  # Scripts must return the standard { "data" => ..., "meta" => {} } envelope
  # (enforced by ResponseSchema); see the guardrail section below.
  # ---------------------------------------------------------------------------

  test "execute returns success hash when script returns a valid envelope" do
    result = @tool.execute(script: '{ "data" => 1 + 1, "meta" => {} }')

    assert_equal true, result[:success]
    assert_equal({ "data" => 2, "meta" => {} }, result[:result])
  end

  test "execute exposes Service::Events.count to the LLM inside the envelope" do
    result = @tool.execute(script: '{ "data" => Service::Events.count, "meta" => {} }')

    assert result[:success]
    assert_equal 0, result[:result]["data"]
  end

  test "execute returns a non-nil result for valid chained EventQuery" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    result = @tool.execute(script: '{ "data" => Service::Events.by_name("page_view").count, "meta" => {} }')

    assert result[:success]
    assert_equal 1, result[:result]["data"]
  end

  test "execute returns success with MetricQuery result" do
    3.times { Event.create!(occurred_at: Time.current, name: "click") }
    result = @tool.execute(script: '{ "data" => Service::Metrics.total_count, "meta" => {} }')

    assert result[:success]
    assert_equal 3, result[:result]["data"]
  end

  # ---------------------------------------------------------------------------
  # Schema guardrail — a script that runs cleanly but returns a non-conforming
  # shape is reported back as a SchemaError so the LLM self-corrects, exactly
  # as it would for a runtime error (error-as-feedback).
  # ---------------------------------------------------------------------------

  test "execute returns SchemaError when a clean script returns a bare scalar" do
    result = @tool.execute(script: "1 + 1")

    assert_equal false, result[:success], "bare scalar must not pass the envelope guardrail"
    assert_equal "SchemaError", result[:error_type]
    assert result[:error].present?, "expected a fix-oriented schema error message for the LLM"
  end

  test "execute returns SchemaError when the envelope is missing the meta key" do
    result = @tool.execute(script: '{ "data" => 1 }')

    assert_equal false, result[:success]
    assert_equal "SchemaError", result[:error_type]
    assert_match(/meta/, result[:error])
  end

  test "execute accepts an envelope with a populated meta block" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    script = '{ "data" => Service::Events.count, "meta" => { "event" => "page_view" } }'
    result = @tool.execute(script: script)

    assert result[:success]
    assert_equal 1, result[:result]["data"]
    assert_equal "page_view", result[:result]["meta"]["event"]
  end

  # ---------------------------------------------------------------------------
  # Failure path — error-as-feedback: LLM receives actionable structured error
  # ---------------------------------------------------------------------------

  test "execute returns failure hash on syntax error" do
    result = @tool.execute(script: "def bad(")

    assert_equal false, result[:success]
    assert result[:error].present?
  end

  test "execute includes error type in failure result" do
    result = @tool.execute(script: "UndefinedConst.call")

    assert_equal false, result[:success]
    assert_match(/Error/, result[:error_type])
  end

  test "execute includes error message in failure result" do
    result = @tool.execute(script: "raise 'intentional error for test'")

    assert_equal false, result[:success]
    assert result[:error].is_a?(String)
    assert result[:error].present?
  end

  test "execute includes mruby class in failure details for LLM self-correction" do
    # raise produces a SandboxError — structured_details always populates :details
    # with the guest panic envelope, including mruby klass for self-correction.
    result = @tool.execute(script: "raise 'oops'")

    assert_equal false, result[:success]
    assert result[:details], "expected :details for SandboxError (raise produces structured panic envelope)"
    assert result[:details][:klass].present?, "expected mruby :klass in details"
  end

  test "execute includes backtrace_lines in failure details for SandboxError" do
    result = @tool.execute(script: "raise 'boom'")

    assert_equal false, result[:success]
    assert result[:details], "expected :details for SandboxError"
    assert result[:details].key?(:backtrace_lines), "expected :backtrace_lines in details"
  end

  test "execute returns structured error on unrepresentable return value" do
    # Object.new is not MessagePack-serializable; treated as SandboxError.
    result = @tool.execute(script: "Object.new")

    assert_equal false, result[:success]
    assert result[:error].present?
  end

  # ---------------------------------------------------------------------------
  # Timeout — LLM learns the script ran too long
  # ---------------------------------------------------------------------------

  test "execute returns failure on sandbox timeout" do
    tool = RunScriptTool.new(timeout: 0.001)
    result = tool.execute(script: "loop { }")

    assert_equal false, result[:success]
    assert_match(/Timeout/, result[:error_type])
  end

  # ---------------------------------------------------------------------------
  # Shared execution path (docs/architecture.md Patterns)
  # ---------------------------------------------------------------------------

  test "execute uses ReadOnlySandbox internally" do
    # Verify delegation: same sandbox that read_only_sandbox_test exercises.
    # A script that writes must fail, not silently succeed.
    result = @tool.execute(script: 'Event.create!(occurred_at: Time.now, name: "injected")')

    assert_equal false, result[:success], "write attempt must be rejected by the sandbox"
    assert_equal 0, Event.count, "no events should have been created"
  end

  # ---------------------------------------------------------------------------
  # Tool result shape is self-consistent
  # ---------------------------------------------------------------------------

  test "success result has :success true and :result key" do
    result = @tool.execute(script: '{ "data" => 42, "meta" => {} }')
    assert result.key?(:success)
    assert result[:success]
    assert result.key?(:result)
    refute result.key?(:error)
  end

  test "failure result has :success false, :error, and :error_type keys" do
    result = @tool.execute(script: "raise 'fail'")
    assert result.key?(:success)
    refute result[:success]
    assert result.key?(:error),      "expected :error key in failure result"
    assert result.key?(:error_type), "expected :error_type key in failure result"
    refute result.key?(:result)
  end
end
