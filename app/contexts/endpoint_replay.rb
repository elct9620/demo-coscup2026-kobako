# frozen_string_literal: true

# DCI Context: replays a persisted, validated Endpoint script in a fresh
# read-only sandbox and returns the structured result.
#
# Usage:
#   result = EndpointReplay.new(endpoint, params).call
#   # => { ok: true,  result: <wire-representable value> }
#   # => { ok: false, error: { type: String, message: String, ... } }
#
# Architecture (docs/architecture.md — DCI 三要素):
#   - Data:        Endpoint (ActiveRecord, read here — not written)
#   - Context:     this class — thin use-case orchestrator, no business logic
#   - Interaction: EventQuery / MetricQuery / ParamsQuery bound via ReadOnlySandbox
#
# Invariants upheld (SPEC.md Consistency → Invariants):
#   - 驗證即上線 (Shared execution path): this context uses the same
#     ReadOnlySandbox builder as RunScriptTool.  The script the agent validated
#     is executed via the identical code path on every live request.
#   - 每次調用全新狀態 (Fresh state per invocation): ReadOnlySandbox#call builds
#     a brand-new Kobako::Sandbox on each call.  No mrb_state leaks between
#     requests.
#   - 兩層唯讀防禦 (Two-layer read-only defense): enforced deeper in
#     ReadOnlySandbox (capability boundary) and the SQLite reading connection
#     (SQL boundary).  This context is unaware of the sandbox internals and
#     must not bypass them.
#   - 查詢參數非法 → 結構化錯誤 (Invalid params → structured error):
#     ReadOnlySandbox validates params before entering the sandbox.  Invalid
#     input never reaches the script.
#
# Interface is consistent with EndpointGeneration — both are instantiated with
# their inputs and return a structured Hash from #call.
#
# Dependency direction (docs/architecture.md — Dependency Guidelines):
#   Context → Data (Endpoint, read-only)
#   Context → ReadOnlySandbox (shared builder, injected for testability)
#   Data does NOT depend on Context.
class EndpointReplay
  # @param endpoint   [Endpoint]   the persisted endpoint whose script to replay
  # @param params     [Hash]       HTTP query parameters (untrusted; String keys,
  #                                String/Integer/nil values)
  # @param sandbox    [ReadOnlySandbox]  shared sandbox builder; defaults to a
  #                                fresh instance with production limits.
  #                                Injectable for tests that need custom timeout.
  def initialize(endpoint, params, sandbox: nil,
                 timeout: ReadOnlySandbox::DEFAULT_TIMEOUT,
                 memory_limit: ReadOnlySandbox::DEFAULT_MEMORY_LIMIT)
    @endpoint = endpoint
    @params   = params
    @sandbox  = sandbox || ReadOnlySandbox.new(timeout: timeout, memory_limit: memory_limit)
  end

  # Replay the endpoint script in a fresh read-only sandbox.
  #
  # @return [Hash] { ok: true,  result: <value> }            on success
  # @return [Hash] { ok: false, error: { type:, message: } } on failure
  def call
    @sandbox.call(@endpoint.script, params: @params)
  end
end
