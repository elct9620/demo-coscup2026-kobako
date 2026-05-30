# frozen_string_literal: true

require "test_helper"

# Tests for EndpointGenerationJob — the ActiveJob wrapper that runs the
# EndpointGeneration context in the background via SolidQueue (production)
# or the :async adapter (development).
#
# Mock strategy:
#   EndpointGeneration is intercepted at the class level by temporarily
#   redefining EndpointGeneration.new via define_singleton_method, then
#   restoring the original method.  This avoids any mocking library and
#   works with Minitest 6 (which removed minitest/mock).
#
#   All test doubles are simple PORO fakes defined inline — no framework
#   dependency required.
#
#   EndpointGeneration internals are tested separately in
#   test/contexts/endpoint_generation_test.rb — not duplicated here.
#
# Queue adapter:
#   ActiveJob::TestCase sets the queue adapter to :test automatically, so
#   assert_enqueued_with / perform_enqueued_jobs work without a real worker.
class EndpointGenerationJobTest < ActiveJob::TestCase
  REQUIREMENT = "count all events"

  # ---------------------------------------------------------------------------
  # Enqueue behaviour
  # ---------------------------------------------------------------------------

  test "enqueues on the default queue" do
    assert_enqueued_with(job: EndpointGenerationJob, queue: "default") do
      EndpointGenerationJob.perform_later(REQUIREMENT)
    end
  end

  test "enqueues with the requirement argument" do
    assert_enqueued_with(job: EndpointGenerationJob, args: [ REQUIREMENT ]) do
      EndpointGenerationJob.perform_later(REQUIREMENT)
    end
  end

  # ---------------------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------------------

  test "calls EndpointGeneration with the given requirement" do
    received_requirement = nil
    endpoint = Endpoint.new(script: "Service::Events.all.count")

    with_fake_generation(->(req) { received_requirement = req; { ok: true, endpoint: endpoint } }) do
      EndpointGenerationJob.perform_now(REQUIREMENT)
    end

    assert_equal REQUIREMENT, received_requirement
  end

  test "logs success with the endpoint slug on ok:true" do
    endpoint = endpoints(:active_endpoint)

    with_fake_generation(->(_req) { { ok: true, endpoint: endpoint } }) do
      assert_logged(/Generated endpoint.*#{endpoint.slug}/i) do
        EndpointGenerationJob.perform_now(REQUIREMENT)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Failure path (ok: false — context absorbed the IterationLimitError)
  # ---------------------------------------------------------------------------

  test "logs failure message on ok:false" do
    error_msg = "Stopped after 5 iterations without success."

    with_fake_generation(->(_req) { { ok: false, error: error_msg } }) do
      assert_logged(/Failed to generate endpoint.*Stopped after 5 iterations/i) do
        EndpointGenerationJob.perform_now(REQUIREMENT)
      end
    end
  end

  test "does not raise when EndpointGeneration returns ok:false" do
    with_fake_generation(->(_req) { { ok: false, error: "generation failed" } }) do
      assert_nothing_raised do
        EndpointGenerationJob.perform_now(REQUIREMENT)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Infrastructure error path (e.g. LMStudio connection refused)
  # ---------------------------------------------------------------------------

  test "propagates unexpected infrastructure errors so the queue can retry" do
    with_fake_generation(->(_req) { raise RuntimeError, "connection refused" }) do
      assert_raises(RuntimeError) do
        EndpointGenerationJob.perform_now(REQUIREMENT)
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

    # Minitest 6 removed mock.rb; Job has no agent-style injection seam.
    # Override .new at the singleton level so the Job's call site is unchanged.
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
