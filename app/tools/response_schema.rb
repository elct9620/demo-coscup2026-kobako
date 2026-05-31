# frozen_string_literal: true

# Generation guardrail — validates that a sandbox script's return value conforms
# to the standard response envelope:
#
#   { "data" => <wire-representable value>, "meta" => { ... } }
#
# SubmitEndpointTool runs the LLM-generated script in ReadOnlySandbox, then
# passes the return value through here.  A non-conforming shape is reported back
# to the LLM as a SchemaError, so it self-corrects in the error-as-feedback loop
# — exactly as it would for a runtime error.  This keeps every generated
# endpoint's response self-describing (named "data" + a "meta" block) instead of
# a bare scalar like 42 or "page_view".  (inspect_query deliberately skips this
# check so the agent can explore raw values.)
#
# Why here (next to SubmitEndpointTool) and not in ReadOnlySandbox:
#   The sandbox's responsibility is *safe execution* and returning a
#   wire-representable value.  The response *shape* is a product-level generation
#   contract, enforced at the submission surface — so this lives beside its sole
#   consumer, SubmitEndpointTool, not baked into the shared execution path.
#   EndpointReplay therefore replays the already-conforming script without
#   re-checking (the script is identical, so its shape is too).  This preserves
#   the "驗證即上線" invariant.
#
# Convention:
#   #validate returns nil when the value conforms, or a single human-readable
#   error String when it does not — mirroring ReadOnlySandbox#validate_params,
#   which also returns nil-on-success.  The String is written for an LLM reader:
#   it states what is wrong and how to fix it.
class ResponseSchema
  # Envelope keys every generated response must carry.  String keys, because the
  # value crosses the MessagePack wire where String is the natural key type
  # (Symbol keys are not part of the wire contract).
  DATA_KEY = "data"
  META_KEY = "meta"

  # @param value [Object] the script's return value (already across the wire)
  # @return [String, nil] nil when valid; an error message when invalid
  def self.validate(value)
    new(value).validate
  end

  def initialize(value)
    @value = value
  end

  # @return [String, nil] nil when the envelope conforms; otherwise the first
  #   violation as a human-readable, fix-oriented message for the LLM.
  def validate
    unless @value.is_a?(Hash)
      return "Response must be a Hash envelope { \"#{DATA_KEY}\" => ..., \"#{META_KEY}\" => {} }, " \
             "got #{@value.class}. Wrap your result in this envelope instead of returning a bare value."
    end

    unless @value.key?(DATA_KEY)
      return "Response envelope is missing the required \"#{DATA_KEY}\" key. " \
             "Put the result value under \"#{DATA_KEY}\"."
    end

    unless @value.key?(META_KEY)
      return "Response envelope is missing the required \"#{META_KEY}\" key. " \
             "Add a \"#{META_KEY}\" Hash describing the query (e.g. window, limit, generated_at)."
    end

    unless @value[META_KEY].is_a?(Hash)
      return "Response \"#{META_KEY}\" must be a Hash, got #{@value[META_KEY].class}. " \
             "Use \"#{META_KEY}\" => {} when there is nothing to describe."
    end

    nil
  end
end
