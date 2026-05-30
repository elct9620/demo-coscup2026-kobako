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
  desc "Trial-runs an mruby script in the read-only sandbox. " \
       "Available services: Service::Events (EventQuery) and Service::Metrics (MetricQuery). " \
       "Returns a result hash the agent uses to verify correctness or self-correct on error."

  param :script,
        type: "string",
        desc: "The mruby script to evaluate. Must return a MessagePack-serializable value " \
              "(Integer, Float, String, Array, Hash, nil, or Boolean). " \
              "Access data via Service::Events and Service::Metrics."

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
  #   - error_type   — distinguishes TimeoutError / SandboxError / etc.
  #   - error        — human-readable message for direct correction guidance
  #   - details      — mruby klass + backtrace_lines for precise diagnosis
  def execute(script:)
    outcome = @sandbox.call(script)

    if outcome[:ok]
      { success: true, result: outcome[:result] }
    else
      err = outcome[:error]
      result = { success: false, error: err[:message], error_type: err[:type] }
      result[:details] = err[:details] if err[:details]
      result
    end
  end
end
