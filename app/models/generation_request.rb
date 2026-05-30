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
end
