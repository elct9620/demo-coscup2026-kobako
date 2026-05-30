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
# #13 Streaming hook:
#   After updating the GenerationRequest, this job (or EndpointGeneration) can
#   broadcast Turbo Stream updates to the dom_id(generation_request) channel.
#   The chat association on GenerationRequest is reserved for wiring in the
#   persisted RubyLLM Chat that EndpointBuilderAgent uses — enabling per-round
#   streaming of Message/ToolCall records.
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
    result = EndpointGeneration.new(generation_request.requirement).call

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
