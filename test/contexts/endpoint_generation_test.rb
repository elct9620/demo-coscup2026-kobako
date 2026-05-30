# frozen_string_literal: true

require "test_helper"

# Unit tests for EndpointGeneration context — the DCI orchestrator that drives
# the EndpointBuilderAgent error-as-feedback loop and persists a validated script
# as an Endpoint on success.
#
# Mock strategy:
#   EndpointGeneration.new(requirement, agent:) accepts an optional injected
#   agent.  Tests pass a FakeAgent that simulates the two outcomes without
#   hitting a real LMStudio instance:
#
#   1. FakeSuccessAgent#ask — injects a synthetic message history into its own
#      in-memory RubyLLM::Chat (assistant tool_call + tool result success:true),
#      then returns the final assistant message.  EndpointGeneration finds the
#      last success result, extracts the script, and creates an Endpoint.
#
#   2. FakeFailureAgent#ask — raises EndpointBuilderAgent::IterationLimitError.
#      EndpointGeneration rescues, returns { ok: false, error: ... }, and does
#      NOT create any Endpoint.
#
# The real LLM end-to-end round-trip is deferred to test item #14.
class EndpointGenerationTest < ActiveSupport::TestCase
  VALIDATED_SCRIPT = "Service::Events.all.count"

  # ---------------------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------------------

  test "returns ok:true with endpoint when agent validates a script" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:ok], "result must be ok:true on success"
    assert_not_nil result[:endpoint], "result must contain the endpoint record"
    assert_instance_of Endpoint, result[:endpoint]
    assert result[:endpoint].persisted?, "endpoint must be persisted"
    assert_equal VALIDATED_SCRIPT, result[:endpoint].script
  end

  test "creates exactly one Endpoint record on success" do
    assert_difference "Endpoint.count", 1 do
      EndpointGeneration.new("count all events", agent: fake_success_agent).call
    end
  end

  test "persisted endpoint has a generated slug" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:endpoint].slug.present?, "slug must be auto-generated"
  end

  test "persisted endpoint status is active" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:endpoint].active?
  end

  # ---------------------------------------------------------------------------
  # Failure path — IterationLimitError
  # ---------------------------------------------------------------------------

  test "returns ok:false when agent raises IterationLimitError" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert_not result[:ok], "result must be ok:false when iteration limit is hit"
  end

  test "does not create an Endpoint when agent raises IterationLimitError" do
    assert_no_difference "Endpoint.count" do
      EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call
    end
  end

  test "failure result contains an error message" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert result[:error].present?, "failure result must include an error message"
  end

  test "does not raise IterationLimitError to the caller" do
    assert_nothing_raised do
      EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call
    end
  end

  # ---------------------------------------------------------------------------
  # Interface contract
  # ---------------------------------------------------------------------------

  test "success result contains :ok key set to true" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result.key?(:ok)
    assert result[:ok]
  end

  test "failure result contains :ok and :error keys" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert result.key?(:ok)
    assert result.key?(:error)
    assert_not result[:ok]
  end

  private

  # Returns a fake agent whose #ask method injects a synthetic, successful
  # message history into its own in-memory RubyLLM::Chat, simulating:
  #
  #   1. assistant message with tool_calls: { id => ToolCall(run_script_tool, {script:}) }
  #   2. tool   message with content: "{success: true, result: 42}"  (Ruby 3.4+ Hash#to_s),
  #              tool_call_id: <same id>
  #   3. assistant message (final confirmation, no tool_calls)
  #
  # EndpointGeneration scans backwards for the last :tool message whose content
  # parses to success:true, then reads the script from the matching assistant
  # tool_call arguments.
  def fake_success_agent
    FakeSuccessAgent.new(VALIDATED_SCRIPT)
  end

  def fake_failure_agent
    FakeFailureAgent.new
  end

  # ---------------------------------------------------------------------------
  # Fake agent helpers
  # ---------------------------------------------------------------------------

  # Minimal duck-type of EndpointBuilderAgent that exposes #ask and #chat.
  # Uses a real RubyLLM::Chat in-memory (no model resolution needed) so that
  # EndpointGeneration can walk messages just as it would with the real agent.
  class FakeSuccessAgent
    attr_reader :chat

    def initialize(validated_script)
      @validated_script = validated_script
      @chat = RubyLLM::Chat.new(model: "gpt-4o-mini")
    end

    def ask(_requirement)
      tool_call_id = "call_test_#{SecureRandom.hex(4)}"
      tool_call = RubyLLM::ToolCall.new(
        id: tool_call_id,
        name: "run_script_tool",
        arguments: { script: @validated_script }
      )

      # 1. Assistant message that requested the tool call
      @chat.add_message(
        RubyLLM::Message.new(
          role: :assistant,
          content: nil,
          tool_calls: { tool_call_id.to_sym => tool_call }
        )
      )

      # 2. Tool result message with success: true
      @chat.add_message(
        RubyLLM::Message.new(
          role: :tool,
          content: { success: true, result: 42 }.to_s,
          tool_call_id: tool_call_id
        )
      )

      # 3. Final assistant confirmation
      final = RubyLLM::Message.new(role: :assistant, content: "Script validated successfully.")
      @chat.add_message(final)
      final
    end
  end

  # Simulates exhaustion of MAX_ITERATIONS: ask() raises IterationLimitError.
  class FakeFailureAgent
    attr_reader :chat

    def initialize
      messages = []
      @chat = Object.new.tap { |c| c.define_singleton_method(:messages) { messages } }
    end

    def ask(_requirement)
      raise EndpointBuilderAgent::IterationLimitError,
            "Stopped after #{EndpointBuilderAgent::MAX_ITERATIONS} iterations without success."
    end
  end
end
