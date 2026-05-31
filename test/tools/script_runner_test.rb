# frozen_string_literal: true

require "test_helper"

# Tests for ScriptRunner — the shared sandbox-execution step behind the agent's
# tools.  It runs an LLM-generated script in the real Kobako sandbox and shapes
# the outcome into the LLM tool-result contract:
#
#   Success: { success: true,  result: <value> }
#   Failure: { success: false, error: String, error_type: String, details: Hash? }
#
# Unlike SubmitEndpointTool, ScriptRunner does NOT enforce the response envelope
# — it returns whatever wire-representable value the script produced, including a
# bare scalar.  That is what lets InspectQueryTool offer free exploration.
class ScriptRunnerTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @runner = ScriptRunner.new
  end

  test "returns success with the raw value for a bare scalar (no envelope required)" do
    result = @runner.call("1 + 1")

    assert_equal true, result[:success]
    assert_equal 2, result[:result]
  end

  test "exposes Service queries and returns their raw value" do
    3.times { Event.create!(occurred_at: Time.current, name: "click") }
    result = @runner.call("Service::Metrics.total_count")

    assert result[:success]
    assert_equal 3, result[:result]
  end

  test "returns a structured failure with error_type on a runtime error" do
    result = @runner.call("raise 'boom'")

    assert_equal false, result[:success]
    assert_match(/Error/, result[:error_type])
    assert result[:error].present?
  end

  test "includes mruby details for SandboxError so the LLM can self-correct" do
    result = @runner.call("raise 'oops'")

    assert result[:details], "expected :details for SandboxError"
    assert result[:details][:klass].present?, "expected mruby :klass in details"
  end

  test "rejects a write attempt via the read-only sandbox" do
    result = @runner.call('Event.create!(occurred_at: Time.now, name: "injected")')

    assert_equal false, result[:success], "write attempt must be rejected by the sandbox"
    assert_equal 0, Event.count
  end
end
