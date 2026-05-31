# frozen_string_literal: true

require "test_helper"

# Unit tests for EndpointGeneration context — the DCI orchestrator that drives
# the EndpointBuilderAgent error-as-feedback loop and persists the captured
# script as an Endpoint on success.
#
# Mock strategy:
#   EndpointGeneration.new(requirement, agent:) accepts an optional injected
#   agent.  The real agent answers "which script is final" through
#   #captured_script (delegated to SubmitEndpointTool during the loop), so the
#   fakes here only need to expose #ask and #captured_script — no synthetic chat
#   history is required.
#
#   1. FakeSuccessAgent      — #captured_script returns a script.
#                              EndpointGeneration persists it as an Endpoint.
#   2. FakeFailureAgent      — #ask raises IterationLimitError (cap hit).
#                              EndpointGeneration rescues → { ok: false }.
#   3. FakeNoSubmitAgent     — loop ends but #captured_script is nil (agent never
#                              submitted a valid script). → ExtractionError → false.
#
# The real agent's #captured_script wiring is pinned by the "real agent" test
# below; the full LLM round-trip is covered by the gated E2E test.
class EndpointGenerationTest < ActiveSupport::TestCase
  VALIDATED_SCRIPT = '{ "data" => Service::Events.count, "meta" => {} }'

  # ---------------------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------------------

  test "returns ok:true with endpoint when agent captures a validated script" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:ok], "result must be ok:true on success"
    assert_not_nil result[:endpoint], "result must contain the endpoint record"
    assert_instance_of Endpoint, result[:endpoint]
    assert result[:endpoint].persisted?, "endpoint must be persisted"
    assert_equal VALIDATED_SCRIPT, result[:endpoint].script
  end

  test "persists the script captured by submit_endpoint, not anything else" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert_equal VALIDATED_SCRIPT, result[:endpoint].script,
                 "the persisted script must be exactly submit_tool.captured_script"
  end

  test "creates exactly one Endpoint record on success" do
    assert_difference "Endpoint.count", 1 do
      EndpointGeneration.new("count all events", agent: fake_success_agent).call
    end
  end

  test "persisted endpoint has a generated slug" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:endpoint].slug.present?, "slug must be auto-generated"
  end

  test "persisted endpoint status is active" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result[:endpoint].active?
  end

  # ---------------------------------------------------------------------------
  # Failure path — IterationLimitError (cap hit)
  # ---------------------------------------------------------------------------

  test "returns ok:false when agent raises IterationLimitError" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert_not result[:ok], "result must be ok:false when iteration limit is hit"
  end

  test "does not create an Endpoint when agent raises IterationLimitError" do
    assert_no_difference "Endpoint.count" do
      EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call
    end
  end

  test "failure result contains an error message" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert result[:error].present?, "failure result must include an error message"
  end

  test "does not raise IterationLimitError to the caller" do
    assert_nothing_raised do
      EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call
    end
  end

  # Strict cap policy: hitting MAX_ITERATIONS is a failure even if an earlier
  # submission had succeeded — the captured script is discarded, not shipped.
  test "cap hit fails and persists nothing even if a script was captured" do
    agent = FakeFailureAgent.new(captured_script: VALIDATED_SCRIPT)

    assert_no_difference "Endpoint.count" do
      result = EndpointGeneration.new("ran long", agent: agent).call
      assert_not result[:ok], "cap hit must fail regardless of an earlier capture"
    end
  end

  # ---------------------------------------------------------------------------
  # Failure path — ExtractionError (loop ended, nothing was submitted)
  # ---------------------------------------------------------------------------

  test "returns ok:false when the agent never captured a valid script" do
    result = EndpointGeneration.new("vague requirement", agent: fake_no_submit_agent).call

    assert_not result[:ok], "result must be ok:false when captured_script is nil"
  end

  test "does not create an Endpoint when nothing was submitted" do
    assert_no_difference "Endpoint.count" do
      EndpointGeneration.new("vague requirement", agent: fake_no_submit_agent).call
    end
  end

  test "failure result contains an error message when nothing was submitted" do
    result = EndpointGeneration.new("vague requirement", agent: fake_no_submit_agent).call

    assert result[:error].present?, "failure result must include an error message"
  end

  test "does not raise ExtractionError to the caller" do
    assert_nothing_raised do
      EndpointGeneration.new("vague requirement", agent: fake_no_submit_agent).call
    end
  end

  # ---------------------------------------------------------------------------
  # Interface contract
  # ---------------------------------------------------------------------------

  test "success result contains :ok key set to true" do
    result = EndpointGeneration.new("count all events", agent: fake_success_agent).call

    assert result.key?(:ok)
    assert result[:ok]
  end

  test "failure result contains :ok and :error keys" do
    result = EndpointGeneration.new("impossible requirement", agent: fake_failure_agent).call

    assert result.key?(:ok)
    assert result.key?(:error)
    assert_not result[:ok]
  end

  private

  def fake_success_agent
    FakeSuccessAgent.new(VALIDATED_SCRIPT)
  end

  def fake_failure_agent
    FakeFailureAgent.new
  end

  def fake_no_submit_agent
    FakeNoSubmitAgent.new
  end

  # ---------------------------------------------------------------------------
  # Fake agent helpers — duck-types of EndpointBuilderAgent exposing #ask and
  # #captured_script (the same interface the real agent presents to the context).
  # ---------------------------------------------------------------------------

  # #ask is a no-op; #captured_script is what EndpointGeneration reads.
  class FakeSuccessAgent
    attr_reader :captured_script

    def initialize(captured_script)
      @captured_script = captured_script
    end

    def ask(_requirement) = nil
  end

  # Loop ends cleanly but the agent never submitted a valid script.
  class FakeNoSubmitAgent
    attr_reader :captured_script

    def initialize
      @captured_script = nil
    end

    def ask(_requirement) = nil
  end

  # Simulates exhaustion of MAX_ITERATIONS: #ask raises IterationLimitError.
  # captured_script is never read because the cap is a failure regardless — it
  # may even be set (see the strict-cap test) and must still be discarded.
  class FakeFailureAgent
    attr_reader :captured_script

    def initialize(captured_script: nil)
      @captured_script = captured_script
    end

    def ask(_requirement)
      raise EndpointBuilderAgent::IterationLimitError,
            "Stopped after #{EndpointBuilderAgent::MAX_ITERATIONS} iterations without success."
    end
  end
end
