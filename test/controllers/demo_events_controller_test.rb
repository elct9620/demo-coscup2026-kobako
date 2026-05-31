# frozen_string_literal: true

require "test_helper"

# Integration tests for DemoEventsController — the operator's "inject events"
# control on the endpoints board.
#
# Purpose: live on stage the operator injects a fresh batch of events so the
# audience sees an already-live endpoint's output change on the next request,
# proving "每次調用反映當前資料庫狀態".
#
# Security (coding:security STRIDE):
#   D (DoS): count is untrusted input; EventFactory clamps it to MAX_BATCH_SIZE
#     so a hostile/fat-fingered value cannot flood the table.
#   Boundary: this writes through plain ActiveRecord, never the sandbox, so it
#     does not touch the two-layer read-only defense (which governs generated
#     scripts only).
class DemoEventsControllerTest < ActionDispatch::IntegrationTest
  test "POST /demo_events injects the default batch size" do
    assert_difference "Event.count", EventFactory::DEFAULT_BATCH_SIZE do
      post demo_events_path
    end
  end

  test "POST /demo_events with a count injects that many events" do
    assert_difference "Event.count", 5 do
      post demo_events_path, params: { count: 5 }
    end
  end

  test "POST /demo_events clamps an excessive count to the maximum" do
    assert_difference "Event.count", EventFactory::MAX_BATCH_SIZE do
      post demo_events_path, params: { count: 99_999 }
    end
  end

  test "POST /demo_events redirects back to the endpoints index with a notice" do
    post demo_events_path
    assert_redirected_to endpoints_path
    assert_equal "已灌入 #{EventFactory::DEFAULT_BATCH_SIZE} 筆事件", flash[:notice]
  end

  test "injected events are recent so live endpoint queries reflect them" do
    post demo_events_path
    recent = Event.where(occurred_at: 1.hour.ago..Time.current).count
    assert_operator recent, :>=, EventFactory::DEFAULT_BATCH_SIZE
  end
end
