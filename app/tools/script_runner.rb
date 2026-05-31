# frozen_string_literal: true

# Runs an LLM-generated mruby script in the read-only Kobako sandbox and shapes
# the outcome into the tool-result contract the agent's tools consume.
#
# This is the shared execution-and-translation step behind both agent tools:
#   • InspectQueryTool  — returns this result as-is (free exploration).
#   • SubmitEndpointTool — adds the response-envelope guardrail on top.
#
# Keeping the sandbox call + error shaping here (one place) prevents the
# LLM-facing result contract from drifting between the two tools.
#
# Result shape (the LLM tool-result contract):
#   Success: { success: true,  result: <wire-representable value> }
#   Failure: { success: false, error: String, error_type: String, details: Hash | nil }
#
# Trust boundary: the script is LLM-generated (untrusted).  ReadOnlySandbox is
# the sole enforcement point — this runner must not add any execution path
# outside it.
class ScriptRunner
  def initialize(timeout: ReadOnlySandbox::DEFAULT_TIMEOUT,
                 memory_limit: ReadOnlySandbox::DEFAULT_MEMORY_LIMIT)
    @sandbox = ReadOnlySandbox.new(timeout: timeout, memory_limit: memory_limit)
  end

  # Trial-run +script+ and return the structured tool result.
  #
  # @param script [String] the mruby script to evaluate
  # @return [Hash] success or structured-error tool result (see class doc)
  def call(script)
    outcome = @sandbox.call(script)
    return sandbox_error(outcome[:error]) unless outcome[:ok]

    { success: true, result: outcome[:result] }
  end

  private

  def sandbox_error(err)
    result = { success: false, error: err[:message], error_type: err[:type] }
    result[:details] = err[:details] if err[:details]
    result
  end
end
