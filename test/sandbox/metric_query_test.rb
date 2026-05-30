# frozen_string_literal: true

require "test_helper"

# Integration tests for MetricQuery — the DCI Interaction role that exposes
# read-only Metric aggregations to mruby scripts running in the Kobako sandbox.
#
# MetricQuery delegates to Metric class methods (which aggregate Event records),
# wrapping each call in connected_to(role: :reading) to enforce the SQL
# boundary layer.  All return values are wire-representable (Integer, Array, Hash
# with String/Integer/Date-serialized keys).
class MetricQueryTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @today = Date.current
    @query = MetricQuery.new
  end

  # --- daily_counts ---

  test "daily_counts returns a Hash" do
    result = @query.daily_counts(since: @today - 2)
    assert_kind_of Hash, result
  end

  test "daily_counts keys are ISO-8601 date Strings (wire-representable)" do
    result = @query.daily_counts(since: @today - 2)
    result.each_key do |k|
      assert_kind_of String, k, "expected String key, got #{k.class}"
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, k)
    end
  end

  test "daily_counts values are Integers (wire-representable)" do
    result = @query.daily_counts(since: @today - 2)
    result.each_value { |v| assert_kind_of Integer, v }
  end

  test "daily_counts covers every day from since to today inclusive" do
    result = @query.daily_counts(since: @today - 3)
    assert_equal 4, result.size
  end

  test "daily_counts zero-pads days with no events" do
    result = @query.daily_counts(since: @today - 2)
    result.each_value { |v| assert_equal 0, v }
  end

  test "daily_counts counts events correctly" do
    Event.create!(occurred_at: @today.beginning_of_day, name: "page_view")
    Event.create!(occurred_at: @today.beginning_of_day, name: "page_view")
    Event.create!(occurred_at: (@today - 1).beginning_of_day, name: "page_view")

    result = @query.daily_counts(since: @today - 1)

    assert_equal 2, result[@today.iso8601]
    assert_equal 1, result[(@today - 1).iso8601]
  end

  test "daily_counts accepts a name filter" do
    Event.create!(occurred_at: @today.beginning_of_day, name: "page_view")
    Event.create!(occurred_at: @today.beginning_of_day, name: "button_click")

    result = @query.daily_counts(since: @today, name: "page_view")

    assert_equal 1, result[@today.iso8601]
  end

  test "daily_counts accepts since as an ISO-8601 String" do
    result = @query.daily_counts(since: (@today - 1).iso8601)
    assert_kind_of Hash, result
    assert_equal 2, result.size
  end

  # --- top_names ---

  test "top_names returns an Array" do
    assert_kind_of Array, @query.top_names
  end

  test "top_names elements are Arrays of [String, Integer] (wire-representable)" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    rows = @query.top_names
    rows.each do |pair|
      assert_kind_of Array, pair
      assert_equal 2, pair.size
      assert_kind_of String, pair[0]
      assert_kind_of Integer, pair[1]
    end
  end

  test "top_names returns names sorted by count descending" do
    3.times { Event.create!(occurred_at: Time.current, name: "page_view") }
    1.times { Event.create!(occurred_at: Time.current, name: "button_click") }
    2.times { Event.create!(occurred_at: Time.current, name: "form_submit") }

    result = @query.top_names(limit: 3)
    assert_equal %w[page_view form_submit button_click], result.map(&:first)
  end

  test "top_names respects limit" do
    %w[a b c d].each { |n| Event.create!(occurred_at: Time.current, name: n) }
    assert_equal 2, @query.top_names(limit: 2).size
  end

  test "top_names default limit is 10" do
    12.times { |i| Event.create!(occurred_at: Time.current, name: "event_#{i}") }
    assert_equal 10, @query.top_names.size
  end

  # --- total_count ---

  test "total_count returns an Integer" do
    assert_kind_of Integer, @query.total_count
  end

  test "total_count returns 0 when no events" do
    assert_equal 0, @query.total_count
  end

  test "total_count returns count of all events" do
    Event.create!(occurred_at: Time.current, name: "ping")
    Event.create!(occurred_at: Time.current, name: "pong")
    assert_equal 2, @query.total_count
  end

  test "total_count filters by name when given" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")
    assert_equal 1, @query.total_count(name: "page_view")
  end

  # --- reading connection (SQL boundary) ---

  test "total_count does not raise when called within reading role" do
    assert_nothing_raised do
      ApplicationRecord.connected_to(role: :reading) { @query.total_count }
    end
  end

  test "daily_counts does not raise when called within reading role" do
    assert_nothing_raised do
      ApplicationRecord.connected_to(role: :reading) { @query.daily_counts(since: @today) }
    end
  end
end
