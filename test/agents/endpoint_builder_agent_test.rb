# frozen_string_literal: true

require "test_helper"

# Unit tests for EndpointBuilderAgent — the RubyLLM::Agent that drives the
# error-as-feedback self-correction loop (docs/architecture.md Patterns).
#
# Strategy: test class-level configuration and instance-level iteration cap
# WITHOUT hitting real LMStudio.  Real LLM integration is deferred to #14 E2E.
#
# What we verify here:
#   1. Class structure — inherits RubyLLM::Agent, binds inspect_query +
#      submit_endpoint, instructions point to the prompt file, model is
#      LMStudio-compatible.
#   2. Iteration cap — before_tool_call counter raises IterationLimitError at
#      MAX_ITERATIONS + 1 call, not before.
#
# The before_tool_call callback is registered on the chat object inside
# initialize.  We extract the registered callbacks from chat.instance_variable_get
# and invoke them directly — no LLM call required.
class EndpointBuilderAgentTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Class-structure tests
  # ---------------------------------------------------------------------------

  test "inherits from RubyLLM::Agent" do
    assert_operator EndpointBuilderAgent, :<, RubyLLM::Agent
  end

  test "declares MAX_ITERATIONS constant as a positive integer" do
    assert defined?(EndpointBuilderAgent::MAX_ITERATIONS), "MAX_ITERATIONS should be defined"
    assert EndpointBuilderAgent::MAX_ITERATIONS.is_a?(Integer)
    assert EndpointBuilderAgent::MAX_ITERATIONS.positive?
  end

  test "class-level tools declare the stateless InspectQueryTool" do
    tools = EndpointBuilderAgent.tools
    assert_includes tools, InspectQueryTool,
                    "tools macro should declare InspectQueryTool"
  end

  test "binds both inspect_query and submit_endpoint on the chat" do
    agent = build_agent
    bound = agent.chat.tools.keys

    assert_includes bound, :inspect_query, "inspect_query must be bound"
    assert_includes bound, :submit_endpoint, "submit_endpoint must be bound"
  end

  test "exposes the submit_endpoint tool instance via #submit_tool" do
    agent = build_agent

    assert_instance_of SubmitEndpointTool, agent.submit_tool
    assert_nil agent.submit_tool.captured_script,
               "captured_script starts nil until a submission succeeds"
  end

  test "the bound submit_endpoint is the same tracked instance #submit_tool exposes" do
    agent = build_agent

    assert_same agent.submit_tool, agent.chat.tools[:submit_endpoint],
                "EndpointGeneration must read the same instance the LLM submits through"
  end

  test "instructions point to the conventional prompt file" do
    # RubyLLM Agent#instructions returns { prompt: "instructions", locals: {} }
    # when using the default no-arg conventions.
    instructions = EndpointBuilderAgent.instructions
    assert instructions, "instructions should be configured"
    assert_equal "instructions", instructions[:prompt]
  end

  test "chat_kwargs include provider: :openai and assume_model_exists: true" do
    kwargs = EndpointBuilderAgent.chat_kwargs
    assert_equal :openai, kwargs[:provider],
                 "provider must be :openai (LMStudio OpenAI-compatible)"
    assert kwargs[:assume_model_exists],
           "assume_model_exists must be true so LMStudio model is accepted without registry lookup"
  end

  test "chat_kwargs include the model id from config.llm" do
    expected_model = Rails.application.config.llm.model
    assert expected_model.present?, "config.llm.model must be set"
    assert_equal expected_model, EndpointBuilderAgent.chat_kwargs[:model]
  end

  # ---------------------------------------------------------------------------
  # IterationLimitError constant
  # ---------------------------------------------------------------------------

  test "IterationLimitError is a subclass of StandardError" do
    assert_operator EndpointBuilderAgent::IterationLimitError, :<, StandardError
  end

  # ---------------------------------------------------------------------------
  # Iteration cap — before_tool_call counter behaviour
  # ---------------------------------------------------------------------------
  #
  # We build a real agent instance (which registers the before_tool_call callback
  # on the internal chat object) and then invoke the callback directly the
  # required number of times to exercise the counter logic without an LLM call.

  test "before_tool_call callback does not raise before MAX_ITERATIONS calls" do
    agent = build_agent
    callbacks = extract_before_tool_call_callbacks(agent)

    assert callbacks.any?, "at least one before_tool_call callback must be registered"

    assert_nothing_raised do
      EndpointBuilderAgent::MAX_ITERATIONS.times do
        callbacks.each { |cb| cb.call(stub_tool_call) }
      end
    end
  end

  test "before_tool_call raises IterationLimitError on the call beyond MAX_ITERATIONS" do
    agent = build_agent
    callbacks = extract_before_tool_call_callbacks(agent)

    # Exhaust the allowed quota
    EndpointBuilderAgent::MAX_ITERATIONS.times do
      callbacks.each { |cb| cb.call(stub_tool_call) }
    end

    # The very next call must raise
    assert_raises EndpointBuilderAgent::IterationLimitError do
      callbacks.each { |cb| cb.call(stub_tool_call) }
    end
  end

  test "separate agent instances have independent counters" do
    agent_a = build_agent
    agent_b = build_agent

    cbs_a = extract_before_tool_call_callbacks(agent_a)
    cbs_b = extract_before_tool_call_callbacks(agent_b)

    # Exhaust agent_a
    EndpointBuilderAgent::MAX_ITERATIONS.times { cbs_a.each { |cb| cb.call(stub_tool_call) } }
    assert_raises EndpointBuilderAgent::IterationLimitError do
      cbs_a.each { |cb| cb.call(stub_tool_call) }
    end

    # agent_b's counter should be untouched
    assert_nothing_raised do
      cbs_b.each { |cb| cb.call(stub_tool_call) }
    end
  end

  private

  # Build an agent instance without triggering any LLM call.
  # EndpointBuilderAgent.new calls RubyLLM.chat internally which creates a Chat
  # object; this is pure in-process Ruby — no network required.
  def build_agent
    EndpointBuilderAgent.new
  end

  # Extract the before_tool_call callbacks registered on the internal chat.
  # RubyLLM::Chat stores them in @callbacks[:before_tool_call].
  def extract_before_tool_call_callbacks(agent)
    agent.chat.instance_variable_get(:@callbacks)[:before_tool_call]
  end

  # Minimal stub that satisfies the callback signature (receives a tool_call arg).
  def stub_tool_call
    Object.new
  end
end
