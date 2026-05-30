# frozen_string_literal: true

# DCI Interaction role — the read-only query parameter entry point bound into
# the Kobako sandbox as Service::Params.
#
# HTTP query parameters arrive as an untrusted Hash[String, String|Integer] from
# the controller.  This class is the sandbox-facing adapter: it validates and
# exposes params safely, keeping untrusted data on the *data* side of the
# instruction/data boundary.
#
# Allowed value types (MessagePack wire-representable and HTTP-natural):
#   String  — the default HTTP query string value type
#   Integer — a numeric query parameter (e.g. ?limit=10 after controller coercion)
#   nil     — represented as nil in the sandbox
#
# Float, Boolean, Array, Hash are intentionally excluded: they require extra
# parsing contracts that HTTP query strings do not support natively, and the
# Demo does not need them.  LLM-generated scripts that require typed parameters
# should apply conversion inside the script (e.g. `param.to_i`).
#
# Usage (bound in ReadOnlySandbox):
#   sandbox.define(:Service).bind(:Params, ParamsQuery.new(params))
#
# Script example:
#   Service::Params.fetch("name")     # => "page_view" or nil
#   Service::Params.fetch("limit")    # => 10 or nil
#
# Trust boundary:
#   +params+ is untrusted HTTP input.  Keys must be Strings.  Values must be
#   String, Integer, or nil.  All other types are rejected at construction via
#   +ReadOnlySandbox#call+ — callers receive a structured InvalidParamsError
#   result before the sandbox is invoked.
class ParamsQuery
  # Allowed value types.  Any value not in this set is rejected.
  ALLOWED_VALUE_TYPES = [ String, Integer, NilClass ].freeze

  def initialize(params)
    @params = params
  end

  # Fetch the value for +key+ from the query params.
  # Returns the value (String, Integer, or nil) when the key is present,
  # nil when the key is absent.
  def fetch(key)
    @params[key.to_s]
  end
end
