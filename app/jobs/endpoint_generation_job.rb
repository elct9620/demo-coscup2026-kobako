# frozen_string_literal: true

# ActiveJob wrapper that runs EndpointGeneration in the background.
#
# In production, SolidQueue dispatches this job.  In development the :async
# adapter runs it in a thread-pool; in test the :test adapter provides
# assert_enqueued_with / perform_enqueued_jobs without starting a real worker.
#
# Responsibilities (this job):
#   - Enqueue EndpointGeneration on the default queue.
#   - Log success (endpoint slug) or failure (error message).
#   - Propagate unexpected infrastructure errors (e.g. LMStudio unreachable)
#     so the queue adapter can apply its retry / dead-letter policy.
#
# Out of scope (left for #12 UI / #13 Streaming):
#   - Broadcasting the result via Turbo Stream — #13 will add Turbo Stream
#     broadcasts either here (via after_perform callback) or inside
#     EndpointGeneration once a persistent Chat record is wired in.
#   - Persisting a "generation request" record — if #12 needs one to show
#     pending status, it will introduce the model and enqueue via that record.
#
# Dependency direction (docs/architecture.md):
#   Job → Context (EndpointGeneration)
#   Job does NOT touch Data directly — endpoint creation stays in the Context.
class EndpointGenerationJob < ApplicationJob
  queue_as :default

  # @param requirement [String]  natural-language description from the operator
  def perform(requirement)
    result = EndpointGeneration.new(requirement).call

    if result[:ok]
      Rails.logger.info "Generated endpoint: slug=#{result[:endpoint].slug} requirement=#{requirement.inspect}"
    else
      Rails.logger.warn "Failed to generate endpoint: #{result[:error]} requirement=#{requirement.inspect}"
    end
  end
end
