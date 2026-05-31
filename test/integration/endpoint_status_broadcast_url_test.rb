# frozen_string_literal: true

require "test_helper"

# Regression (#endpoint-url-host):
#
# The endpoints/_status partial renders an absolute URL via dynamic_endpoint_url.
# It is broadcast over Turbo Streams from GenerationRequest#broadcast_status_to_self,
# i.e. rendered OUTSIDE an HTTP request through ActionController::Renderer — whose
# default host is "example.org".  Without config.action_controller.default_url_options
# the operator was shown http://example.org/e/<slug> instead of the running host.
#
# This test exercises the same renderer path the broadcast uses and asserts the
# configured host (example.com in test) is used, not example.org.
class EndpointStatusBroadcastUrlTest < ActiveSupport::TestCase
  test "endpoint URL rendered outside an HTTP request uses the configured host, not example.org" do
    generation_request = generation_requests(:succeeded_request)
    endpoint = generation_request.endpoint

    html = ApplicationController.render(
      partial: "endpoints/status",
      locals: { generation_request: generation_request }
    )

    assert_includes html, "http://example.com/e/#{endpoint.slug}",
      "broadcast-rendered endpoint URL should use the configured host"
    refute_includes html, "example.org",
      "broadcast-rendered endpoint URL must not fall back to the renderer default host"
  end
end
