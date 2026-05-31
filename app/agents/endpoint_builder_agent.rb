# frozen_string_literal: true

# RubyLLM::Agent that drives the error-as-feedback self-correction loop
# (docs/architecture.md — "error-as-feedback 自我驗證迴圈" pattern).
#
# The agent receives a natural-language requirement from the operator, then
# iterates in Code Mode with two tools:
#
#   1. Explore with inspect_query (InspectQueryTool) — run scripts to inspect the
#      data and rule out query problems; raw values come back, no envelope needed.
#   2. Commit with submit_endpoint (SubmitEndpointTool) — submit the final script;
#      it is validated against the response envelope and, on success, captured as
#      the endpoint candidate.
#   3. Sandbox/schema errors from either tool are fed back as the tool result and
#      the LLM self-corrects in the next turn.
#
# "Which script is the final one" is answered by SubmitEndpointTool#captured_script
# (exposed via #submit_tool), not by scanning the chat history — see
# EndpointGeneration (#8).
#
# Iteration cap (SPEC "有限迭代" invariant):
#   A before_tool_call callback counts every tool invocation (both inspect_query
#   and submit_endpoint — the honest measure of work per attempt).  On the call
#   that exceeds MAX_ITERATIONS the callback raises IterationLimitError, which
#   EndpointGeneration (#8) rescues to surface "cannot generate + last error".
#
# Configuration:
#   - model / provider come from config.llm (config_for(:llm)), never hard-coded.
#   - Instructions are loaded from the conventional prompt file below at runtime.
#   - Only inspect_query / submit_endpoint are bound — no write path is reachable.
#
# Prompt file: app/prompts/endpoint_builder_agent/instructions.txt.erb
class EndpointBuilderAgent < RubyLLM::Agent
  # Maximum number of tool calls per generation attempt, counting BOTH
  # inspect_query and submit_endpoint.  Set with headroom for a few rounds of
  # exploration before the agent commits a final script; raise it only if
  # real-world requirements regularly need more rounds to converge.
  MAX_ITERATIONS = 15

  # Point at LMStudio via the OpenAI-compatible provider.
  # assume_model_exists: true bypasses the RubyLLM model-registry lookup so
  # locally-loaded LMStudio models are accepted without a remote capabilities
  # fetch.  provider: :openai is required when assume_model_exists is true.
  model Rails.application.config.llm.model,
        provider: :openai,
        assume_model_exists: true

  # Load system instructions from app/prompts/endpoint_builder_agent/instructions.txt.erb
  # (RubyLLM Agent convention: no-arg `instructions` defaults to { prompt: "instructions" }).
  instructions

  # Stateless exploration tool — declared at the class level.  The stateful
  # submit_endpoint tool is registered per-instance in #initialize so its
  # captured script can be read back (see #submit_tool).  Neither exposes a
  # write path; both delegate to ReadOnlySandbox.
  tools InspectQueryTool

  # Raised by the before_tool_call callback when MAX_ITERATIONS is exceeded.
  # Carry this out of chat#complete and handle in EndpointGeneration context (#8).
  class IterationLimitError < StandardError; end

  # The submit_endpoint tool instance this agent drives.  EndpointGeneration
  # reads #submit_tool.captured_script after the loop to get the final script.
  attr_reader :submit_tool

  def initialize(...)
    super
    # Register submit_endpoint as a tracked instance (RubyLLM supports stateful
    # instance tools via with_tool) so we can read captured_script afterwards.
    @submit_tool = SubmitEndpointTool.new
    with_tool(@submit_tool)

    @tool_call_count = 0
    before_tool_call { |_tool_call| check_iteration_limit! }
  end

  private

  def check_iteration_limit!
    @tool_call_count += 1
    return unless @tool_call_count > MAX_ITERATIONS

    raise IterationLimitError,
          "Stopped after #{MAX_ITERATIONS} script iterations without a successful result. " \
          "The last error has been fed back to the LLM in the conversation history."
  end
end
