# frozen_string_literal: true

class Chat < ApplicationRecord
  acts_as_chat

  # Inverse of GenerationRequest#belongs_to :chat — enables Message broadcasts
  # to resolve their target stream via msg.chat.generation_request (#13).
  has_one :generation_request
end
