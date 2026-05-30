# Metric is a pure query object (no database table).
# It aggregates Event records and exposes a stable API for MetricQuery (sandbox Interaction role).
class Metric
  # Returns a Hash of { Date => Integer } covering every day from +since+ through today.
  # All days are present — days with no matching events have count 0.
  #
  # @param since [Date] first day of the range (inclusive)
  # @param name  [String, nil] optional filter by event name
  # @return [Hash{Date => Integer}]
  def self.daily_counts(since:, name: nil)
    scope = Event.where(occurred_at: since.beginning_of_day..).then do |s|
      name ? s.by_name(name) : s
    end

    counts = scope
      .group("DATE(occurred_at)")
      .count
      .transform_keys { |d| Date.parse(d) }

    (since..Date.current).each_with_object({}) do |date, hash|
      hash[date] = counts.fetch(date, 0)
    end
  end

  # Returns an Array of [name, count] pairs sorted by count descending.
  #
  # @param limit [Integer] maximum number of results
  # @param since [Date, nil] optional lower bound on occurred_at
  # @return [Array<Array(String, Integer)>]
  def self.top_names(limit: 10, since: nil)
    scope = since ? Event.recent_days((Date.current - since).to_i) : Event.all
    scope
      .group(:name)
      .order(Arel.sql("count(*) DESC"))
      .limit(limit)
      .count
      .to_a
  end

  # Returns the total count of events, optionally filtered by name.
  #
  # @param name [String, nil] optional filter by event name
  # @return [Integer]
  def self.total_count(name: nil)
    scope = name ? Event.by_name(name) : Event.all
    scope.count
  end
end
