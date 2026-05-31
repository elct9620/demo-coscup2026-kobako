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
  # GET /endpoints (index) — list of live endpoints
  # ---------------------------------------------------------------------------

  test "GET /endpoints returns 200" do
    get endpoints_path
    assert_response :ok
  end

  test "GET /endpoints links each endpoint to its live replay URL" do
    endpoint = endpoints(:active_endpoint)
    get endpoints_path
    assert_select "a[href=?]", dynamic_endpoint_path(endpoint.slug)
  end

  test "GET /endpoints shows the originating requirement for an endpoint" do
    get endpoints_path
    assert_includes @response.body, "count page_view events"
  end

  test "GET /endpoints offers the inject-events control" do
    get endpoints_path
    assert_select "form[action=?][method=post]", demo_events_path
  end

  test "GET /endpoints renders an empty state linking to the form when none exist" do
    GenerationRequest.update_all(endpoint_id: nil)
    Endpoint.delete_all
    get endpoints_path
    assert_response :ok
    assert_select "a[href=?]", new_endpoint_path
  end

  # ---------------------------------------------------------------------------
  # DELETE /endpoints/reset — clear the board back to the fresh-demo state
  # ---------------------------------------------------------------------------

  # Build a realistic generation footprint: an endpoint with its originating
  # GenerationRequest, the Chat that produced it, and a message + tool call —
  # mirroring what EndpointGeneration leaves behind so the cascade is exercised.
  def seed_generation_footprint
    chat = Chat.create!
    msg  = Message.new(role: :assistant, content: nil, chat: chat)
    msg.save!(validate: false)
    msg.tool_calls.create!(tool_call_id: "call_reset", name: "submit_endpoint",
                           arguments: { "script" => "events.count" })
    endpoint = Endpoint.create!(script: "events.count")
    GenerationRequest.create!(requirement: "count events", chat: chat).succeeded!(endpoint: endpoint)
  end

  test "DELETE /endpoints/reset removes every endpoint" do
    seed_generation_footprint
    assert_operator Endpoint.count, :>, 0

    delete reset_endpoints_path

    assert_equal 0, Endpoint.count
  end

  test "DELETE /endpoints/reset removes generation requests, chats and messages" do
    seed_generation_footprint

    delete reset_endpoints_path

    assert_equal 0, GenerationRequest.count
    assert_equal 0, Chat.count
    assert_equal 0, Message.count
  end

  test "DELETE /endpoints/reset preserves the event data" do
    seed_generation_footprint
    events_before = Event.count
    assert_operator events_before, :>, 0

    delete reset_endpoints_path

    assert_equal events_before, Event.count
  end

  test "DELETE /endpoints/reset redirects to the index with a notice" do
    delete reset_endpoints_path

    assert_redirected_to endpoints_path
    assert flash[:notice].present?
  end

  test "GET /endpoints offers the reset control" do
    get endpoints_path
    assert_select "form[action=?][method=post]", reset_endpoints_path
  end

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

  # The form offers several one-click example prompts (not just one) so the
  # operator can demo the range of capabilities on stage — Params-driven
  # queries, aggregations, detail listings, relative time. Each is a button
  # wired to the examples Stimulus controller's fill action.
  test "GET /endpoints/new offers multiple one-click example prompts" do
    get new_endpoint_path
    assert_select "button[data-action='examples#fill']", minimum: 3
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

  # The log streams entries via Turbo Stream append. Its scroll viewport fills
  # the remaining viewport height (flex-fill, not a fixed fraction) so it adapts
  # to any projector resolution, and the generation-log Stimulus controller
  # keeps it pinned to the newest entry. These guard that markup contract: the
  # append target lives inside the controller-bound, height-filling scroll box.
  test "GET /endpoints/:id nests the generation log inside the auto-scroll viewport" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    assert_select "[data-controller='generation-log'] [id='generation_log_#{gr.id}']"
  end

  test "GET /endpoints/:id makes the log viewport fill the remaining height and scroll" do
    gr = GenerationRequest.create!(requirement: "count all events")

    get endpoint_path(gr)

    viewport = css_select("[data-controller='generation-log']").first
    assert_includes viewport["class"], "flex-1"
    assert_includes viewport["class"], "min-h-0"
    assert_includes viewport["class"], "overflow-y-auto"
  end
end
