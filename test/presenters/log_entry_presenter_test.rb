# frozen_string_literal: true

require "test_helper"

# Unit tests for LogEntryPresenter — the Message → Markdown mapping that lets the
# whole generation log render through one Markdown pipeline and share one look.
class LogEntryPresenterTest < ActiveSupport::TestCase
  setup { @chat = Chat.create! }

  test "assistant prose passes through as verbatim Markdown" do
    msg = build_message(role: :assistant, content: "Here is **my** analysis.")

    assert_equal "Here is **my** analysis.", LogEntryPresenter.new(msg).to_markdown
  end

  test "blank assistant content becomes the empty placeholder" do
    msg = build_message(role: :assistant, content: nil)

    assert_equal "(empty)", LogEntryPresenter.new(msg).to_markdown
  end

  test "tool call fences the clean script as a ruby block" do
    msg = build_message(role: :assistant)
    msg.tool_calls.create!(tool_call_id: "c1", name: "inspect_query",
                           arguments: { "script" => "Event.count" })

    assert_equal "```ruby\nEvent.count\n```", LogEntryPresenter.new(msg.reload).to_markdown
  end

  test "tool call without a script key falls back to the arguments JSON" do
    msg = build_message(role: :assistant)
    msg.tool_calls.create!(tool_call_id: "c2", name: "other", arguments: { "param" => "value" })

    markdown = LogEntryPresenter.new(msg.reload).to_markdown

    assert_includes markdown, "```ruby"
    assert_includes markdown, '"param"'
  end

  test "tool result fences the sandbox return as a ruby block" do
    msg = build_message(role: :tool, content: "{success: true, result: 2}")

    assert_equal "```ruby\n{success: true, result: 2}\n```", LogEntryPresenter.new(msg).to_markdown
  end

  private

  def build_message(role:, content: nil)
    msg = Message.new(role: role, content: content, chat: @chat)
    msg.save!(validate: false)
    msg.reload
  end
end
