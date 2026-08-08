# frozen_string_literal: true

# DCI Interaction role — the read-only current-time entry point bound into the
# Kobako sandbox as Utils::Time.
#
# Kobako's restricted mruby has no Time / Date / DateTime constants, so scripts
# cannot ask "what time is it now" on their own.  LLM-generated scripts reach
# for `Time.now` to compute relative date ranges ("last 7 days", "today") and
# fail with `uninitialized constant Time`.  Clock is the single host-side
# capability that closes that gap.
#
# #now returns a live Time object.  It is not MessagePack-representable, so
# Kobako auto-wraps it as a Handle proxy (docs/architecture.md — Capability
# Handle): the guest script calls #strftime / #to_i and does arithmetic
# (e.g. `Utils::Time.now - 7 * 24 * 60 * 60`) on the proxy, and each call
# dispatches back to this host Time.  The script then formats the result into
# the date Strings that EventQuery#between / MetricQuery#daily_counts expect.
#
# Read-only by construction: Time's public methods are pure (no I/O, no write
# path), so exposing it does not breach the two-layer read-only defense — it
# adds a clock, not a capability to mutate or reach outside the sandbox.
#
# Usage (bound in ReadOnlySandbox):
#   sandbox.bind("Utils::Time", Clock.new)
#
# Script example:
#   Utils::Time.now.strftime("%Y-%m-%d")                      # => "2026-05-31"
#   (Utils::Time.now - 7 * 24 * 60 * 60).strftime("%Y-%m-%d") # => "2026-05-24"
#
# RBS-in-prompt sync: #now and the time object's usable methods are mirrored as
# RBS in app/prompts/endpoint_builder_agent/instructions.txt.erb (Utils::Time /
# the _Time interface). The two are hand-synced — keep the prompt in step.
class Clock
  # Returns the current time as a Time (ActiveSupport::TimeWithZone via
  # Time.current, so it respects config.time_zone).  Crosses the sandbox
  # boundary as a Handle proxy the script can format and offset.
  def now
    Time.current
  end
end
