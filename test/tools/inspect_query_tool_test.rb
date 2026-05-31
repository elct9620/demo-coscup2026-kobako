# frozen_string_literal: true

require "test_helper"

# Tests for InspectQueryTool — the exploration half of the two-tool generation
# loop.  Its defining property: it returns the script's raw value WITHOUT the
# response-envelope guardrail, so the agent can inspect data freely.
#
# Uses the real Kobako sandbox (via ScriptRunner) to verify the contract the LLM
# actually sees.
class InspectQueryToolTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @tool = InspectQueryTool.new
  end

  # ---------------------------------------------------------------------------
  # RubyLLM::Tool contract
  # ---------------------------------------------------------------------------

  test "inherits from RubyLLM::Tool" do
    assert_kind_of RubyLLM::Tool, @tool
  end

  test "is named inspect_query for the LLM tool-calling API" do
    assert_equal "inspect_query", @tool.name
  end

  test "declares a required :script parameter" do
    param = @tool.parameters[:script]
    assert param, "expected a :script parameter"
    assert param.required, "expected :script to be required"
  end

  # ---------------------------------------------------------------------------
  # Exploration: a bare value comes straight back — NO envelope required.
  # This is the whole point of the tool; it is what SubmitEndpointTool refuses.
  # ---------------------------------------------------------------------------

  test "returns a bare scalar without requiring the response envelope" do
    result = @tool.execute(script: "1 + 1")

    assert_equal true, result[:success], "exploration must accept a bare value"
    assert_equal 2, result[:result]
    assert_nil result[:error_type], "a bare value is not a SchemaError here"
  end

  test "lets the agent peek at a raw count to rule out data problems" do
    result = @tool.execute(script: "Service::Events.count")

    assert result[:success]
    assert_equal 0, result[:result], "the agent must SEE the value, not a hidden SchemaError"
  end

  test "returns a raw Array of rows from to_a" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    result = @tool.execute(script: "Service::Events.to_a")

    assert result[:success]
    assert_equal 1, result[:result].length
    assert_equal "page_view", result[:result].first["name"]
  end

  # ---------------------------------------------------------------------------
  # Errors still flow back as structured feedback (same error-as-feedback loop).
  # ---------------------------------------------------------------------------

  test "returns structured failure on a runtime error" do
    result = @tool.execute(script: "raise 'boom'")

    assert_equal false, result[:success]
    assert_match(/Error/, result[:error_type])
    assert result[:error].present?
  end

  test "rejects a write attempt via the read-only sandbox" do
    result = @tool.execute(script: 'Event.create!(occurred_at: Time.now, name: "injected")')

    assert_equal false, result[:success], "write attempt must be rejected by the sandbox"
    assert_equal 0, Event.count
  end
end
