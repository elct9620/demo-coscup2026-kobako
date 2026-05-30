# frozen_string_literal: true

require "test_helper"

# Integration tests for DynamicEndpointsController.
#
# These tests exercise the full stack: routing → controller → EndpointReplay
# → ReadOnlySandbox (real Kobako WASM — no mocks) unless noted.  This verifies:
#
#   1. Successful replay returns 200 with the script result as JSON.
#   2. Unknown slug returns 404 with a structured error JSON.
#   3. Invalid query parameters return 422 with a structured error JSON.
#   4. Sandbox execution errors return 500 with a structured error JSON.
#   5. Query parameters are correctly forwarded to the sandbox via EndpointReplay.
#   6. The structured error JSON format is consistent across all error types.
#
# Security trust-boundary verification (coding:security):
#   - slug is an untrusted URL segment; the controller passes it only to
#     Endpoint.find_by!(slug:) — never interpolated into queries or scripts.
#   - query params are untrusted HTTP input; the controller passes them only to
#     EndpointReplay.new, which gates them through ReadOnlySandbox#validate_params.
#
# HTTP Status contract (coding:schema):
#   200  — replay succeeded, result body is the script return value
#   404  — no Endpoint with the given slug
#   422  — query parameter validation failure (InvalidParamsError)
#   500  — sandbox execution error (SandboxError, TimeoutError, etc.)
class DynamicEndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Event.delete_all
  end

  # ---------------------------------------------------------------------------
  # 200 — successful replay
  # ---------------------------------------------------------------------------

  test "returns 200 with script result for a known slug" do
    endpoint = Endpoint.create!(script: "Service::Events.count")

    get "/e/#{endpoint.slug}"

    assert_response :ok
    assert_equal 0, response.parsed_body
  end

  test "result reflects current database state at request time" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    endpoint = Endpoint.create!(script: "Service::Events.count")

    get "/e/#{endpoint.slug}"

    assert_response :ok
    assert_equal 1, response.parsed_body
  end

  test "query params are forwarded to the sandbox via Service::Params" do
    endpoint = Endpoint.create!(script: 'Service::Params.fetch("name")')

    get "/e/#{endpoint.slug}", params: { name: "page_view" }

    assert_response :ok
    assert_equal "page_view", response.parsed_body
  end

  test "script can use query params to filter events" do
    Event.create!(occurred_at: Time.current, name: "page_view")
    Event.create!(occurred_at: Time.current, name: "button_click")
    endpoint = Endpoint.create!(
      script: 'Service::Events.by_name(Service::Params.fetch("name")).count'
    )

    get "/e/#{endpoint.slug}", params: { name: "page_view" }

    assert_response :ok
    assert_equal 1, response.parsed_body
  end

  test "response Content-Type is application/json" do
    endpoint = Endpoint.create!(script: "42")

    get "/e/#{endpoint.slug}"

    assert_response :ok
    assert_match "application/json", response.content_type
  end

  # ---------------------------------------------------------------------------
  # 404 — slug not found
  # ---------------------------------------------------------------------------

  test "returns 404 for an unknown slug" do
    get "/e/does_not_exist"

    assert_response :not_found
  end

  test "404 response has a structured error JSON body" do
    get "/e/nonexistent_slug"

    assert_response :not_found
    body = response.parsed_body
    assert body.key?("error"), "expected top-level 'error' key"
    assert body["error"].key?("type")
    assert body["error"].key?("message")
    assert_equal "RecordNotFound", body["error"]["type"]
  end

  # ---------------------------------------------------------------------------
  # 422 — invalid query parameters
  # ---------------------------------------------------------------------------

  # Rails query_parameters always produces String keys and String values via
  # normal HTTP GET requests, so InvalidParamsError is not reachable through
  # standard HTTP.  We verify the controller's status mapping by temporarily
  # overriding EndpointReplay.new with a fake that returns the error shape.
  # This tests the controller's error-to-status mapping in isolation while
  # keeping the test free from mocking libraries (same pattern as
  # EndpointGenerationJobTest#with_fake_generation).
  test "returns 422 when EndpointReplay reports InvalidParamsError" do
    endpoint = Endpoint.create!(script: "Service::Events.count")
    invalid_result = {
      ok: false,
      error: { type: "InvalidParamsError", message: "param keys must be Strings" }
    }

    with_fake_replay(->(_ep, _params) { invalid_result }) do
      get "/e/#{endpoint.slug}"
    end

    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "InvalidParamsError", body["error"]["type"]
  end

  # ---------------------------------------------------------------------------
  # 500 — sandbox execution errors
  # ---------------------------------------------------------------------------

  test "returns 500 for a script with a syntax error" do
    endpoint = Endpoint.create!(script: "def foo(")

    get "/e/#{endpoint.slug}"

    assert_response :internal_server_error
    body = response.parsed_body
    assert body.key?("error")
    assert_equal "SandboxError", body["error"]["type"]
  end

  test "returns 500 for a script that raises at runtime" do
    endpoint = Endpoint.create!(script: "raise 'boom'")

    get "/e/#{endpoint.slug}"

    assert_response :internal_server_error
    body = response.parsed_body
    assert_equal "SandboxError", body["error"]["type"]
  end

  test "returns 500 for a sandbox timeout" do
    # Pre-build the fast-timeout replay before intercepting EndpointReplay.new,
    # then return a static timeout result from the fake.  This avoids the
    # infinite recursion that would occur if the lambda called EndpointReplay.new
    # while .new is intercepted.
    endpoint = Endpoint.create!(script: "loop { }")
    timeout_result = { ok: false, error: { type: "TimeoutError", message: "execution expired" } }

    with_fake_replay(->(_ep, _params) { timeout_result }) do
      get "/e/#{endpoint.slug}"
    end

    assert_response :internal_server_error
    body = response.parsed_body
    assert_equal "TimeoutError", body["error"]["type"]
  end

  test "sandbox error response has consistent error JSON structure" do
    endpoint = Endpoint.create!(script: "raise 'structured'")

    get "/e/#{endpoint.slug}"

    body = response.parsed_body
    assert body.key?("error"), "expected top-level 'error' key"
    assert body["error"].key?("type")
    assert body["error"].key?("message")
  end

  test "one failing request does not affect subsequent successful requests" do
    failing = Endpoint.create!(script: "raise 'crash'")
    passing = Endpoint.create!(script: "1 + 2")

    get "/e/#{failing.slug}"
    assert_response :internal_server_error

    get "/e/#{passing.slug}"
    assert_response :ok
    assert_equal 3, response.parsed_body
  end

  private

  # Temporarily overrides EndpointReplay.new so that it delegates #call to
  # +call_proc+.  Restores the original after the block returns (or raises).
  # Same override technique as EndpointGenerationJobTest#with_fake_generation.
  #
  # @param call_proc [Proc]  receives (endpoint, params); its return value
  #                          becomes the result of #call.
  def with_fake_replay(call_proc)
    original_new = EndpointReplay.method(:new)

    EndpointReplay.define_singleton_method(:new) do |ep, params, **_kwargs|
      proc_to_call = call_proc
      Object.new.tap do |ctx|
        ctx.define_singleton_method(:call) { proc_to_call.call(ep, params) }
      end
    end

    yield
  ensure
    EndpointReplay.singleton_class.undef_method(:new)
    EndpointReplay.define_singleton_method(:new) do |*args, **kwargs, &block|
      original_new.call(*args, **kwargs, &block)
    end
  end
end
