# frozen_string_literal: true

# Generates realistic demo Event records from one weighted model.
#
# Two callers share this factory so the distribution and property shapes live
# in a single place (DRY):
#   - db/seeds.rb           — seeds historical events across the last 30 days
#   - DemoEventsController  — injects a fresh batch live on stage so the
#                             operator can watch endpoint output change
#
# This is a pure write-side PORO with no table, mirroring Metric's read-side
# role in app/models. It writes through plain ActiveRecord — never through the
# sandbox — so it does not touch the two-layer read-only defense, which governs
# generated-script execution only.
class EventFactory
  PAGES   = %w[/ /about /pricing /blog /docs /contact].freeze
  SOURCES = %w[google twitter direct newsletter organic].freeze
  BUTTONS = %w[cta_signup cta_demo navbar_login footer_contact].freeze
  FORMS   = %w[contact_form newsletter_signup demo_request].freeze

  # Event name → relative frequency. Drives sample_name's weighted pick so the
  # generated mix resembles real web-analytics traffic.
  EVENT_WEIGHTS = {
    "page_view"    => 60,
    "button_click" => 20,
    "form_submit"  => 10,
    "scroll_depth" => 8,
    "session_end"  => 2
  }.freeze

  WEIGHTED_POOL = EVENT_WEIGHTS.flat_map { |name, weight| Array.new(weight, name) }.freeze

  DEFAULT_BATCH_SIZE = 25
  MAX_BATCH_SIZE     = 200

  class << self
    # Pick an event name following the weighted distribution.
    def sample_name
      WEIGHTED_POOL.sample
    end

    # Build the properties hash for a given event name. Unknown names yield an
    # empty hash so callers never have to special-case them.
    def properties_for(name)
      case name
      when "page_view"
        { "path" => PAGES.sample, "referrer" => SOURCES.sample, "duration_ms" => rand(500..8000) }
      when "button_click"
        { "button_id" => BUTTONS.sample, "path" => PAGES.sample }
      when "form_submit"
        { "form_id" => FORMS.sample, "path" => PAGES.sample, "success" => [ true, false ].sample }
      when "scroll_depth"
        { "path" => PAGES.sample, "percent" => [ 25, 50, 75, 100 ].sample }
      when "session_end"
        { "duration_s" => rand(10..900), "pages_visited" => rand(1..8) }
      else
        {}
      end
    end

    # Persist one Event at +occurred_at+ with a weighted name and matching
    # properties.
    #
    # @param occurred_at [Time]
    # @param name        [String] defaults to a weighted random name
    # @return [Event]
    def create(occurred_at:, name: sample_name)
      Event.create!(name: name, occurred_at: occurred_at, properties: properties_for(name))
    end

    # Inject a fresh batch of events scattered across the last hour, so live
    # endpoint queries (today's counts, recent ranges) visibly change right
    # after the operator clicks "inject".
    #
    # @param count [Integer] clamped to 1..MAX_BATCH_SIZE
    # @return [Integer] the number of events created
    def create_recent_batch(count: DEFAULT_BATCH_SIZE)
      count = count.to_i.clamp(1, MAX_BATCH_SIZE)
      count.times do
        create(occurred_at: Time.current - rand(0..59).minutes - rand(0..59).seconds)
      end
      count
    end
  end
end
