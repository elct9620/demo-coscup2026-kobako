# frozen_string_literal: true

# Operator demo tooling — injects a fresh batch of analytics events.
#
# Route: POST /demo_events
#
# Purpose (PRODUCT.md "Show don't tell"): lets the operator make an already-live
# endpoint visibly change on stage. After injecting, re-requesting /e/:slug
# returns updated numbers, demonstrating that each replay reflects the current
# database state.
#
# Architecture (docs/architecture.md — DCI):
#   Thin HTTP adapter. The generation logic lives in EventFactory (shared with
#   db/seeds.rb); this controller only translates the request into one call and
#   maps the outcome back to a redirect.
#
# Security (coding:security STRIDE):
#   D (DoS): count is untrusted; EventFactory.create_recent_batch clamps it to
#     MAX_BATCH_SIZE so it cannot flood the table.
#   Boundary: writes through plain ActiveRecord, never the sandbox — the
#     two-layer read-only defense governs generated-script execution only and is
#     not weakened here.
#   CSRF: inherits ApplicationController (ActionController::Base) full CSRF
#     protection; the POST requires a valid authenticity token.
class DemoEventsController < ApplicationController
  def create
    created = EventFactory.create_recent_batch(count: batch_count)
    redirect_back fallback_location: endpoints_path, notice: "已灌入 #{created} 筆事件"
  end

  private

  # Default to the standard batch when no count is given; EventFactory clamps
  # the value, so passing it through raw is safe.
  def batch_count
    params.fetch(:count, EventFactory::DEFAULT_BATCH_SIZE)
  end
end
