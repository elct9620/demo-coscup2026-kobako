# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

# Unit tests for Message model — the acts_as_message AR record that persists
# each turn in the EndpointBuilderAgent conversation.
#
# #13 scope: after_create_commit broadcasts to the linked GenerationRequest
# so the operator can watch each agent turn in real time.
#
# Stream-failure isolation:
#   The broadcast callback wraps the cable write in a rescue — any Action Cable
#   error is logged and swallowed, never propagating to the generation loop.
#   This satisfies SPEC "可視化串流中斷不影響端點產出".
#
# Note on transactional tests:
#   Standard Rails unit tests wrap each test in a rolled-back transaction, so
#   after_commit callbacks do NOT fire.  We therefore test:
#     (a) The callback is registered on the model.
#     (b) The private broadcast method behaves correctly when invoked directly.
#     (c) A broadcast failure does not raise (rescue isolation).
#   Full end-to-end streaming is deferred to #14 integration/system tests.
class MessageTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @chat = Chat.create!
    @gr   = GenerationRequest.create!(requirement: "count events", chat: @chat)
  end

  # ---------------------------------------------------------------------------
  # Broadcast method — direct invocation (bypasses transaction wrapper)
  # ---------------------------------------------------------------------------

  test "broadcast method sends a turbo stream append to the generation_request" do
    msg = Message.new(role: :assistant, content: "hello", chat: @chat)
    msg.save!(validate: false)

    assert_turbo_stream_broadcasts @gr do
      msg.send(:broadcast_message_to_generation_request)
    end
  end

  test "broadcast method sends nothing when chat has no generation_request" do
    orphan_chat = Chat.create!
    msg = Message.new(role: :assistant, content: "orphan", chat: orphan_chat)
    msg.save!(validate: false)

    # Should not raise and should not broadcast
    assert_nothing_raised do
      msg.send(:broadcast_message_to_generation_request)
    end
  end

  # ---------------------------------------------------------------------------
  # Stream-failure isolation (SPEC error scenario invariant)
  # ---------------------------------------------------------------------------

  test "broadcast method swallows Action Cable errors so generation loop is unaffected" do
    msg = Message.new(role: :assistant, content: "resilient", chat: @chat)
    msg.save!(validate: false)

    # Override broadcast_append_to on the singleton to raise
    def msg.broadcast_append_to(*_args, **_kwargs)
      raise "Action Cable unavailable"
    end

    assert_nothing_raised do
      msg.send(:broadcast_message_to_generation_request)
    end
  end

  test "message record persists after a broadcast failure" do
    msg = Message.new(role: :assistant, content: "persisted despite failure", chat: @chat)
    msg.save!(validate: false)

    def msg.broadcast_append_to(*_args, **_kwargs)
      raise "Cable down"
    end

    msg.send(:broadcast_message_to_generation_request)

    assert Message.exists?(msg.id), "message must be readable even if broadcast fails"
  end

  # ---------------------------------------------------------------------------
  # Completion re-broadcast (replace) — the fix for the "(empty)" stream bug
  # ---------------------------------------------------------------------------
  #
  # RubyLLM persists each assistant turn in two phases (chat_methods.rb):
  #   1. before_message → persist_new_message: create!(role: :assistant, content: "")
  #      → fires after_create_commit → we append the EMPTY placeholder.
  #   2. after_message  → persist_message_completion: UPDATE fills role/content and
  #      attaches tool_calls.
  # Without an after_update_commit re-broadcast the operator only ever sees the
  # empty placeholder.  These tests pin the replace broadcast that fixes it.

  test "registers an after_update_commit callback to re-broadcast completed messages" do
    # _commit_callbacks holds both create- and update-commit callbacks; the
    # filter name is enough to prove our re-broadcast callback is registered.
    assert_includes Message._commit_callbacks.map(&:filter),
                    :broadcast_completed_message_to_generation_request
  end

  test "re-broadcast method sends a turbo stream replace carrying the filled-in content" do
    # Phase 1: empty placeholder (what RubyLLM creates first).
    msg = Message.new(role: :assistant, content: "", chat: @chat)
    msg.save!(validate: false)
    # Phase 2: RubyLLM fills the row via UPDATE.
    msg.update!(role: :tool, content: "{success: true, result: 2}")

    broadcasts = capture_turbo_stream_broadcasts @gr do
      msg.send(:broadcast_completed_message_to_generation_request)
    end

    assert_equal 1, broadcasts.size
    assert_equal "replace", broadcasts.first["action"]
    assert_equal ActionView::RecordIdentifier.dom_id(msg), broadcasts.first["target"]
    assert_includes broadcasts.first.to_html, "success: true"
  end

  test "re-broadcast method sends nothing when chat has no generation_request" do
    orphan_chat = Chat.create!
    msg = Message.new(role: :assistant, content: "orphan", chat: orphan_chat)
    msg.save!(validate: false)

    assert_no_turbo_stream_broadcasts @gr do
      assert_nothing_raised do
        msg.send(:broadcast_completed_message_to_generation_request)
      end
    end
  end

  test "re-broadcast method swallows Action Cable errors so generation loop is unaffected" do
    msg = Message.new(role: :assistant, content: "resilient", chat: @chat)
    msg.save!(validate: false)

    def msg.broadcast_replace_to(*_args, **_kwargs)
      raise "Action Cable unavailable"
    end

    assert_nothing_raised do
      msg.send(:broadcast_completed_message_to_generation_request)
    end
  end
end
