# frozen_string_literal: true

# RubyLLM::Tool that trial-runs an LLM-generated mruby script inside the
# read-only Kobako sandbox and returns a structured result.
#
# This is the single tool used by EndpointBuilderAgent (#7).  The agent's
# native tool-calling loop drives the error-as-feedback self-correction cycle:
#
#   1. LLM generates a mruby script (Code Mode).
#   2. Agent calls RunScriptTool with the script.
#   3. execute() delegates to ReadOnlySandbox.
#   4. On failure, the structured error hash is returned as the tool result
#      and fed back to the LLM, which uses it to self-correct and retry.
#   5. On success, the LLM sees the return value and confirms the script meets
#      the requirement; EndpointBuilderAgent then persists the Endpoint.
#
# Iteration cap is NOT the responsibility of this tool — it is enforced by
# EndpointBuilderAgent via before_tool_call (see #7).
#
# Trust boundary: script is LLM-generated (untrusted). The sandbox is the sole
# enforcement point — this tool must not add any execution path outside it.
class RunScriptTool < RubyLLM::Tool
  desc "Trial-runs an mruby script in the restricted read-only sandbox (no Time/Date/require). " \
       "Available namespaces: Service::Events, Service::Metrics, Service::Params, and Utils::Time " \
       "(use Utils::Time.now for the current time — the sandbox has no Time constant). " \
       "Returns a result hash the agent uses to verify correctness or self-correct on error."

  param :script,
        type: "string",
        desc: "The mruby script to evaluate. Must return a MessagePack-serializable value " \
              "(Integer, Float, String, Array, Hash, nil, or Boolean). " \
              "Access data via Service::Events / Service::Metrics / Service::Params; " \
              "get the current time via Utils::Time.now (Time/Date constants are unavailable)."

  def initialize(timeout: ReadOnlySandbox::DEFAULT_TIMEOUT,
                 memory_limit: ReadOnlySandbox::DEFAULT_MEMORY_LIMIT)
    @sandbox = ReadOnlySandbox.new(timeout: timeout, memory_limit: memory_limit)
  end

  # Execute the script and return a tool result hash suitable for LLM consumption.
  #
  # Success:
  #   { success: true, result: <value> }
  #
  # Failure (error-as-feedback):
  #   { success: false, error: String, error_type: String, details: Hash | nil }
  #
  # The failure shape gives the LLM:
  #   - error_type   — distinguishes TimeoutError / SandboxError / SchemaError / etc.
  #   - error        — human-readable message for direct correction guidance
  #   - details      — mruby klass + backtrace_lines for precise diagnosis
  #
  # A script may run cleanly yet return a non-conforming shape (e.g. a bare
  # scalar instead of the { "data" => ..., "meta" => {} } envelope).  Such a
  # result is turned into a SchemaError so the LLM self-corrects in the same
  # error-as-feedback loop it uses for runtime errors — the response contract is
  # part of "correctness" for a generated endpoint.
  def execute(script:)
    outcome = @sandbox.call(script)
    return sandbox_error(outcome[:error]) unless outcome[:ok]

    schema_error = ResponseSchema.validate(outcome[:result])
    return { success: false, error: schema_error, error_type: "SchemaError" } if schema_error

    { success: true, result: outcome[:result] }
  end

  private

  def sandbox_error(err)
    result = { success: false, error: err[:message], error_type: err[:type] }
    result[:details] = err[:details] if err[:details]
    result
  end
end
