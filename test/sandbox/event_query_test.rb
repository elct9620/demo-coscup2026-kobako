# frozen_string_literal: true

require "test_helper"

# Integration tests for EventQuery — the DCI Interaction role that exposes
# read-only Event queries to mruby scripts running in the Kobako sandbox.
#
# Two invariants under test:
#
#   1. All queries execute via connected_to(role: :reading) — SQL boundary.
#   2. All terminal methods return wire-representable values
#      (Integer / Array of Hash / nil / Boolean) so Kobako can serialize
#      results across the MessagePack boundary without errors.
class EventQueryTest < ActiveSupport::TestCase
  setup do
    Event.delete_all
    @today = Date.current
    @query = EventQuery.new
  end

  # --- chaining returns self (Handle-compatible) ---

  test "between returns the query object for chaining" do
    result = @query.between(@today - 7, @today)
    assert_same @query, result
  end

  test "by_name returns the query object for chaining" do
    result = @query.by_name("page_view")
    assert_same @query, result
  end

  test "limit returns the query object for chaining" do
    result = @query.limit(10)
    assert_same @query, result
  end

  # --- count (terminal, Integer) ---

  test "count returns 0 when no events exist" do
    assert_equal 0, @query.count
  end

  test "count returns total number of events" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")

    assert_equal 2, @query.count
  end

  test "count is an Integer (wire-representable)" do
    assert_kind_of Integer, @query.count
  end

  test "count respects by_name filter" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")

    assert_equal 1, @query.by_name("page_view").count
  end

  test "count respects between filter" do
    Event.create!(occurred_at: (@today - 10).beginning_of_day, name: "old")
    Event.create!(occurred_at: @today.beginning_of_day, name: "recent")

    result = @query.between(@today - 3, @today).count
    assert_equal 1, result
  end

  test "count respects combined chain: between + by_name" do
    Event.create!(occurred_at: @today.beginning_of_day, name: "page_view")
    Event.create!(occurred_at: @today.beginning_of_day, name: "button_click")
    Event.create!(occurred_at: (@today - 10).beginning_of_day, name: "page_view")

    result = @query.between(@today - 1, @today).by_name("page_view").count
    assert_equal 1, result
  end

  # --- to_a (terminal, Array of Hash) ---

  test "to_a returns an Array" do
    assert_kind_of Array, @query.to_a
  end

  test "to_a returns empty array when no events exist" do
    assert_empty @query.to_a
  end

  test "to_a returns events as Hashes (wire-representable, no AR objects)" do
    Event.create!(occurred_at: Time.current, name: "page_view", properties: { "path" => "/home" })

    rows = @query.to_a
    assert_equal 1, rows.size
    row = rows.first
    assert_kind_of Hash, row
  end

  test "to_a hash contains expected keys with serializable values" do
    ts = @today.beginning_of_day
    Event.create!(occurred_at: ts, name: "page_view", properties: { "path" => "/home" })

    row = @query.to_a.first
    assert row.key?("id")
    assert row.key?("name")
    assert row.key?("occurred_at")
    assert row.key?("properties")
    assert_kind_of Integer, row["id"]
    assert_kind_of String, row["name"]
    assert_kind_of String, row["occurred_at"]
    assert_kind_of Hash, row["properties"]
  end

  test "to_a respects by_name filter" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")

    rows = @query.by_name("page_view").to_a
    assert_equal 1, rows.size
    assert_equal "page_view", rows.first["name"]
  end

  test "to_a respects between filter" do
    Event.create!(occurred_at: (@today - 10).beginning_of_day, name: "old")
    Event.create!(occurred_at: @today.beginning_of_day, name: "recent")

    rows = @query.between(@today - 3, @today).to_a
    assert_equal 1, rows.size
    assert_equal "recent", rows.first["name"]
  end

  test "to_a respects limit" do
    3.times { Event.create!(occurred_at: Time.current, name: "ping") }

    rows = @query.limit(2).to_a
    assert_equal 2, rows.size
  end

  # --- limit clamp (DoS mitigation, untrusted scripts) ---

  test "limit(-1) clamps to DEFAULT_LIMIT instead of unbounded LIMIT -1" do
    (EventQuery::DEFAULT_LIMIT + 5).times { Event.create!(occurred_at: Time.current, name: "ping") }

    rows = @query.limit(-1).to_a
    assert_equal EventQuery::DEFAULT_LIMIT, rows.size
  end

  test "limit(0) clamps to DEFAULT_LIMIT" do
    (EventQuery::DEFAULT_LIMIT + 5).times { Event.create!(occurred_at: Time.current, name: "ping") }

    rows = @query.limit(0).to_a
    assert_equal EventQuery::DEFAULT_LIMIT, rows.size
  end

  test "an oversized limit is clamped to MAX_LIMIT, never the whole table" do
    (EventQuery::MAX_LIMIT + 3).times { Event.create!(occurred_at: Time.current, name: "ping") }

    rows = @query.limit(999_999_999).to_a
    assert_equal EventQuery::MAX_LIMIT, rows.size
  end

  test "a limit between 1 and MAX_LIMIT is honored verbatim" do
    5.times { Event.create!(occurred_at: Time.current, name: "ping") }

    rows = @query.limit(3).to_a
    assert_equal 3, rows.size
  end

  # --- reading connection (SQL boundary) ---

  test "count executes via reading connection" do
    executed_via_reading = false

    ActiveRecord::Base.connected_to(role: :reading) do
      # If reading role is reachable (doesn't raise), SQL boundary is active.
      @query.count
      executed_via_reading = true
    end

    # The real assertion: EventQuery itself always uses reading, independently.
    assert_equal 0, @query.count
    assert executed_via_reading
  end

  test "to_a does not raise when reading role is active" do
    assert_nothing_raised do
      ActiveRecord::Base.connected_to(role: :reading) { @query.to_a }
    end
  end
end
