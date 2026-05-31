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

  # RubyLLM persists each assistant turn in two phases (chat_methods.rb):
  #   1. before_message → create!(role: :assistant, content: "") — the EMPTY
  #      placeholder appended above by after_create_commit.
  #   2. after_message  → an UPDATE fills role/content and attaches tool_calls.
  # Without re-broadcasting on update the operator only ever sees the empty
  # placeholder ("(empty)").  This replaces it with the filled-in turn so each
  # generated script and sandbox result is actually visible in the live stream.
  after_update_commit :broadcast_completed_message_to_generation_request

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

  def broadcast_completed_message_to_generation_request
    generation_request = chat&.generation_request
    return unless generation_request

    # Render from a freshly-loaded record: the after_create_commit append above
    # already rendered this same instance and cached its (then-empty) tool_calls
    # association, so reusing `self` would re-render without the tool_calls that
    # were attached during the completion UPDATE.
    broadcast_replace_to(
      generation_request,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "messages/message",
      locals: { message: self.class.find(id) }
    )
  rescue StandardError => e
    Rails.logger.warn "[Message#broadcast] Turbo Stream update broadcast failed (stream continues): #{e.message}"
  end
end
