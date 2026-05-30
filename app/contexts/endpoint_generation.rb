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
  # @param chat [Chat, nil]      optional persisted Chat to bind to the agent;
  #                               when provided the agent stores all turns in the
  #                               DB so per-message Turbo Stream broadcasts fire (#13).
  #                               When nil the agent uses an in-memory chat (test path).
  def initialize(requirement, agent: nil, chat: nil)
    @requirement = requirement
    @agent = agent || EndpointBuilderAgent.new(chat: chat)
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
  rescue EndpointBuilderAgent::IterationLimitError, ExtractionError => e
    { ok: false, error: e.message }
  rescue ActiveRecord::RecordInvalid => e
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
  #
  # Normalization note:
  #   When the agent uses a persisted Chat, @agent.chat.messages returns AR
  #   Message records.  We normalize each to RubyLLM::Message via #to_llm when
  #   available so the extraction logic is uniform regardless of storage.
  def extract_validated_script
    messages = normalize_messages(@agent.chat.messages)

    # Find the last :tool message that carries a success result.
    success_tool_msg = messages.reverse.find { |m| tool_success_message?(m) }
    raise ExtractionError, "No successful script found in agent conversation history" unless success_tool_msg

    tool_call_id = success_tool_msg.tool_call_id

    # Find the assistant message that triggered this tool call.
    # tool_calls hash keys may be symbols (in-memory RubyLLM::Chat) or
    # strings (persisted Chat after to_llm normalization) — check both.
    assistant_msg = messages.find do |m|
      m.role == :assistant &&
        m.tool_calls.is_a?(Hash) &&
        (m.tool_calls.key?(tool_call_id.to_sym) || m.tool_calls.key?(tool_call_id.to_s))
    end

    unless assistant_msg
      raise ExtractionError, "Could not find assistant message for tool_call_id=#{tool_call_id}"
    end

    tool_call = assistant_msg.tool_calls[tool_call_id.to_sym] ||
                assistant_msg.tool_calls[tool_call_id.to_s]
    # arguments keys may be symbols (in-memory) or strings (persisted/deserialized)
    tool_call.arguments[:script] || tool_call.arguments["script"]
  end

  # Normalize each message to a RubyLLM::Message so extraction logic is uniform
  # for both in-memory chats (test path) and persisted AR chats (production path).
  def normalize_messages(messages)
    messages.map { |m| m.respond_to?(:to_llm) ? m.to_llm : m }
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
