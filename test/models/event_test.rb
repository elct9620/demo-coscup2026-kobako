require "test_helper"

class EventTest < ActiveSupport::TestCase
  # --- validations ---

  test "should be valid with required attributes" do
    event = Event.new(occurred_at: Time.current, name: "page_view", properties: {})
    assert event.valid?
  end

  test "should be invalid without name" do
    event = Event.new(occurred_at: Time.current, name: nil)
    assert_not event.valid?
    assert_includes event.errors[:name], "can't be blank"
  end

  test "should be invalid without occurred_at" do
    event = Event.new(occurred_at: nil, name: "page_view")
    assert_not event.valid?
    assert_includes event.errors[:occurred_at], "can't be blank"
  end

  # --- scopes ---

  test "recent_days returns events within the given number of days" do
    old_event = events(:old_page_view)
    recent_event = events(:recent_page_view)

    results = Event.recent_days(7)
    assert_includes results, recent_event
    assert_not_includes results, old_event
  end

  test "by_name filters events by exact name" do
    page_view = events(:recent_page_view)
    click = events(:button_click)

    assert_includes Event.by_name("page_view"), page_view
    assert_not_includes Event.by_name("page_view"), click
  end

  test "occurring_on returns events for a specific date" do
    target = events(:recent_page_view)
    results = Event.occurring_on(target.occurred_at.to_date)

    assert_includes results, target
  end

  # --- JSON properties ---

  test "properties defaults to empty hash" do
    event = Event.create!(occurred_at: Time.current, name: "ping")
    assert_equal({}, event.reload.properties)
  end

  test "properties stores and retrieves nested hash" do
    props = { "path" => "/home", "user_agent" => "Mozilla" }
    event = Event.create!(occurred_at: Time.current, name: "page_view", properties: props)
    assert_equal props, event.reload.properties
  end
end
