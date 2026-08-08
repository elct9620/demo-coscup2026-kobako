# frozen_string_literal: true

# DCI Interaction role — the read-only Event query entry point bound into the
# Kobako sandbox as a Service.
#
# Scripts in the sandbox receive an EventQuery instance as a Handle proxy and
# chain filter methods on it before calling a terminal method that crosses the
# wire as a plain serializable value (Integer or Array of Hash).
#
# Kobako's Handle mechanism wraps the EventQuery instance when it is returned
# from a Service call: the guest script calls chain methods on the Handle, which
# dispatches each call back to this host object.  Terminal methods (.count,
# .to_a) return MessagePack-representable values that cross the wire directly.
#
# Two-layer read-only defense (docs/architecture.md):
#   Layer 1 — capability boundary: only read methods are exposed here.
#   Layer 2 — SQL boundary: every DB hit runs inside connected_to(role: :reading).
#
# Usage (bound in ReadOnlySandbox via #5):
#   sandbox.bind("Service::Events", EventQuery.new)
#
# Script example:
#   Service::Events.between("2026-01-01", "2026-05-31").by_name("page_view").count
#   Service::Events.limit(20).to_a
#
# RBS-in-prompt sync: this public read API is mirrored as RBS signatures in
# app/prompts/endpoint_builder_agent/instructions.txt.erb (Service::Events).
# The two are hand-synced — when a signature here changes, update the prompt.
class EventQuery
  # Maximum rows returned by #to_a when no explicit limit is set.
  # Guards against unbounded queries from untrusted scripts (DoS mitigation).
  DEFAULT_LIMIT = 100

  # Hard ceiling on rows returned by #to_a regardless of what an untrusted
  # script passes to #limit.  Prevents DoS via large positive values (e.g.
  # limit(999_999_999)) or SQLite's "no upper bound" semantics for LIMIT -1.
  # A script can never pull more than MAX_LIMIT rows in a single #to_a call.
  MAX_LIMIT = 1_000

  def initialize
    @scope_procs = []
    @limit_value = DEFAULT_LIMIT
  end

  # Filter events whose occurred_at falls within [from, to] (inclusive).
  # +from+ and +to+ accept Date, Time, or ISO-8601 String.
  #
  # Boundary semantics:
  #   - +from+: when a pure date is given, the range starts at beginning_of_day
  #             (i.e. 00:00:00) so the entire day is included from its start.
  #   - +to+:   when a pure date is given, the range ends at end_of_day
  #             (i.e. 23:59:59.999...) so the entire day is included up to its end.
  #   - If an explicit time is already present (Time/DateTime, or a string
  #     containing a time component like "2026-05-31T15:30:00"), it is used
  #     as-is without forcing any boundary adjustment.
  #
  # Returns self for chaining.
  def between(from, to)
    from_time = parse_from_time(from)
    to_time   = parse_to_time(to)
    @scope_procs << ->(scope) { scope.where(occurred_at: from_time..to_time) }
    self
  end

  # Filter events by exact event name.
  # Returns self for chaining.
  def by_name(name)
    @scope_procs << ->(scope) { scope.by_name(name) }
    self
  end

  # Cap the number of rows returned by #to_a.
  # The value is clamped to [1, MAX_LIMIT]: non-positive values (including
  # SQLite's unbounded LIMIT -1 semantic) fall back to DEFAULT_LIMIT, and
  # values exceeding MAX_LIMIT are silently reduced to MAX_LIMIT.
  # Returns self for chaining.
  def limit(n)
    int = n.to_i
    @limit_value = if int <= 0
      DEFAULT_LIMIT
    else
      [ int, MAX_LIMIT ].min
    end
    self
  end

  # Terminal method — returns the count of matching events as an Integer.
  # Executes via the reading connection (SQL boundary layer 2).
  def count
    ApplicationRecord.connected_to(role: :reading) do
      build_scope.count
    end
  end

  # Terminal method — returns matching events as an Array of Hash.
  # Each Hash has String keys: "id", "name", "occurred_at", "properties".
  # occurred_at is serialized as an ISO-8601 String so it crosses the
  # MessagePack wire boundary without an UnsupportedType error.
  # Executes via the reading connection (SQL boundary layer 2).
  def to_a
    ApplicationRecord.connected_to(role: :reading) do
      build_scope.limit(@limit_value).map { |e| serialize_event(e) }
    end
  end

  private

  def build_scope
    @scope_procs.reduce(Event.all) { |scope, proc| proc.call(scope) }
  end

  def serialize_event(event)
    {
      "id"          => event.id,
      "name"        => event.name,
      "occurred_at" => event.occurred_at.iso8601,
      "properties"  => event.properties
    }
  end

  # Coerce a range-start value to a Time.
  # Pure dates (Date or date-only String) resolve to beginning_of_day so the
  # entire start day is included.  Explicit times are used as-is.
  def parse_from_time(value)
    case value
    when Time, DateTime then value
    when Date           then value.beginning_of_day
    when String         then date_only_string?(value) ? Date.parse(value).beginning_of_day : Time.parse(value)
    else
      raise ArgumentError, "EventQuery#between: unsupported time type #{value.class}"
    end
  end

  # Coerce a range-end value to a Time.
  # Pure dates (Date or date-only String) resolve to end_of_day so the entire
  # end day is included.  Explicit times are used as-is.
  def parse_to_time(value)
    case value
    when Time, DateTime then value
    when Date           then value.end_of_day
    when String         then date_only_string?(value) ? Date.parse(value).end_of_day : Time.parse(value)
    else
      raise ArgumentError, "EventQuery#between: unsupported time type #{value.class}"
    end
  end

  # Returns true when the string contains only a date (YYYY-MM-DD) with no
  # time component.  Used to select between beginning_of_day / end_of_day
  # boundary expansion vs. respecting an explicit time the caller provided.
  def date_only_string?(str)
    str.match?(/\A\d{4}-\d{2}-\d{2}\z/)
  end
end
