# frozen_string_literal: true

# DCI Interaction role — the read-only Metric aggregation entry point bound
# into the Kobako sandbox as a Service.
#
# MetricQuery wraps the Metric PORO (app/models/metric.rb), which holds the
# stable aggregation API over Event records.  This class is the sandbox-facing
# adapter: it enforces the reading connection and serializes return values to
# MessagePack-representable types (Hash with String keys, Array of Array, Integer).
#
# Unlike EventQuery, MetricQuery methods are not chainable — each method is a
# complete aggregation query.  The sandbox script calls them directly and gets
# a wire-representable value back without needing a Handle proxy chain.
#
# Two-layer read-only defense (docs/architecture.md):
#   Layer 1 — capability boundary: only aggregation read methods exposed.
#   Layer 2 — SQL boundary: every DB hit runs inside connected_to(role: :reading).
#
# Usage (bound in ReadOnlySandbox via #5):
#   sandbox.define(:Service).bind(:Metrics, MetricQuery.new)
#
# Script examples:
#   Service::Metrics.daily_counts(since: "2026-01-01")
#   Service::Metrics.top_names(limit: 5)
#   Service::Metrics.total_count(name: "page_view")
class MetricQuery
  # Returns a Hash of { "YYYY-MM-DD" => Integer } covering every day from
  # +since+ through today, zero-padding days with no matching events.
  #
  # +since+ accepts a Date or an ISO-8601 String ("YYYY-MM-DD").
  # +name+  optional String filter — when given, only matching events are counted.
  #
  # Date keys are serialized as ISO-8601 Strings so the Hash crosses the
  # MessagePack wire boundary without UnsupportedType errors (Date is not a
  # native msgpack type).
  def daily_counts(since:, name: nil)
    since_date = parse_date(since)
    ApplicationRecord.connected_to(role: :reading) do
      Metric.daily_counts(since: since_date, name: name)
            .transform_keys { |date| date.iso8601 }
    end
  end

  # Returns an Array of [name, count] pairs sorted by count descending.
  # Each element is a two-element Array [String, Integer] — fully wire-representable.
  #
  # +limit+ Integer, max results (default 10).
  # +since+ optional Date or ISO-8601 String lower bound on occurred_at.
  def top_names(limit: 10, since: nil)
    since_date = since ? parse_date(since) : nil
    ApplicationRecord.connected_to(role: :reading) do
      Metric.top_names(limit: limit, since: since_date)
    end
  end

  # Returns the total count of events as an Integer.
  # +name+ optional String filter.
  def total_count(name: nil)
    ApplicationRecord.connected_to(role: :reading) do
      Metric.total_count(name: name)
    end
  end

  private

  # Coerce caller-supplied value to a Date.
  # Accepts Date or ISO-8601 String ("YYYY-MM-DD").
  def parse_date(value)
    case value
    when Date   then value
    when String then Date.parse(value)
    else
      raise ArgumentError, "MetricQuery: unsupported date type #{value.class}"
    end
  end
end
