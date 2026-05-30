# frozen_string_literal: true

# ActiveJob wrapper that runs EndpointGeneration in the background.
#
# In production, SolidQueue dispatches this job.  In development the :async
# adapter runs it in a thread-pool; in test the :test adapter provides
# assert_enqueued_with / perform_enqueued_jobs without starting a real worker.
#
# Responsibilities (this job):
#   - Enqueue EndpointGeneration on the default queue.
#   - Update the GenerationRequest record with the outcome (succeeded / failed).
#   - Log success (endpoint slug) or failure (error message).
#   - Propagate unexpected infrastructure errors (e.g. LMStudio unreachable)
#     so the queue adapter can apply its retry / dead-letter policy.
#
# GenerationRequest lifecycle:
#   pending  (created by EndpointsController#create)
#     → succeeded  (EndpointGeneration returned ok:true)
#     → failed     (EndpointGeneration returned ok:false)
#
# #13 Streaming:
#   A persisted Chat is created and linked to the GenerationRequest before
#   generation starts.  Message after_create_commit broadcasts each agent turn
#   to the operator's show page in real time via Turbo Stream.
#
# Dependency direction (docs/architecture.md):
#   Job → Context (EndpointGeneration)
#   Job → Data    (GenerationRequest, for status update)
#   Data does NOT depend on Context.
class EndpointGenerationJob < ApplicationJob
  queue_as :default

  # @param generation_request_id [Integer]  id of the GenerationRequest record
  def perform(generation_request_id)
    generation_request = GenerationRequest.find(generation_request_id)

    # #13 — create and wire a persisted Chat so each Message/ToolCall round
    # triggers after_create_commit broadcast callbacks on the Message model,
    # enabling real-time streaming to the operator show page.
    chat = Chat.create!
    generation_request.update!(chat: chat)

    result = EndpointGeneration.new(generation_request.requirement, chat: chat).call

    if result[:ok]
      generation_request.succeeded!(endpoint: result[:endpoint])
      Rails.logger.info "Generated endpoint: slug=#{result[:endpoint].slug} " \
                        "requirement=#{generation_request.requirement.inspect}"
    else
      generation_request.failed!(error_message: result[:error])
      Rails.logger.warn "Failed to generate endpoint: #{result[:error]} " \
                        "requirement=#{generation_request.requirement.inspect}"
    end
  end
end
