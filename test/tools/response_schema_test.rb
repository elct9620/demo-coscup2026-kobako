# frozen_string_literal: true

require "test_helper"

# Unit tests for ResponseSchema — the generation guardrail that checks a
# sandbox script's return value against the standard response envelope:
#
#   { "data" => <value>, "meta" => { ... } }
#
# Contract under test (mirrors ReadOnlySandbox#validate_params):
#   #validate returns nil when the value conforms, or a single human-readable
#   error String when it does not.  RunScriptTool feeds that String back to the
#   LLM as a SchemaError so it self-corrects in the error-as-feedback loop.
class ResponseSchemaTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Conforming envelopes — #validate returns nil
  # ---------------------------------------------------------------------------

  test "returns nil for a minimal envelope with an empty meta" do
    assert_nil ResponseSchema.validate({ "data" => 42, "meta" => {} })
  end

  test "returns nil for an envelope with a populated meta" do
    value = { "data" => [ [ "page_view", 12 ] ], "meta" => { "limit" => 3 } }
    assert_nil ResponseSchema.validate(value)
  end

  test "returns nil when data is itself a nested Hash" do
    value = { "data" => { "2026-05-31" => 4 }, "meta" => { "window_days" => 7 } }
    assert_nil ResponseSchema.validate(value)
  end

  # ---------------------------------------------------------------------------
  # Bare scalars / non-Hash top level — the core smell we are stamping out
  # ---------------------------------------------------------------------------

  test "returns an error String when the value is a bare Integer" do
    error = ResponseSchema.validate(42)
    assert_kind_of String, error
    assert_match(/Hash/, error)
  end

  test "returns an error String when the value is a bare String" do
    assert_kind_of String, ResponseSchema.validate("just a string")
  end

  test "returns an error String when the value is a bare Array" do
    assert_kind_of String, ResponseSchema.validate([ 1, 2, 3 ])
  end

  test "returns an error String when the value is nil" do
    assert_kind_of String, ResponseSchema.validate(nil)
  end

  # ---------------------------------------------------------------------------
  # Missing required keys
  # ---------------------------------------------------------------------------

  test "returns an error mentioning data when the data key is missing" do
    error = ResponseSchema.validate({ "meta" => {} })
    assert_kind_of String, error
    assert_match(/data/, error)
  end

  test "returns an error mentioning meta when the meta key is missing" do
    error = ResponseSchema.validate({ "data" => 1 })
    assert_kind_of String, error
    assert_match(/meta/, error)
  end

  # ---------------------------------------------------------------------------
  # meta must be a Hash
  # ---------------------------------------------------------------------------

  test "returns an error mentioning meta when meta is not a Hash" do
    error = ResponseSchema.validate({ "data" => 1, "meta" => "nope" })
    assert_kind_of String, error
    assert_match(/meta/, error)
  end

  # ---------------------------------------------------------------------------
  # Documented contract edges — these pin intentional decisions so they cannot
  # drift silently (the envelope requires data + meta, but says nothing else).
  # ---------------------------------------------------------------------------

  test "allows extra top-level keys alongside data and meta" do
    value = { "data" => 1, "meta" => {}, "links" => { "next" => "?page=2" } }
    assert_nil ResponseSchema.validate(value)
  end

  test "treats nil as a valid data value when the key is present" do
    assert_nil ResponseSchema.validate({ "data" => nil, "meta" => {} })
  end

  test "rejects a Symbol-keyed envelope — the wire contract requires String keys" do
    assert_kind_of String, ResponseSchema.validate({ data: 1, meta: {} })
  end
end
