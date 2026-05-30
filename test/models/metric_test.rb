require "test_helper"

class MetricTest < ActiveSupport::TestCase
  # Metric is a pure query object (PORO) — no table, aggregates Event records.
  # MetricQuery sandbox role uses these class methods as its stable API surface.

  setup do
    Event.delete_all
    @today = Date.current
  end

  test "daily_counts returns zero-padded hash for days with no events" do
    result = Metric.daily_counts(since: 3.days.ago.to_date)
    assert_kind_of Hash, result
    assert_equal 4, result.size  # today + 3 prior days
    result.each_value { |v| assert_equal 0, v }
  end

  test "daily_counts counts events per day within range" do
    Event.create!(occurred_at: @today.beginning_of_day + 1.hour, name: "page_view")
    Event.create!(occurred_at: @today.beginning_of_day + 2.hours, name: "page_view")
    Event.create!(occurred_at: (@today - 1).beginning_of_day + 1.hour, name: "page_view")

    result = Metric.daily_counts(since: 2.days.ago.to_date)

    assert_equal 2, result[@today]
    assert_equal 1, result[@today - 1]
    assert_equal 0, result[@today - 2]
  end

  test "daily_counts filters by event name when given" do
    Event.create!(occurred_at: @today.beginning_of_day, name: "page_view")
    Event.create!(occurred_at: @today.beginning_of_day, name: "button_click")

    result = Metric.daily_counts(since: @today, name: "page_view")

    assert_equal 1, result[@today]
  end

  test "top_names returns names ranked by event count descending" do
    3.times { Event.create!(occurred_at: Time.current, name: "page_view") }
    1.times { Event.create!(occurred_at: Time.current, name: "button_click") }
    2.times { Event.create!(occurred_at: Time.current, name: "form_submit") }

    result = Metric.top_names(limit: 3)

    assert_equal [ "page_view", "form_submit", "button_click" ], result.map(&:first)
    assert_equal [ 3, 2, 1 ], result.map(&:last)
  end

  test "top_names respects limit" do
    %w[a b c d].each { |n| Event.create!(occurred_at: Time.current, name: n) }

    result = Metric.top_names(limit: 2)

    assert_equal 2, result.size
  end

  test "total_count returns the count of all events" do
    Event.create!(occurred_at: Time.current, name: "ping")
    Event.create!(occurred_at: Time.current, name: "ping")

    assert_equal 2, Metric.total_count
  end

  test "total_count filters by name when given" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")

    assert_equal 1, Metric.total_count(name: "page_view")
  end
end
