# frozen_string_literal: true

require "test_helper"

# Unit tests for EventFactory — the shared write-side generator for realistic
# demo events.
#
# Two callers depend on this factory (db/seeds.rb for historical seeding,
# DemoEventsController for live injection), so the weighted distribution and
# the per-name property shapes are pinned here rather than duplicated.
#
# Boundary (coding:testing): these assert the factory's own contract — that it
# produces persisted Events with names drawn from the known set and properties
# matching each name. They do not re-test ActiveRecord's create!.
class EventFactoryTest < ActiveSupport::TestCase
  test "sample_name only returns names from the known weighted set" do
    100.times do
      assert_includes EventFactory::EVENT_WEIGHTS.keys, EventFactory.sample_name
    end
  end

  test "properties_for page_view carries path, referrer and duration_ms" do
    props = EventFactory.properties_for("page_view")
    assert_includes EventFactory::PAGES, props["path"]
    assert_includes EventFactory::SOURCES, props["referrer"]
    assert_kind_of Integer, props["duration_ms"]
  end

  test "properties_for an unknown name is an empty hash" do
    assert_equal({}, EventFactory.properties_for("nonexistent_event"))
  end

  test "create persists one Event at the given time with matching properties" do
    at = 3.days.ago
    assert_difference "Event.count", 1 do
      event = EventFactory.create(occurred_at: at, name: "button_click")
      assert_equal "button_click", event.name
      assert_in_delta at.to_f, event.occurred_at.to_f, 1.0
      assert_includes EventFactory::BUTTONS, event.properties["button_id"]
    end
  end

  test "create_recent_batch persists the requested count of recent events" do
    assert_difference "Event.count", 12 do
      created = EventFactory.create_recent_batch(count: 12)
      assert_equal 12, created
    end
  end

  test "create_recent_batch places events within the last hour" do
    EventFactory.create_recent_batch(count: 5)
    Event.order(created_at: :desc).limit(5).each do |event|
      assert_operator event.occurred_at, :>=, 1.hour.ago
      assert_operator event.occurred_at, :<=, Time.current
    end
  end

  test "create_recent_batch clamps the count to the allowed range" do
    assert_difference "Event.count", EventFactory::MAX_BATCH_SIZE do
      EventFactory.create_recent_batch(count: 10_000)
    end
  end

  test "create_recent_batch defaults to DEFAULT_BATCH_SIZE when count is omitted" do
    assert_difference "Event.count", EventFactory::DEFAULT_BATCH_SIZE do
      EventFactory.create_recent_batch
    end
  end
end
