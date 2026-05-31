# frozen_string_literal: true

# Data layer: tracks one operator-initiated endpoint-generation attempt.
#
# Lifecycle (status enum):
#   pending   — job enqueued, generation not yet complete
#   succeeded — EndpointGeneration returned ok:true; endpoint association populated
#   failed    — EndpointGeneration returned ok:false; error_message populated
#
# Turbo Stream anchor (#13):
#   dom_id(generation_request) produces a stable CSS id that
#   EndpointGenerationJob can broadcast to once #13 wires in the chat
#   association and broadcasts_to macro.
#
# Architecture (docs/architecture.md — DCI 三要素):
#   This is thin Data — no business logic.  State transitions are driven by
#   EndpointGenerationJob (the job that calls #succeeded! / #failed!).
#   The EndpointsController creates the record; the Job updates it.
#
# Dependency direction:
#   Data does NOT depend on Context.
class GenerationRequest < ApplicationRecord
  enum :status, { pending: "pending", succeeded: "succeeded", failed: "failed" }, validate: true

  belongs_to :endpoint, optional: true
  belongs_to :chat, optional: true

  validates :requirement, presence: true
  validates :status, presence: true

  # #13 — broadcast status frame replacement after each update so the operator
  # sees the final succeeded / failed state in real time.
  #
  # Isolation guarantee: the broadcast is wrapped in rescue.  Any Action Cable
  # error is logged and swallowed — it cannot roll back the committed row or
  # propagate to EndpointGenerationJob.
  after_update_commit :broadcast_status_to_self

  # Transition to succeeded and persist the associated endpoint in one call.
  #
  # @param endpoint [Endpoint]  the validated, persisted endpoint record
  def succeeded!(endpoint:)
    update!(status: :succeeded, endpoint: endpoint)
  end

  # Transition to failed and record the error message.
  #
  # @param error_message [String]
  def failed!(error_message:)
    update!(status: :failed, error_message: error_message)
  end

  # Messages replayed in the generation log on revisit — the agent's work:
  # assistant turns and tool (sandbox trial) results. The system prompt and the
  # initial user requirement are deliberately excluded: the former is infra
  # noise (a multi-thousand-character prompt), the latter is already shown in
  # the Requirement section above the log.
  #
  # @return [ActiveRecord::Relation<Message>]
  def log_messages
    return Message.none unless chat

    chat.messages.where(role: %w[assistant tool])
  end

  private

  # Broadcast a replace of the status Turbo Frame so the show page updates
  # without a page reload.  Targets the dom_id(self) frame wired in show.html.erb.
  def broadcast_status_to_self
    broadcast_replace_to(
      self,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "endpoints/status",
      locals: { generation_request: self }
    )
  rescue StandardError => e
    Rails.logger.warn "[GenerationRequest#broadcast_status] Turbo Stream broadcast failed (generation unaffected): #{e.message}"
  end
end
