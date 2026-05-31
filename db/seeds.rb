# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# --- Demo event data ---
# Provides enough variety for endpoint queries like:
#   - "daily page views for the last 7 days"
#   - "top event names by count"
#   - "events with a specific property value"

pages   = %w[/ /about /pricing /blog /docs /contact]
sources = %w[google twitter direct newsletter organic]
buttons = %w[cta_signup cta_demo navbar_login footer_contact]
forms   = %w[contact_form newsletter_signup demo_request]

# Weight table: event name → relative frequency
event_weights = {
  "page_view"    => 60,
  "button_click" => 20,
  "form_submit"  => 10,
  "scroll_depth" => 8,
  "session_end"  => 2
}

weighted_pool = event_weights.flat_map { |name, weight| Array.new(weight, name) }

puts "Seeding demo events..."

# Remove existing demo events so seeds stay idempotent
Event.where("occurred_at >= ?", 30.days.ago).delete_all

30.downto(0) do |days_ago|
  # Realistic daily volume: weekdays ~40 events, weekends ~15
  date = days_ago.days.ago.to_date
  daily_volume = date.wday.in?([ 0, 6 ]) ? rand(10..20) : rand(30..55)

  daily_volume.times do
    name = weighted_pool.sample
    hour = rand(7..22)
    minute = rand(0..59)
    second = rand(0..59)
    occurred_at = date.to_time.utc + hour.hours + minute.minutes + second.seconds

    properties = case name
    when "page_view"
      { "path" => pages.sample, "referrer" => sources.sample, "duration_ms" => rand(500..8000) }
    when "button_click"
      { "button_id" => buttons.sample, "path" => pages.sample }
    when "form_submit"
      { "form_id" => forms.sample, "path" => pages.sample, "success" => [ true, false ].sample }
    when "scroll_depth"
      { "path" => pages.sample, "percent" => [ 25, 50, 75, 100 ].sample }
    when "session_end"
      { "duration_s" => rand(10..900), "pages_visited" => rand(1..8) }
    else
      {}
    end

    Event.create!(name: name, occurred_at: occurred_at, properties: properties)
  end
end

total = Event.count
puts "Seeded #{total} demo events spanning the last 30 days."
puts "  page_view:    #{Event.by_name('page_view').count}"
puts "  button_click: #{Event.by_name('button_click').count}"
puts "  form_submit:  #{Event.by_name('form_submit').count}"

# --- Demo endpoints (already-live, validated read-only scripts) ---
# So the Endpoints list isn't empty on a fresh setup: the audience sees a few
# working endpoints before the operator generates one live. These scripts are
# real, sandbox-verified read-only mruby (the same shape the agent generates).
# The "2026-05-01" window lines up with the 30 days of events seeded above.
demo_endpoints = [
  {
    slug: "page-views-last-7-days",
    requirement: "Count all page_view events from the past 7 days",
    script: <<~RUBY.strip
      counts = Service::Metrics.daily_counts(since: "2026-05-01", name: "page_view")
      sorted_dates = counts.keys.sort
      recent_dates = sorted_dates.last(7)
      sum = 0
      recent_dates.each { |date| sum += counts[date] }
      sum
    RUBY
  },
  {
    slug: "recent-events",
    requirement: "List the 5 most recent events with their names and timestamps",
    script: <<~RUBY.strip
      events = Service::Events.limit(100).to_a.sort_by { |e| e["occurred_at"] }.reverse.first(5).map do |e|
        { "name" => e["name"], "occurred_at" => e["occurred_at"] }
      end
      events
    RUBY
  },
  {
    slug: "avg-events-per-day",
    requirement: "Average number of events per day over the last 7 days",
    script: <<~RUBY.strip
      counts = Service::Metrics.daily_counts(since: "2026-05-01")
      sorted_days = counts.keys.sort
      last_7_days = sorted_days.last(7)
      if last_7_days.empty?
        0.0
      else
        total_events = 0
        last_7_days.each { |day| total_events += counts[day] }
        total_events.to_f / last_7_days.size
      end
    RUBY
  }
]

puts "Seeding demo endpoints..."
demo_endpoints.each do |attrs|
  endpoint = Endpoint.find_or_create_by!(slug: attrs[:slug]) do |e|
    e.script = attrs[:script]
    e.status = :active
  end
  GenerationRequest.find_or_create_by!(endpoint: endpoint) do |gr|
    gr.requirement = attrs[:requirement]
    gr.status = :succeeded
  end
end
puts "Seeded #{Endpoint.count} demo endpoints."
