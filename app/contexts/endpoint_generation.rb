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
#   - Interaction: EndpointBuilderAgent drives inspect_query / submit_endpoint → ReadOnlySandbox
#
# Invariants upheld (SPEC.md Consistency → Invariants):
#   - 有限迭代: IterationLimitError from the agent is rescued here; the caller
#     never sees it.  Hitting the cap is a failure even if an earlier submission
#     succeeded — the captured script is read only when the loop ends cleanly.
#   - 終態保證: LLM transport / infrastructure errors (RubyLLM::Error, Faraday::Error
#     — e.g. LMStudio unreachable or model not loaded) are also rescued into an
#     ok:false result, never propagated.  This keeps every outcome terminal so the
#     Job can mark the request failed and the operator UI leaves the pending state.
#   - 驗證即上線: only the script captured by SubmitEndpointTool (sandbox-run +
#     envelope-valid) is persisted.  No re-execution occurs before persisting.
#   - 唯讀邊界: enforced deeper in ReadOnlySandbox — this context is unaware of
#     the sandbox and must not bypass it.
#
# Dependency direction (docs/architecture.md — Dependency Guidelines):
#   Context → Data (Endpoint)
#   Context → Agent (EndpointBuilderAgent, injected for testability)
#   Data does NOT depend on Context.
class EndpointGeneration
  # Raised when the agent's loop ended cleanly but it never submitted a script
  # that passed validation (submit_tool.captured_script is nil).  Distinct from
  # IterationLimitError (cap hit): this means the agent gave up without a result.
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
  # The final script is whatever the agent captured during the loop (the last
  # submission that passed sandbox execution + the envelope check).  We ask the
  # agent for it via #captured_script rather than scanning chat history.
  #
  # @return [Hash] { ok: true,  endpoint: Endpoint }  on success
  # @return [Hash] { ok: false, error: String }        on failure
  def call
    @agent.ask(@requirement)

    script = @agent.captured_script
    raise ExtractionError, "Agent finished without submitting a valid endpoint script" if script.nil?

    endpoint = Endpoint.create!(script: script)
    { ok: true, endpoint: endpoint }
  rescue EndpointBuilderAgent::IterationLimitError, ExtractionError => e
    { ok: false, error: e.message }
  rescue ActiveRecord::RecordInvalid => e
    { ok: false, error: e.message }
  rescue RubyLLM::Error, Faraday::Error => e
    # LLM transport / infrastructure failure: the local model is unreachable or
    # unloaded (LMStudio JIT "model not loaded" → HTTP 400 → RubyLLM::Error, or
    # the server is down → Faraday::Error). Convert to a terminal failure here so
    # the Job marks the request failed and the operator UI leaves the pending
    # state — instead of the exception escaping and stranding the request as
    # "Generating…" with no way forward. We stop after this one attempt; retry is
    # a backend concern, not part of this self-verification loop.
    { ok: false, error: "本地模型服務未就緒或無回應，生成已中止：#{e.message}" }
  end
end
