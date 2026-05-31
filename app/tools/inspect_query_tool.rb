# frozen_string_literal: true

# RubyLLM::Tool that lets the agent *explore* the data freely while designing an
# endpoint script — the diagnostic half of the two-tool generation loop.
#
# Unlike SubmitEndpointTool, this tool does NOT enforce the response envelope.
# The script may return any wire-representable value (a bare count, a raw row
# Array, a peek at a Hash), and the agent gets that value straight back.  This is
# what lets the agent rule out data problems ("is this count really 0?", "what
# shape does .to_a return?") without being blocked by the final-output contract.
#
# Nothing run through this tool can become a live endpoint: EndpointGeneration
# only ever persists the script captured by SubmitEndpointTool.  Inspection is
# scratch work; submission is the commitment.
#
# Trust boundary: script is LLM-generated (untrusted).  Execution is delegated to
# ScriptRunner → ReadOnlySandbox, the sole enforcement point — this tool adds no
# execution path outside it.
class InspectQueryTool < RubyLLM::Tool
  desc "Trial-runs an mruby script in the restricted read-only sandbox to EXPLORE the data " \
       "while you design an endpoint. Returns whatever value the script produces — a bare " \
       "Integer/Array/Hash is fine, no response envelope is required here. " \
       "Use this to inspect counts, peek at rows, and rule out query problems before you " \
       "commit a final script with submit_endpoint. Inspection never goes live. " \
       "Available namespaces: Service::Events, Service::Metrics, Service::Params, Utils::Time."

  param :script,
        type: "string",
        desc: "The mruby script to evaluate for exploration. Must return a MessagePack-serializable " \
              "value (Integer, Float, String, Array, Hash, nil, or Boolean). No envelope required. " \
              "Access data via Service::Events / Service::Metrics / Service::Params; " \
              "get the current time via Utils::Time.now (Time/Date constants are unavailable)."

  def initialize(timeout: ReadOnlySandbox::DEFAULT_TIMEOUT,
                 memory_limit: ReadOnlySandbox::DEFAULT_MEMORY_LIMIT)
    @runner = ScriptRunner.new(timeout: timeout, memory_limit: memory_limit)
  end

  # Run the script and return the raw tool result.
  #
  #   Success: { success: true,  result: <value> }   # any shape — no envelope check
  #   Failure: { success: false, error: String, error_type: String, details: Hash? }
  #
  # Sandbox errors flow back as structured feedback exactly as they do for
  # submit_endpoint, so the agent self-corrects query/runtime mistakes in the
  # same error-as-feedback loop.
  def execute(script:)
    @runner.call(script)
  end
end
