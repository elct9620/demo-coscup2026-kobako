# frozen_string_literal: true

# Shared builder for the read-only Kobako sandbox.
#
# This is the canonical execution path for both:
#   • Validation  — RunScriptTool (#6) calls #call(script) to trial-run
#     LLM-generated mruby and feed structured errors back to the agent.
#   • Replay      — EndpointReplay (#9) calls #call(script) to serve a
#     live request with the stored endpoint script.
#
# Sharing the same builder satisfies the "Validation == Live" invariant from
# docs/architecture.md: what the agent verified is exactly what gets served.
#
# Three-invariant summary (docs/architecture.md Patterns):
#
#   1. Capability boundary (layer 1 of two-layer read-only defense):
#      The sandbox is bound only to EventQuery and MetricQuery.  No write
#      path is exposed; the script cannot reach AR models, the filesystem,
#      the network, or ENV.
#
#   2. Shared execution path:
#      Both RunScriptTool and EndpointReplay instantiate ReadOnlySandbox and
#      call #call(script).  Same code, same sandbox setup, same result.
#
#   3. Fresh state per invocation:
#      Each #call builds a brand-new Kobako::Sandbox so that no mrb_state,
#      Handle table, or stdout/stderr buffer leaks from one invocation to the
#      next.  (A TrapError also makes the underlying Sandbox unrecoverable;
#      building fresh avoids the need to track that condition on the builder.)
#
# Usage:
#   sandbox = ReadOnlySandbox.new
#   result  = sandbox.call(script)
#
#   # Success path (ok: true):
#   result  #=> { ok: true, result: <wire-representable value> }
#
#   # Error path (ok: false):
#   result  #=> { ok: false, error: { type: "SandboxError"|"TrapError"|...,
#                                     message: String,
#                                     details: Hash | nil } }
#
# Script namespace (bound via Service::Events / Service::Metrics):
#   Service::Events.count
#   Service::Events.between("2026-01-01", "2026-05-31").by_name("page_view").count
#   Service::Metrics.total_count(name: "page_view")
#   Service::Metrics.daily_counts(since: "2026-01-01")
#   Service::Metrics.top_names(limit: 5)
class ReadOnlySandbox
  # Wall-clock timeout per invocation (seconds, Float).
  # Kobako default is 60 s; tighter here to cap LLM-generated runaway loops.
  DEFAULT_TIMEOUT = 5.0

  # Per-invocation linear-memory delta cap (bytes, Integer).
  # Keeps mruby scripts from inflating the Wasm heap unboundedly.
  DEFAULT_MEMORY_LIMIT = 16 * 1024 * 1024 # 16 MiB

  def initialize(timeout: DEFAULT_TIMEOUT, memory_limit: DEFAULT_MEMORY_LIMIT)
    @timeout = timeout
    @memory_limit = memory_limit
  end

  # Execute +script+ inside a fresh read-only Kobako sandbox.
  #
  # Returns a Hash with one of two shapes:
  #
  #   Success: { ok: true,  result: <wire-representable value> }
  #   Failure: { ok: false, error: { type: String, message: String,
  #                                  details: Hash | nil } }
  #
  # Never raises — all Kobako exceptions are caught and converted to the
  # structured error shape so callers (#6 error-as-feedback, #9 HTTP response)
  # can act on them without their own rescue clauses.
  def call(script)
    sandbox = build_sandbox
    value   = sandbox.eval(script)
    { ok: true, result: value }
  rescue Kobako::TimeoutError => e
    error_result("TimeoutError", e)
  rescue Kobako::MemoryLimitError => e
    error_result("MemoryLimitError", e)
  rescue Kobako::TrapError => e
    error_result("TrapError", e)
  rescue Kobako::ServiceError => e
    error_result("ServiceError", e, structured_details(e))
  rescue Kobako::SandboxError => e
    error_result("SandboxError", e, structured_details(e))
  end

  private

  # Build a fresh Kobako::Sandbox with capability boundary:
  # only EventQuery (Service::Events) and MetricQuery (Service::Metrics)
  # are bound — no write path is reachable from the script.
  def build_sandbox
    sandbox = Kobako::Sandbox.new(timeout: @timeout, memory_limit: @memory_limit)
    sandbox.define(:Service)
           .bind(:Events,  EventQuery.new)
           .bind(:Metrics, MetricQuery.new)
    sandbox
  end

  def error_result(type, exception, details = nil)
    error = { type: type, message: exception.message }
    error[:details] = details if details
    { ok: false, error: error }
  end

  # Extract the structured panic envelope from SandboxError / ServiceError.
  #
  # These carry the guest-side failure context (mruby class, origin, backtrace,
  # and any extra details) that #6 feeds back to the LLM so it can self-correct.
  def structured_details(exception)
    return nil unless exception.respond_to?(:klass)

    {
      klass:           exception.klass,
      origin:          exception.origin,
      backtrace_lines: exception.backtrace_lines,
      details:         exception.details
    }.compact
  end
end
