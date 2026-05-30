require "test_helper"

class EndpointTest < ActiveSupport::TestCase
  # --- validations ---

  test "should be valid with required attributes" do
    endpoint = Endpoint.new(script: "events.all")
    assert endpoint.valid?, endpoint.errors.full_messages.inspect
  end

  test "should be invalid without script" do
    endpoint = Endpoint.new(script: nil)
    assert_not endpoint.valid?
    assert_includes endpoint.errors[:script], "can't be blank"
  end

  test "should auto-generate slug even when whitespace-only slug is provided" do
    # blank? is true for whitespace, so generate_slug replaces it
    endpoint = Endpoint.new(script: "events.all", slug: "  ")
    endpoint.valid?
    assert_match(/\A[A-Za-z0-9_\-]+\z/, endpoint.slug)
  end

  test "should be invalid when slug is not unique" do
    existing = endpoints(:active_endpoint)
    duplicate = Endpoint.new(script: "events.all", slug: existing.slug)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end

  # --- auto slug generation ---

  test "should auto-generate slug when not provided" do
    endpoint = Endpoint.new(script: "events.all")
    endpoint.valid?
    assert_not_nil endpoint.slug
    assert_not_empty endpoint.slug
  end

  test "should not override an explicitly provided slug" do
    endpoint = Endpoint.new(script: "events.all", slug: "my-custom-slug")
    endpoint.valid?
    assert_equal "my-custom-slug", endpoint.slug
  end

  test "generated slugs are URL-safe" do
    endpoint = Endpoint.new(script: "events.all")
    endpoint.valid?
    assert_match(/\A[A-Za-z0-9_\-]+\z/, endpoint.slug)
  end

  # --- status enum ---

  test "default status is active" do
    endpoint = Endpoint.create!(script: "events.all")
    assert_equal "active", endpoint.status
    assert endpoint.active?
  end

  test "active? returns true for active status" do
    endpoint = endpoints(:active_endpoint)
    assert endpoint.active?
  end

  test "should be invalid with unknown status" do
    endpoint = Endpoint.new(script: "events.all", status: "unknown")
    assert_not endpoint.valid?
    assert_includes endpoint.errors[:status], "is not included in the list"
  end
end
