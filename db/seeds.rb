# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# --- Demo event data ---
# Provides enough variety for endpoint queries like:
#   - "daily page views for the last 7 days"
#   - "top event names by count"
#   - "events with a specific property value"

# The weighted name model and per-name property shapes live in EventFactory,
# shared with the live "inject events" action (DemoEventsController) so the two
# data sources never drift apart.

puts "Seeding demo events..."

# Remove existing demo events so seeds stay idempotent
Event.where("occurred_at >= ?", 30.days.ago).delete_all

30.downto(0) do |days_ago|
  # Realistic daily volume: weekdays ~40 events, weekends ~15
  date = days_ago.days.ago.to_date
  daily_volume = date.wday.in?([ 0, 6 ]) ? rand(10..20) : rand(30..55)

  daily_volume.times do
    occurred_at = date.to_time.utc + rand(7..22).hours + rand(0..59).minutes + rand(0..59).seconds
    EventFactory.create(occurred_at: occurred_at)
  end
end

total = Event.count
puts "Seeded #{total} demo events spanning the last 30 days."
puts "  page_view:    #{Event.by_name('page_view').count}"
puts "  button_click: #{Event.by_name('button_click').count}"
puts "  form_submit:  #{Event.by_name('form_submit').count}"

# Endpoints are intentionally NOT seeded. The whole point of the demo is the
# operator generating an endpoint live on stage; pre-seeding working endpoints
# would undercut that. A fresh setup starts with an empty Endpoints list and
# only the event data above for generated scripts to query.
