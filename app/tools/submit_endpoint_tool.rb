# frozen_string_literal: true

# RubyLLM::Tool the agent calls to *commit* its final endpoint script — the
# decisive half of the two-tool generation loop (InspectQueryTool is the
# exploratory half).
#
# Calling this tool means "this is my answer." The script is trial-run in the
# read-only sandbox and its return value is checked against the response
# envelope ({ "data" => ..., "meta" => {} }) via ResponseSchema:
#
#   • Sandbox/runtime error → structured error fed back (error-as-feedback).
#   • Non-conforming shape   → SchemaError fed back, so the agent wraps and
#                              resubmits in the same loop.
#   • Conforms              → the exact submitted script is captured as the
#                              endpoint candidate, and { success: true } returns.
#
# Capture is how "which script is the final one" is answered mechanically.
# After the agent loop, EndpointGeneration reads it (via the agent's
# #captured_script delegator) instead of scanning the chat history.  Each
# successful submission overwrites it, so the value is the LAST script that
# passed — the one the agent converged on.
#
# Lifecycle: @captured_script is per-instance mutable state, and that is safe
# because one tool instance serves exactly one generation — EndpointBuilderAgent
# news a fresh SubmitEndpointTool per agent, and EndpointGeneration news a fresh
# agent per call.  Do not share a single instance across generations, or a stale
# capture could leak from one into the next.
#
# 驗證即上線 invariant: validation runs the script through the same
# ReadOnlySandbox that EndpointReplay uses to serve it, and only a captured
# (sandbox-run + envelope-valid) script is ever persisted — so what was verified
# is exactly what goes live.  The envelope check stays here (gen-time contract),
# not in ReadOnlySandbox, so replay does not re-validate an identical script.
#
# Trust boundary: script is LLM-generated (untrusted). Execution is delegated to
# ScriptRunner → ReadOnlySandbox, the sole enforcement point.
class SubmitEndpointTool < RubyLLM::Tool
  desc "Submits your FINAL mruby script as the endpoint. The script is run in the read-only " \
       "sandbox and its return value MUST be the response envelope " \
       "{ \"data\" => <result>, \"meta\" => { ... } } — a bare value is rejected as a SchemaError. " \
       "On success this script goes live as the endpoint, so submit only once you are confident " \
       "(use inspect_query first to explore). If it fails, read the error, fix, and submit again. " \
       "Available namespaces: Service::Events, Service::Metrics, Service::Params, Utils::Time."

  param :script,
        type: "string",
        desc: "The final mruby script. Its last expression MUST be the envelope " \
              "{ \"data\" => <wire-representable value>, \"meta\" => Hash }. " \
              "Access data via Service::Events / Service::Metrics / Service::Params; " \
              "get the current time via Utils::Time.now (Time/Date constants are unavailable)."

  # The last script that passed both sandbox execution and the envelope check.
  # nil until a submission succeeds.  Read by EndpointGeneration after the loop.
  attr_reader :captured_script

  def initialize(timeout: ReadOnlySandbox::DEFAULT_TIMEOUT,
                 memory_limit: ReadOnlySandbox::DEFAULT_MEMORY_LIMIT)
    @runner = ScriptRunner.new(timeout: timeout, memory_limit: memory_limit)
    @captured_script = nil
  end

  # Validate the script and, on success, capture it as the endpoint candidate.
  #
  #   Success: { success: true,  result: <enveloped value> }
  #   Failure: { success: false, error: String, error_type: String, details: Hash? }
  #
  # A clean run that returns a non-conforming shape is reported as a SchemaError
  # so it self-corrects in the same error-as-feedback loop as a runtime error —
  # the response contract is part of "correctness" for a generated endpoint.
  def execute(script:)
    result = @runner.call(script)
    return result unless result[:success]

    schema_error = ResponseSchema.validate(result[:result])
    return { success: false, error: schema_error, error_type: "SchemaError" } if schema_error

    @captured_script = script
    result
  end
end
