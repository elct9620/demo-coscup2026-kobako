# frozen_string_literal: true

# RubyLLM::Agent that drives the error-as-feedback self-correction loop
# (docs/architecture.md — "error-as-feedback 自我驗證迴圈" pattern).
#
# The agent receives a natural-language requirement from the operator, then
# iterates in Code Mode:
#
#   1. Generate a read-only mruby script using Service::Events / Service::Metrics.
#   2. Call RunScriptTool to trial-run the script inside ReadOnlySandbox.
#   3. If success: true, the validated script is ready for Endpoint creation.
#   4. If success: false, the structured error is fed back as the tool result
#      and the LLM self-corrects in the next turn.
#
# Iteration cap (SPEC "有限迭代" invariant):
#   A before_tool_call callback counts every tool invocation.  On the call
#   that exceeds MAX_ITERATIONS the callback raises IterationLimitError,
#   which the calling context (#8 EndpointGeneration) rescues to surface
#   "cannot generate + last error" to the operator.
#
# Configuration:
#   - model / provider come from config.llm (config_for(:llm)), never hard-coded.
#   - Instructions are loaded from the conventional prompt file below at runtime.
#   - RunScriptTool is the single tool — no write path is reachable.
#
# Prompt file: app/prompts/endpoint_builder_agent/instructions.txt.erb
class EndpointBuilderAgent < RubyLLM::Agent
  # Maximum number of RunScriptTool calls per generation attempt.
  # Raise this only if real-world scripts regularly need more rounds to converge.
  MAX_ITERATIONS = 5

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

  # Sole tool — delegates to ReadOnlySandbox; no write path is reachable.
  tools RunScriptTool

  # Raised by the before_tool_call callback when MAX_ITERATIONS is exceeded.
  # Carry this out of chat#complete and handle in EndpointGeneration context (#8).
  class IterationLimitError < StandardError; end

  def initialize(...)
    super
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
