# frozen_string_literal: true

# DCI Context: orchestrates the EndpointBuilderAgent error-as-feedback loop
# and persists the first validated script as an Endpoint.
#
# Usage:
#   result = EndpointGeneration.new(requirement).call
#   # => { ok: true,  endpoint: <Endpoint> }
#   # => { ok: false, error: "..." }
#
# Architecture (docs/architecture.md — DCI 三要素):
#   - Data:        Endpoint (ActiveRecord, persisted here on success)
#   - Context:     this class — thin use-case orchestrator, no business logic
#   - Interaction: EndpointBuilderAgent drives RunScriptTool → ReadOnlySandbox
#
# Invariants upheld (SPEC.md Consistency → Invariants):
#   - 有限迭代: IterationLimitError from the agent is rescued here; the caller
#     never sees it.  The failure result carries the error message.
#   - 驗證即上線: only the script that passed RunScriptTool (success: true) is
#     persisted.  No re-execution occurs before persisting.
#   - 唯讀邊界: enforced deeper in ReadOnlySandbox — this context is unaware of
#     the sandbox and must not bypass it.
#
# Dependency direction (docs/architecture.md — Dependency Guidelines):
#   Context → Data (Endpoint)
#   Context → Agent (EndpointBuilderAgent, injected for testability)
#   Data does NOT depend on Context.
class EndpointGeneration
  # Raised when the agent conversation history contains no successful tool run.
  # Distinct from IterationLimitError (expected convergence failure) — this
  # signals an unexpected internal inconsistency.
  class ExtractionError < StandardError; end

  # @param requirement [String]  natural-language description from the operator
  # @param agent [#ask, #chat]   agent instance; defaults to EndpointBuilderAgent.new
  #                               (injectable for testing — avoids real LMStudio calls)
  def initialize(requirement, agent: EndpointBuilderAgent.new)
    @requirement = requirement
    @agent = agent
  end

  # Run the self-verification loop and return a structured result.
  #
  # @return [Hash] { ok: true,  endpoint: Endpoint }  on success
  # @return [Hash] { ok: false, error: String }        on failure
  def call
    @agent.ask(@requirement)
    script = extract_validated_script
    endpoint = Endpoint.create!(script: script)
    { ok: true, endpoint: endpoint }
  rescue EndpointBuilderAgent::IterationLimitError => e
    { ok: false, error: e.message }
  end

  private

  # Walk the agent's chat message history to find the last RunScriptTool call
  # that produced { success: true }, then return the script that was submitted
  # in that call.
  #
  # Message structure after the agent loop (from RubyLLM::Chat#handle_tool_calls):
  #
  #   assistant  role: :assistant, tool_calls: { id => ToolCall(name, arguments) }
  #   tool       role: :tool,      content: result_hash.to_s, tool_call_id: id
  #   ...        (may repeat for each correction round)
  #   assistant  role: :assistant, content: "final text"   (no tool_calls)
  #
  # The tool message content is the Ruby Hash#to_s of the RunScriptTool result:
  #   "{success: true, result: ...}"    on success  (Ruby 3.4+ format)
  #   "{success: false, error: ...}"    on failure
  #
  # Strategy:
  #   1. Scan messages in reverse to find the LAST :tool message with success:true.
  #   2. Use its tool_call_id to locate the matching assistant ToolCall.
  #   3. Return the :script argument from that ToolCall.
  #
  # This is the canonical "last successful run" — the script the LLM converged on.
  def extract_validated_script
    messages = @agent.chat.messages

    # Find the last :tool message that carries a success result.
    success_tool_msg = messages.reverse.find { |m| tool_success_message?(m) }
    raise ExtractionError, "No successful script found in agent conversation history" unless success_tool_msg

    tool_call_id = success_tool_msg.tool_call_id

    # Find the assistant message that triggered this tool call.
    assistant_msg = messages.find do |m|
      m.role == :assistant &&
        m.tool_calls.is_a?(Hash) &&
        m.tool_calls.key?(tool_call_id.to_sym)
    end

    unless assistant_msg
      raise ExtractionError, "Could not find assistant message for tool_call_id=#{tool_call_id}"
    end

    tool_call = assistant_msg.tool_calls[tool_call_id.to_sym]
    tool_call.arguments[:script]
  end

  # Returns true when +message+ is a tool-result message whose content
  # represents a successful RunScriptTool run.
  #
  # RunScriptTool returns a Hash; RubyLLM converts non-Content tool results via
  # `result.to_s` before storing as the message content.  In Ruby 3.4+:
  #
  #   { success: true, result: 42 }.to_s
  #   => "{success: true, result: 42}"
  #
  # We check for the substring "success: true" to avoid a full eval.
  # This is safe because RunScriptTool is the sole tool and its contract is
  # stable: success key is always a boolean literal.
  def tool_success_message?(message)
    message.role == :tool &&
      message.tool_call_id.present? &&
      message.content.to_s.include?("success: true")
  end
end
