# frozen_string_literal: true

class Message < ApplicationRecord
  acts_as_message

  # #13 — broadcast each new message to the generation request's Turbo Stream
  # so the operator sees each agent turn in real time.
  #
  # Stream target: the GenerationRequest linked via chat.generation_request.
  # Guard: when no GenerationRequest is linked (e.g. standalone chat), the
  # lambda returns nil and no broadcast is sent.
  #
  # Isolation guarantee: the callback fires in after_create_commit — after the
  # message row is already committed.  Any Action Cable error is rescued and
  # logged; it cannot roll back the committed row or propagate to the caller.
  # This satisfies SPEC "可視化串流中斷不影響端點產出".
  after_create_commit :broadcast_message_to_generation_request

  private

  def broadcast_message_to_generation_request
    generation_request = chat&.generation_request
    return unless generation_request

    broadcast_append_to(
      generation_request,
      target: "generation_log_#{generation_request.id}",
      partial: "messages/message",
      locals: { message: self }
    )
  rescue StandardError => e
    Rails.logger.warn "[Message#broadcast] Turbo Stream broadcast failed (stream continues): #{e.message}"
  end
end
