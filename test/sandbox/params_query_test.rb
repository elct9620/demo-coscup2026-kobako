# frozen_string_literal: true

require "test_helper"

# Unit tests for ParamsQuery — the DCI Interaction role that exposes
# read-only query parameters to mruby scripts running in the Kobako sandbox
# as Service::Params.
#
# ParamsQuery is the host-side gate for the trust boundary: it holds the
# validated, wire-safe params hash produced by ReadOnlySandbox#validate_params
# and exposes a safe #fetch interface to the sandbox.
#
# Three properties under test:
#   1. ALLOWED_VALUE_TYPES white-list content is exactly [String, Integer, NilClass].
#   2. #fetch returns the value for a present key.
#   3. #fetch returns nil for an absent key (no KeyError / NoMethodError).
#   4. #fetch coerces the key argument via to_s (numeric keys work transparently).
class ParamsQueryTest < ActiveSupport::TestCase
  setup do
    @params = ParamsQuery.new({ "name" => "page_view", "limit" => 10, "optional" => nil })
  end

  # ---------------------------------------------------------------------------
  # ALLOWED_VALUE_TYPES constant — white-list contract
  # ---------------------------------------------------------------------------

  test "ALLOWED_VALUE_TYPES includes String" do
    assert_includes ParamsQuery::ALLOWED_VALUE_TYPES, String
  end

  test "ALLOWED_VALUE_TYPES includes Integer" do
    assert_includes ParamsQuery::ALLOWED_VALUE_TYPES, Integer
  end

  test "ALLOWED_VALUE_TYPES includes NilClass" do
    assert_includes ParamsQuery::ALLOWED_VALUE_TYPES, NilClass
  end

  test "ALLOWED_VALUE_TYPES contains exactly three entries" do
    assert_equal 3, ParamsQuery::ALLOWED_VALUE_TYPES.size
  end

  test "ALLOWED_VALUE_TYPES does not include Float" do
    refute_includes ParamsQuery::ALLOWED_VALUE_TYPES, Float
  end

  test "ALLOWED_VALUE_TYPES does not include Array" do
    refute_includes ParamsQuery::ALLOWED_VALUE_TYPES, Array
  end

  test "ALLOWED_VALUE_TYPES does not include Hash" do
    refute_includes ParamsQuery::ALLOWED_VALUE_TYPES, Hash
  end

  # ---------------------------------------------------------------------------
  # #fetch — present key
  # ---------------------------------------------------------------------------

  test "fetch returns String value for present String key" do
    assert_equal "page_view", @params.fetch("name")
  end

  test "fetch returns Integer value for present key" do
    assert_equal 10, @params.fetch("limit")
  end

  test "fetch returns nil for a key whose value is nil" do
    assert_nil @params.fetch("optional")
  end

  # ---------------------------------------------------------------------------
  # #fetch — absent key
  # ---------------------------------------------------------------------------

  test "fetch returns nil when key is absent" do
    assert_nil @params.fetch("nonexistent")
  end

  test "fetch returns nil for any absent key without raising" do
    assert_nothing_raised { @params.fetch("missing_key") }
  end

  # ---------------------------------------------------------------------------
  # #fetch — key to_s coercion
  # ---------------------------------------------------------------------------

  test "fetch coerces a Symbol key via to_s so it matches a String-keyed entry" do
    assert_equal "page_view", @params.fetch(:name)
  end

  test "fetch coerces an Integer key via to_s so it matches a String-keyed entry" do
    query = ParamsQuery.new({ "42" => "answer" })
    assert_equal "answer", query.fetch(42)
  end

  # ---------------------------------------------------------------------------
  # Empty params
  # ---------------------------------------------------------------------------

  test "fetch on an empty params hash returns nil" do
    empty = ParamsQuery.new({})
    assert_nil empty.fetch("any_key")
  end
end
