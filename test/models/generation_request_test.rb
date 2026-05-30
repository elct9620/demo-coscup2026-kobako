# frozen_string_literal: true

require "test_helper"
require "turbo/broadcastable/test_helper"

# Unit tests for GenerationRequest model.
#
# GenerationRequest is the anchor record for one operator-initiated generation
# attempt.  It tracks lifecycle state (pending → succeeded / failed) so the UI
# can display progress without polling the job queue.
#
# It is also the Turbo Stream target for #13 real-time streaming: dom_id(record)
# produces a stable CSS selector that EndpointGenerationJob can broadcast to.
class GenerationRequestTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper
  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------

  test "is valid with a requirement and pending status" do
    gr = GenerationRequest.new(requirement: "count all events")
    assert gr.valid?, gr.errors.full_messages.inspect
  end

  test "is invalid without a requirement" do
    gr = GenerationRequest.new(requirement: nil)
    assert_not gr.valid?
    assert_includes gr.errors[:requirement], "can't be blank"
  end

  test "is invalid with a blank requirement" do
    gr = GenerationRequest.new(requirement: "   ")
    assert_not gr.valid?
  end

  test "is invalid without a status" do
    gr = GenerationRequest.new(requirement: "count all events", status: nil)
    assert_not gr.valid?
  end

  test "is invalid with an unknown status" do
    # Rails enum with validate: true adds an error rather than raising.
    gr = GenerationRequest.new(requirement: "r", status: "unknown")
    assert_not gr.valid?
    assert gr.errors[:status].any?
  end

  # ---------------------------------------------------------------------------
  # Default status
  # ---------------------------------------------------------------------------

  test "defaults to pending status" do
    gr = GenerationRequest.create!(requirement: "count all events")
    assert gr.pending?
  end

  # ---------------------------------------------------------------------------
  # Status transitions
  # ---------------------------------------------------------------------------

  test "can transition from pending to succeeded" do
    gr = GenerationRequest.create!(requirement: "count all events")
    endpoint = Endpoint.create!(script: "Service::Events.count")

    gr.succeeded!(endpoint: endpoint)

    assert gr.succeeded?
    assert_equal endpoint, gr.reload.endpoint
  end

  test "can transition from pending to failed" do
    gr = GenerationRequest.create!(requirement: "count all events")

    gr.failed!(error_message: "Stopped after 5 iterations without success.")

    assert gr.failed?
    assert_equal "Stopped after 5 iterations without success.", gr.reload.error_message
  end

  # ---------------------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------------------

  test "belongs_to endpoint (optional)" do
    gr = GenerationRequest.create!(requirement: "count all events")
    assert_nil gr.endpoint
  end

  test "belongs_to chat (optional)" do
    gr = GenerationRequest.create!(requirement: "count all events")
    assert_nil gr.chat
  end

  # ---------------------------------------------------------------------------
  # Turbo Stream anchor
  # ---------------------------------------------------------------------------

  test "dom_id is stable and usable as Turbo Stream target" do
    gr = GenerationRequest.create!(requirement: "count all events")
    assert_match(/generation_request_\d+/, ActionView::RecordIdentifier.dom_id(gr))
  end

  # ---------------------------------------------------------------------------
  # Turbo Stream broadcast — status updates (#13)
  # ---------------------------------------------------------------------------
  #
  # After succeeded! or failed! the status frame on the show page must refresh.
  # We use after_update_commit to broadcast a replace of the status partial.
  #
  # Same transactional-test caveat as MessageTest: we invoke the private
  # broadcast method directly to bypass the rolled-back test transaction.
  # ---------------------------------------------------------------------------

  test "broadcast_status_to_self sends a turbo stream replace to the generation request" do
    gr = GenerationRequest.create!(requirement: "count events")

    assert_turbo_stream_broadcasts gr do
      gr.send(:broadcast_status_to_self)
    end
  end

  test "broadcast_status_to_self swallows Action Cable errors" do
    gr = GenerationRequest.create!(requirement: "count events")

    def gr.broadcast_replace_to(*_args, **_kwargs)
      raise "Cable down"
    end

    assert_nothing_raised do
      gr.send(:broadcast_status_to_self)
    end
  end
end
