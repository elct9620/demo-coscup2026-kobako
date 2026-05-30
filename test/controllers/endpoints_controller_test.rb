# frozen_string_literal: true

require "test_helper"

# Integration tests for EndpointsController — the operator-facing generation UI.
#
# Scope (this controller):
#   GET  /endpoints/new  → render the requirement form
#   POST /endpoints      → create GenerationRequest, enqueue job, redirect to show
#   GET  /endpoints/:id  → show generation status (pending / succeeded / failed)
#
# NOT tested here:
#   - Real LMStudio calls (job is only enqueued, not performed)
#   - Turbo Stream broadcasts (#13)
#
# Security (coding:security STRIDE):
#   T (Tampering): requirement is untrusted user input — controller passes it to
#     GenerationRequest.new only; it is never interpolated into queries or scripts.
#   D (DoS): the controller only enqueues the job; the sandbox timeout is enforced
#     inside ReadOnlySandbox, not here.
#   E (EoP): no privileged operations; no auth in this demo.
class EndpointsControllerTest < ActionDispatch::IntegrationTest
  # ---------------------------------------------------------------------------
  # GET /endpoints/new
  # ---------------------------------------------------------------------------

  test "GET /endpoints/new returns 200" do
    get new_endpoint_path
    assert_response :ok
  end

  test "GET /endpoints/new renders the requirement form" do
    get new_endpoint_path
    assert_select "form[action='#{endpoints_path}']"
    assert_select "textarea[name='generation_request[requirement]']"
  end

  # ---------------------------------------------------------------------------
  # POST /endpoints (create)
  # ---------------------------------------------------------------------------

  test "POST /endpoints creates a GenerationRequest record" do
    assert_difference "GenerationRequest.count", 1 do
      post endpoints_path, params: { generation_request: { requirement: "count all events" } }
    end
  end

  test "POST /endpoints creates a GenerationRequest with the given requirement" do
    post endpoints_path, params: { generation_request: { requirement: "count all events" } }

    gr = GenerationRequest.last
    assert_equal "count all events", gr.requirement
  end

  test "POST /endpoints creates a GenerationRequest with pending status" do
    post endpoints_path, params: { generation_request: { requirement: "count all events" } }

    gr = GenerationRequest.last
    assert gr.pending?
  end

  test "POST /endpoints enqueues EndpointGenerationJob" do
    assert_enqueued_with(job: EndpointGenerationJob) do
      post endpoints_path, params: { generation_request: { requirement: "count all events" } }
    end
  end

  test "POST /endpoints enqueues job with the generation_request id" do
    assert_enqueued_with(job: EndpointGenerationJob) do
      post endpoints_path, params: { generation_request: { requirement: "count all events" } }
    end

    gr = GenerationRequest.last
    job_args = ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args]
    assert_equal gr.id, job_args.first
  end

  test "POST /endpoints redirects to the generation request show page" do
    post endpoints_path, params: { generation_request: { requirement: "count all events" } }

    gr = GenerationRequest.last
    assert_redirected_to endpoint_path(gr)
  end

  test "POST /endpoints with blank requirement does not create a record" do
    assert_no_difference "GenerationRequest.count" do
      post endpoints_path, params: { generation_request: { requirement: "" } }
    end
  end

  test "POST /endpoints with blank requirement re-renders the form" do
    post endpoints_path, params: { generation_request: { requirement: "" } }
    assert_response :unprocessable_entity
  end

  # ---------------------------------------------------------------------------
  # GET /endpoints/:id (show)
  # ---------------------------------------------------------------------------

  test "GET /endpoints/:id returns 200 for a pending request" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    assert_response :ok
  end

  test "GET /endpoints/:id shows pending state" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    assert_select "[id='#{ActionView::RecordIdentifier.dom_id(gr)}-status']"
  end

  test "GET /endpoints/:id shows the endpoint URL on success" do
    endpoint = Endpoint.create!(script: "Service::Events.count")
    gr = GenerationRequest.create!(requirement: "count all events")
    gr.succeeded!(endpoint: endpoint)

    get endpoint_path(gr)

    assert_response :ok
    assert_select "a[href='#{dynamic_endpoint_path(endpoint.slug)}']"
  end

  test "GET /endpoints/:id shows the error message on failure" do
    gr = GenerationRequest.create!(requirement: "count all events")
    gr.failed!(error_message: "Stopped after 5 iterations without success.")

    get endpoint_path(gr)

    assert_response :ok
    assert_select "p", text: /Stopped after 5 iterations/
  end

  test "GET /endpoints/:id returns 404 for unknown id" do
    get endpoint_path(id: 9_999_999)
    assert_response :not_found
  end

  # ---------------------------------------------------------------------------
  # Turbo Stream subscription (#13)
  # ---------------------------------------------------------------------------

  test "GET /endpoints/:id includes turbo-cable-stream-source element for live updates" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    assert_select "turbo-cable-stream-source", minimum: 1
  end

  test "GET /endpoints/:id includes the generation log target div" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    assert_select "[id='generation_log_#{gr.id}']"
  end
end
