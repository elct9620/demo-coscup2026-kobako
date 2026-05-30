# frozen_string_literal: true

# Consumer-facing read-only JSON API — replays a persisted, LLM-validated
# mruby endpoint script on demand.
#
# Route: GET /e/:slug
#
# Architecture (docs/architecture.md — DCI 三要素):
#   This controller is a thin HTTP adapter.  It translates HTTP semantics into
#   EndpointReplay context calls and maps structured results back to HTTP.  All
#   business logic (sandbox execution, param validation, read-only enforcement)
#   lives in EndpointReplay and ReadOnlySandbox — not here.
#
# Security (coding:security — STRIDE):
#   Tampering (T): slug and query params are untrusted HTTP input.  The slug is
#     passed only to Endpoint.find_by!(slug:) — never interpolated into queries
#     or scripts.  Query params are forwarded only to EndpointReplay, which gates
#     them through ReadOnlySandbox#validate_params before the script runs.
#   Denial of Service (D): sandbox timeout and memory limit are enforced inside
#     ReadOnlySandbox; a hung or memory-hungry script is terminated and returns a
#     structured error rather than hanging the request indefinitely.
#   Information Disclosure (I): structured error details (mruby-side context such
#     as class name, origin, and backtrace) are included in responses to aid Demo
#     self-correction visibility.  No host-side secrets or paths are exposed.
#
# HTTP Status contract (coding:schema):
#   200  — replay succeeded; body is the script's return value as JSON
#   404  — no Endpoint with the given slug (ActiveRecord::RecordNotFound)
#   422  — query parameter validation failure (InvalidParamsError before sandbox)
#   500  — sandbox execution error (SandboxError, TimeoutError, MemoryLimitError,
#           TrapError, ServiceError)
#
# CSRF: inherits ActionController::API (not Base), which carries no CSRF
# middleware.  This endpoint is a pure JSON GET API with no session or cookies;
# CSRF protection is both unnecessary and inapplicable.
class DynamicEndpointsController < ActionController::API
  # Map EndpointReplay error types to HTTP status codes.
  #
  # InvalidParamsError   — client error: the query params are structurally
  #                        invalid (wrong key type, disallowed value type).
  #                        422 Unprocessable Entity communicates "we understood
  #                        the request but cannot process it as sent."
  #
  # Sandbox family       — server error: the script itself failed at runtime,
  #                        timed out, or exceeded memory.  503 would imply a
  #                        retry would succeed; 500 is correct because the
  #                        error is in the stored script, not a transient
  #                        infrastructure failure.
  ERROR_STATUS = {
    "InvalidParamsError"  => :unprocessable_entity,
    "SandboxError"        => :internal_server_error,
    "TrapError"           => :internal_server_error,
    "TimeoutError"        => :internal_server_error,
    "MemoryLimitError"    => :internal_server_error,
    "ServiceError"        => :internal_server_error
  }.freeze

  def show
    endpoint = Endpoint.find_by!(slug: params[:slug])
    result   = EndpointReplay.new(endpoint, request.query_parameters).call

    if result[:ok]
      # Explicit .to_json is required: Rails' render json: skips encoding when
      # the value is already a String, which would send bare strings without
      # JSON quotes (invalid JSON).  Calling .to_json first normalises all types.
      render json: result[:result].to_json
    else
      status = ERROR_STATUS.fetch(result[:error][:type], :internal_server_error)
      render json: { error: result[:error] }, status: status
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: { type: "RecordNotFound", message: "Endpoint not found" } },
           status: :not_found
  end
end
