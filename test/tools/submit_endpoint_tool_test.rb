# frozen_string_literal: true

require "test_helper"

# Tests for SubmitEndpointTool — the commit half of the two-tool generation loop.
# It enforces the response envelope and captures the validated script as the
# endpoint candidate.
#
# Uses the real Kobako sandbox (via ScriptRunner) to verify the contract the LLM
# sees, plus the capture behavior EndpointGeneration depends on.
class SubmitEndpointToolTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @tool = SubmitEndpointTool.new
  end

  # ---------------------------------------------------------------------------
  # RubyLLM::Tool contract
  # ---------------------------------------------------------------------------

  test "inherits from RubyLLM::Tool" do
    assert_kind_of RubyLLM::Tool, @tool
  end

  test "is named submit_endpoint for the LLM tool-calling API" do
    assert_equal "submit_endpoint", @tool.name
  end

  test "declares a required :script parameter" do
    param = @tool.parameters[:script]
    assert param, "expected a :script parameter"
    assert param.required, "expected :script to be required"
  end

  # ---------------------------------------------------------------------------
  # Envelope guardrail — a bare value is rejected; a conforming envelope passes.
  # ---------------------------------------------------------------------------

  test "accepts a conforming envelope and returns the value" do
    result = @tool.execute(script: '{ "data" => 1 + 1, "meta" => {} }')

    assert_equal true, result[:success]
    assert_equal({ "data" => 2, "meta" => {} }, result[:result])
  end

  test "rejects a bare scalar as a SchemaError" do
    result = @tool.execute(script: "1 + 1")

    assert_equal false, result[:success], "bare scalar must not pass the envelope guardrail"
    assert_equal "SchemaError", result[:error_type]
    assert result[:error].present?, "expected a fix-oriented schema error message"
  end

  test "rejects an envelope missing the meta key" do
    result = @tool.execute(script: '{ "data" => 1 }')

    assert_equal false, result[:success]
    assert_equal "SchemaError", result[:error_type]
    assert_match(/meta/, result[:error])
  end

  test "passes a runtime error back as structured feedback" do
    result = @tool.execute(script: "raise 'boom'")

    assert_equal false, result[:success]
    assert_match(/Error/, result[:error_type])
  end

  # ---------------------------------------------------------------------------
  # Capture — the mechanism EndpointGeneration uses to find the final script.
  # ---------------------------------------------------------------------------

  test "captured_script is nil before any submission" do
    assert_nil @tool.captured_script
  end

  test "captures the script after a successful submission" do
    script = '{ "data" => Service::Events.count, "meta" => {} }'
    @tool.execute(script: script)

    assert_equal script, @tool.captured_script
  end

  test "does NOT capture a script that fails the envelope guardrail" do
    @tool.execute(script: "42")

    assert_nil @tool.captured_script, "a SchemaError submission must not be captured"
  end

  test "does NOT capture a script that errors in the sandbox" do
    @tool.execute(script: "raise 'boom'")

    assert_nil @tool.captured_script, "a failed run must not be captured"
  end

  test "the last successful submission wins when several succeed" do
    @tool.execute(script: '{ "data" => 1, "meta" => {} }')
    @tool.execute(script: '{ "data" => 2, "meta" => {} }')

    assert_equal '{ "data" => 2, "meta" => {} }', @tool.captured_script,
                 "captured_script must reflect the last script that passed"
  end

  test "a later failed submission does not overwrite an earlier captured script" do
    good = '{ "data" => 1, "meta" => {} }'
    @tool.execute(script: good)
    @tool.execute(script: "999") # bare scalar → SchemaError

    assert_equal good, @tool.captured_script,
                 "a failed submission must leave the last valid capture intact"
  end
end
