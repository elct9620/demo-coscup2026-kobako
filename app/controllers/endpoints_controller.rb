# frozen_string_literal: true

# Operator-facing generation UI (Hotwire/Turbo).
#
# Routes handled:
#   GET  /endpoints      → list the live endpoints
#   GET  /endpoints/new  → render the requirement form
#   POST /endpoints      → create GenerationRequest, enqueue job, redirect to show
#   GET  /endpoints/:id  → show generation status (pending / succeeded / failed)
#
# Architecture (docs/architecture.md — DCI 三要素):
#   This controller is a thin HTTP adapter.  It creates/finds the GenerationRequest
#   Data record and delegates all work to EndpointGenerationJob (Context).
#
# Security (coding:security — STRIDE):
#   T (Tampering): requirement is untrusted user input; it is passed only to
#     GenerationRequest.new — never interpolated into queries or scripts.
#   D (DoS): the controller only enqueues the job; sandbox timeout is enforced
#     inside ReadOnlySandbox.
#   CSRF: inherits ActionController::Base (not API), which applies full CSRF
#     protection via the authenticity token — all state-changing requests (POST)
#     require a valid token.
class EndpointsController < ApplicationController
  def index
    @endpoints = Endpoint.includes(:generation_request).order(created_at: :desc)
  end

  def new
    @generation_request = GenerationRequest.new
  end

  def create
    @generation_request = GenerationRequest.new(generation_request_params)

    if @generation_request.save
      EndpointGenerationJob.perform_later(@generation_request.id)
      redirect_to endpoint_path(@generation_request)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @generation_request = GenerationRequest.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Current status frame, rendered without the page chrome or live log. The
  # status-reconciler Stimulus controller reloads this on an interval so the
  # operator UI converges to the terminal state even when the live status
  # broadcast is missed — e.g. an instant LLM failure that completes before the
  # browser's Action Cable subscription is established. The live broadcast still
  # drives the happy path; this is the deterministic backstop.
  def status
    @generation_request = GenerationRequest.find(params[:id])
    render layout: false
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Clear the board back to the fresh-demo state so the operator can re-run the
  # demo from scratch. Removes endpoints and their entire generation footprint
  # (requests, chats, messages, tool calls); the seeded event data is left
  # intact so generated scripts still have something to query.
  #
  # Order matters under the foreign keys: GenerationRequest references both
  # Endpoint and Chat, so it goes first; Chat#destroy cascades messages and
  # tool calls via acts_as_chat. Wrapped in a transaction so a mid-delete
  # failure leaves the board untouched rather than half-cleared.
  def reset
    ActiveRecord::Base.transaction do
      GenerationRequest.destroy_all
      Endpoint.destroy_all
      Chat.destroy_all
    end
    redirect_to endpoints_path, notice: "已清空所有端點，回到初始狀態"
  end

  private

  def generation_request_params
    params.require(:generation_request).permit(:requirement)
  end
end
