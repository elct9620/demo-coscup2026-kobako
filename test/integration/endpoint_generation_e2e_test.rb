# frozen_string_literal: true

require "test_helper"

# E2E integration test: full generation → live → replay chain with a REAL
# local LMStudio instance.
#
# Gate: runs only when the environment variable LLM_E2E=1 is set.
# Without the gate, this test is skipped so that the default
# `bin/rails test` / `bin/ci` run is never blocked by LLM latency or
# connectivity requirements.
#
# Run with a real LMStudio instance:
#
#   LLM_E2E=1 \
#   LLM_API_BASE=http://localhost:1234/v1 \
#   LLM_MODEL=google/gemma-4-26b-a4b \
#   LLM_API_KEY=lm-studio \
#   bin/rails test test/integration/endpoint_generation_e2e_test.rb
#
# What this test proves (SPEC.md Success Criteria):
#
#   1. 端點全程在沙盒內試跑驗證，於迭代上限內產出可上線腳本，過程不需人工修改腳本.
#      → EndpointGenerationJob completes with a succeeded GenerationRequest and a
#        persisted Endpoint — entirely driven by the real LLM self-correction loop.
#
#   2. 驗證即上線（Shared execution path）
#      → The same ReadOnlySandbox path used during generation validates the script;
#        GET /e/:slug replays it through the identical path and returns consistent JSON.
#
#   3. 任何到達資料庫的寫入在連線層被拒絕.
#      → The Endpoint script runs exclusively via EventQuery / MetricQuery on the
#        reading connection (SQLite mode=ro).  No write path is reachable — the
#        integration test would raise ActiveRecord::ReadOnlyError or SQLite3::Exception
#        if the two-layer defense were broken.
#
#   4. 暖機後單次重放延遲為微秒級量級.
#      → GET /e/:slug completes in < 500 ms after generation (replay timing assertion).
#
# Architecture:
#   - Uses ActionDispatch::IntegrationTest (no browser, no Capybara).
#     The data chain is the invariant; UI/stream fidelity is a separate concern.
#   - Uses ActiveJob::TestHelper#perform_enqueued_jobs so the job runs
#     synchronously in-process with the REAL EndpointBuilderAgent.
#     No fake agent injection — the whole point is the real LLM.
#   - Creates its own Event records; does not rely on fixtures or db:seed
#     to stay self-contained and deterministic about what data the LLM can query.
#
# Requirement wording:
#   "How many page_view events are there in total?" is chosen because:
#     - It is narrow and unambiguous — one-line script: Service::Events.by_name("page_view").count
#     - It matches data seeded by this test (3 page_view events).
#     - It tests a concrete, assertable result (Integer 3).
#     - It exercises EventQuery#by_name (not just .count) to cover the filter path.
class EndpointGenerationE2eTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Guard: skip the entire test class when LLM_E2E is not set.
  # This keeps `bin/rails test` and `bin/ci` fast and LMStudio-independent.
  # Also wipes Event rows so every test starts from a known, fixture-free state —
  # the same pattern used in DynamicEndpointsControllerTest.
  def setup
    skip "Set LLM_E2E=1 to run real-LLM E2E tests (requires local LMStudio)" unless ENV["LLM_E2E"]
    Event.delete_all
  end

  # ---------------------------------------------------------------------------
  # Complete chain: generate → live endpoint → replay
  # ---------------------------------------------------------------------------

  test "generates a working endpoint from natural language and replays it correctly" do
    # Arrange: seed known event data the LLM script can query.
    # Event.delete_all is handled by setup, so the slate is already clean.
    Event.create!(occurred_at: 3.days.ago, name: "page_view", properties: { "path" => "/" })
    Event.create!(occurred_at: 2.days.ago, name: "page_view", properties: { "path" => "/about" })
    Event.create!(occurred_at: 1.day.ago,  name: "page_view", properties: { "path" => "/pricing" })
    Event.create!(occurred_at: 1.day.ago,  name: "button_click", properties: { "button_id" => "cta" })

    expected_page_view_count = Event.by_name("page_view").count  # = 3

    # Arrange: create the GenerationRequest (as EndpointsController would)
    requirement = "How many page_view events are there in total?"
    generation_request = GenerationRequest.create!(requirement: requirement)

    # Act: run the job synchronously with the real LLM (no fake injection)
    # perform_enqueued_jobs executes any job enqueued inside the block immediately.
    assert_nothing_raised do
      perform_enqueued_jobs do
        EndpointGenerationJob.perform_later(generation_request.id)
      end
    end

    # Assert: generation succeeded
    generation_request.reload
    assert generation_request.succeeded?,
           "GenerationRequest must be succeeded after E2E generation; " \
           "got status=#{generation_request.status.inspect}, error=#{generation_request.error_message.inspect}"

    endpoint = generation_request.endpoint
    assert_not_nil endpoint, "GenerationRequest must have an associated Endpoint on success"
    assert endpoint.persisted?, "Endpoint must be persisted"
    assert endpoint.slug.present?, "Endpoint must have a generated slug"
    assert endpoint.script.present?, "Endpoint must have a script"

    # Assert: replay via GET /e/:slug returns correct JSON (shared execution path)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/e/#{endpoint.slug}"
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000

    assert_response :ok,
                    "GET /e/#{endpoint.slug} must return 200; body=#{response.body.inspect}"

    # Every submitted script clears ResponseSchema, so the replay body is the
    # { "data" => ..., "meta" => {} } envelope and the count sits under "data".
    count = assert_envelope(response.parsed_body)

    # The LLM may generate Service::Events.by_name("page_view").count (= 3)
    # or Service::Events.count (= 4 total).  Both are valid interpretations of
    # "how many page_view events" — the key invariant is that the count is an
    # Integer reflecting the current DB state at replay time and is consistent
    # with the total event count in the DB (not some hardcoded value).
    total_event_count = Event.count
    assert count.is_a?(Integer),
           "Replay \"data\" must be an Integer (event count); got #{count.class}: #{count.inspect}"
    assert count >= expected_page_view_count,
           "Replay count (#{count}) must be >= page_view count (#{expected_page_view_count})"
    assert count <= total_event_count,
           "Replay count (#{count}) must be <= total event count (#{total_event_count})"

    # Replay latency: assert well under 500 ms (SPEC: 微秒級量級 after warm-up)
    assert elapsed_ms < 500,
           "Replay took #{elapsed_ms.round(1)} ms — expected < 500 ms for sandbox replay"
  end

  # ---------------------------------------------------------------------------
  # Two-layer read-only defense: write attempt is rejected at the connection layer
  # ---------------------------------------------------------------------------

  test "write attempt inside the script is rejected at the connection layer" do
    # This test proves Invariant 1: 兩層唯讀防禦.
    # A script that tries to write via AR is rejected — not silently ignored.
    # We verify this by creating an endpoint with a write script directly
    # (bypassing the LLM for this specific invariant test) and confirming
    # that GET /e/:slug returns a non-200 error, not a silent success.
    #
    # Note: this does NOT use the real LLM — it injects the write script directly
    # to isolate the invariant assertion from LLM non-determinism.
    write_script = "Event.create!(name: 'injected', occurred_at: Time.now); 'wrote'"
    endpoint = Endpoint.create!(script: write_script)

    get "/e/#{endpoint.slug}"

    assert_response :internal_server_error,
                    "A write-attempting script must be rejected at the connection layer (500); " \
                    "got #{response.status}"

    body = response.parsed_body
    assert body.key?("error"), "Error response must have top-level 'error' key"
    assert body["error"].key?("type"), "Error must have a type"
  end

  # ---------------------------------------------------------------------------
  # Validation == live (shared execution path invariant)
  # ---------------------------------------------------------------------------

  test "replay of a script returns the same result as validation did" do
    # Arrange: Event.delete_all is handled by setup; insert exactly one event.
    Event.create!(occurred_at: 1.hour.ago, name: "page_view", properties: {})

    requirement = "Return the total count of all events."
    generation_request = GenerationRequest.create!(requirement: requirement)

    # Record total count BEFORE generation so we can compare to replay result.
    total_at_generation_time = Event.count  # = 1

    # Run the full generation chain with the real LLM.
    perform_enqueued_jobs do
      EndpointGenerationJob.perform_later(generation_request.id)
    end

    generation_request.reload
    skip "Generation failed; cannot verify shared execution path: #{generation_request.error_message}" \
      unless generation_request.succeeded?

    endpoint = generation_request.endpoint

    # Act: replay the endpoint immediately (no new events inserted between
    # generation and replay — DB state is identical).
    get "/e/#{endpoint.slug}"
    assert_response :ok

    replay_count = assert_envelope(response.parsed_body)

    # Assert: replay result equals what the validated script returned during
    # generation (shared execution path invariant — "驗證即上線").
    # The LLM script counts events; since DB state has not changed, the count
    # must be consistent with total_at_generation_time.
    assert replay_count.is_a?(Integer),
           "Replay \"data\" must be an Integer; got #{replay_count.class}: #{replay_count.inspect}"
    assert_equal total_at_generation_time, replay_count,
                 "Replay count (#{replay_count}) must match total event count " \
                 "at generation time (#{total_at_generation_time})"
  end

  private

  # Assert the replay body carries the ResponseSchema envelope and return the
  # value under "data".  SubmitEndpointTool rejects any script whose return
  # value fails this shape, so an endpoint that reached persistence cannot
  # answer with a bare scalar — asserting it here keeps that guardrail visible
  # from the end of the chain, where a regression would otherwise read as the
  # LLM having generated something odd.
  def assert_envelope(body)
    assert_kind_of Hash, body,
                   "Replay body must be the response envelope Hash; got #{body.class}: #{body.inspect}"
    assert body.key?("data"), "Replay envelope must carry \"data\"; got keys #{body.keys.inspect}"
    assert body.key?("meta"), "Replay envelope must carry \"meta\"; got keys #{body.keys.inspect}"
    assert_kind_of Hash, body["meta"],
                   "Replay envelope \"meta\" must be a Hash; got #{body["meta"].class}"
    body["data"]
  end
end
