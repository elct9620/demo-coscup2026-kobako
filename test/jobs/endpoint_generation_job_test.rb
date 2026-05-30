# frozen_string_literal: true

require "test_helper"

# Tests for EndpointGenerationJob — the ActiveJob wrapper that runs the
# EndpointGeneration context in the background via SolidQueue (production)
# or the :async adapter (development).
#
# Signature change from #12:
#   Old (pre-#12): perform(requirement)
#   New (post-#12): perform(generation_request_id)
#
#   The Job now looks up the GenerationRequest by id, reads its requirement,
#   calls EndpointGeneration, and updates the record's status.
#
# Mock strategy:
#   EndpointGeneration is intercepted at the class level — same technique
#   as before (define_singleton_method on .new).
#
#   GenerationRequest records are created in the test DB; no mocking needed
#   for Data.
#
# Queue adapter:
#   ActiveJob::TestCase sets the queue adapter to :test automatically.
class EndpointGenerationJobTest < ActiveJob::TestCase
  REQUIREMENT = "count all events"

  setup do
    @generation_request = GenerationRequest.create!(requirement: REQUIREMENT)
  end

  # ---------------------------------------------------------------------------
  # Enqueue behaviour
  # ---------------------------------------------------------------------------

  test "enqueues on the default queue" do
    assert_enqueued_with(job: EndpointGenerationJob, queue: "default") do
      EndpointGenerationJob.perform_later(@generation_request.id)
    end
  end

  test "enqueues with the generation_request_id argument" do
    assert_enqueued_with(job: EndpointGenerationJob, args: [ @generation_request.id ]) do
      EndpointGenerationJob.perform_later(@generation_request.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------------------

  test "calls EndpointGeneration with the requirement from the record" do
    received_requirement = nil
    endpoint = Endpoint.new(script: "Service::Events.all.count")

    with_fake_generation(->(req) { received_requirement = req; { ok: true, endpoint: endpoint } }) do
      EndpointGenerationJob.perform_now(@generation_request.id)
    end

    assert_equal REQUIREMENT, received_requirement
  end

  test "updates GenerationRequest to succeeded on ok:true" do
    endpoint = Endpoint.create!(script: "Service::Events.count")

    with_fake_generation(->(_req) { { ok: true, endpoint: endpoint } }) do
      EndpointGenerationJob.perform_now(@generation_request.id)
    end

    assert @generation_request.reload.succeeded?
    assert_equal endpoint, @generation_request.reload.endpoint
  end

  test "logs success with the endpoint slug on ok:true" do
    endpoint = endpoints(:active_endpoint)

    with_fake_generation(->(_req) { { ok: true, endpoint: endpoint } }) do
      assert_logged(/Generated endpoint.*#{endpoint.slug}/i) do
        EndpointGenerationJob.perform_now(@generation_request.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Failure path (ok: false — context absorbed the IterationLimitError)
  # ---------------------------------------------------------------------------

  test "updates GenerationRequest to failed on ok:false" do
    error_msg = "Stopped after 5 iterations without success."

    with_fake_generation(->(_req) { { ok: false, error: error_msg } }) do
      EndpointGenerationJob.perform_now(@generation_request.id)
    end

    assert @generation_request.reload.failed?
    assert_equal error_msg, @generation_request.reload.error_message
  end

  test "logs failure message on ok:false" do
    error_msg = "Stopped after 5 iterations without success."

    with_fake_generation(->(_req) { { ok: false, error: error_msg } }) do
      assert_logged(/Failed to generate endpoint.*Stopped after 5 iterations/i) do
        EndpointGenerationJob.perform_now(@generation_request.id)
      end
    end
  end

  test "does not raise when EndpointGeneration returns ok:false" do
    with_fake_generation(->(_req) { { ok: false, error: "generation failed" } }) do
      assert_nothing_raised do
        EndpointGenerationJob.perform_now(@generation_request.id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Infrastructure error path (e.g. LMStudio connection refused)
  # ---------------------------------------------------------------------------

  test "propagates unexpected infrastructure errors so the queue can retry" do
    with_fake_generation(->(_req) { raise RuntimeError, "connection refused" }) do
      assert_raises(RuntimeError) do
        EndpointGenerationJob.perform_now(@generation_request.id)
      end
    end
  end

  private

  # Temporarily replaces EndpointGeneration.new so that it returns a fake
  # context whose #call delegates to +call_proc+.  The original .new is
  # restored after the block returns (or raises).
  #
  # @param call_proc [Proc]  called with the requirement; return value becomes
  #                          the result of context#call.  May raise freely.
  def with_fake_generation(call_proc)
    original_new = EndpointGeneration.method(:new)

    EndpointGeneration.define_singleton_method(:new) do |req|
      proc_to_call = call_proc
      Object.new.tap do |ctx|
        ctx.define_singleton_method(:call) { proc_to_call.call(req) }
      end
    end

    yield
  ensure
    EndpointGeneration.singleton_class.undef_method(:new)
    EndpointGeneration.define_singleton_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end

  # Temporarily replaces Rails.logger with an in-memory logger and asserts
  # that at least one log line within the block matches +pattern+.
  def assert_logged(pattern)
    log_io     = StringIO.new
    tmp_logger = ActiveSupport::TaggedLogging.new(Logger.new(log_io))
    original   = Rails.logger

    Rails.logger = tmp_logger
    yield
  ensure
    Rails.logger = original
    assert_match pattern, log_io.string,
                 "Expected log output to match #{pattern.inspect}"
  end
end
