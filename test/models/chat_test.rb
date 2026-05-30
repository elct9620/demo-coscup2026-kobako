# frozen_string_literal: true

require "test_helper"

# Unit tests for Chat model — the acts_as_chat AR record that backs the
# EndpointBuilderAgent conversation history.
#
# Scope:
#   - has_one :generation_request inverse association (#13)
#
# Broadcasts are triggered from Message and GenerationRequest, not Chat itself,
# so broadcast assertions live in their respective test files.
class ChatTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Association: has_one :generation_request
  # ---------------------------------------------------------------------------

  test "can have a generation_request" do
    chat = Chat.create!
    gr = GenerationRequest.create!(requirement: "count events", chat: chat)

    assert_equal gr, chat.generation_request
  end

  test "generation_request is nil when no generation_request is linked" do
    chat = Chat.create!

    assert_nil chat.generation_request
  end
end
