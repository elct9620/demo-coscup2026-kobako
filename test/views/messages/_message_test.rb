# frozen_string_literal: true

require "test_helper"

# View tests for messages/_message.html.erb partial.
#
# Guards the core observability feature of the Demo: each agent turn in the
# EndpointBuilderAgent self-verification loop is streamed to the operator via
# Turbo Stream using this partial.
#
# Key invariant: tool_call messages must display the clean script content
# (e.g. "Event.count") rather than the raw JSON wrapper
# (e.g. {"script":"Event.count"}) regardless of whether the ToolCall
# arguments hash uses string keys (DB read-back path) or symbol keys
# (in-memory path).
class MessagePartialTest < ActionView::TestCase
  # ---------------------------------------------------------------------------
  # tool_call message — string-keyed arguments (DB read-back path)
  # ---------------------------------------------------------------------------

  test "renders clean script for tool_call message with string-keyed arguments" do
    chat = Chat.create!
    msg  = Message.new(role: :assistant, content: nil, chat: chat)
    msg.save!(validate: false)

    msg.tool_calls.create!(
      tool_call_id: "call_abc123",
      name: "run_script",
      arguments: { "script" => "Event.count" }
    )

    render partial: "messages/message", locals: { message: msg.reload }

    assert_select "pre", text: "Event.count"
    assert_not_includes rendered, '{"script"'
  end

  # ---------------------------------------------------------------------------
  # tool_call message — symbol-keyed arguments (in-memory / hypothetical path)
  # ---------------------------------------------------------------------------

  test "renders clean script for tool_call message with symbol-keyed arguments" do
    chat = Chat.create!
    msg  = Message.new(role: :assistant, content: nil, chat: chat)
    msg.save!(validate: false)

    # ActiveRecord stores JSON as string keys, but with_indifferent_access must
    # also handle a hash that was constructed with symbol keys.
    msg.tool_calls.create!(
      tool_call_id: "call_def456",
      name: "run_script",
      arguments: { script: "Metric.average(:value)" }
    )

    render partial: "messages/message", locals: { message: msg.reload }

    assert_select "pre", text: "Metric.average(:value)"
    assert_not_includes rendered, '{"script"'
  end

  # ---------------------------------------------------------------------------
  # tool_call message — no :script key (fallback to to_json)
  # ---------------------------------------------------------------------------

  test "falls back to JSON when tool_call arguments have no script key" do
    chat = Chat.create!
    msg  = Message.new(role: :assistant, content: nil, chat: chat)
    msg.save!(validate: false)

    msg.tool_calls.create!(
      tool_call_id: "call_ghi789",
      name: "other_tool",
      arguments: { "param" => "value" }
    )

    render partial: "messages/message", locals: { message: msg.reload }

    assert_includes rendered, "param"
  end

  # ---------------------------------------------------------------------------
  # non-tool_call assistant message (plain content path)
  # ---------------------------------------------------------------------------

  test "renders plain text content for assistant message without tool calls" do
    chat = Chat.create!
    msg  = Message.new(role: :assistant, content: "Here is my analysis.", chat: chat)
    msg.save!(validate: false)

    render partial: "messages/message", locals: { message: msg.reload }

    assert_select "pre", text: "Here is my analysis."
  end
end
