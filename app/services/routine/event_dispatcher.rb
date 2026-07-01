class Routine
  # Matches an inbound WebhookEvent against the team's enabled event routines
  # and fires each one. Wildcard event_type, a per-routine cooldown, and
  # optional trigger_config["conditions"] (dotted-path equality on the
  # payload) all gate a fire. Best-effort per routine.
  class EventDispatcher
    def self.dispatch(event)
      new(event).dispatch
    end

    def initialize(event)
      @event = event
    end

    def dispatch
      candidates.each do |routine|
        next if routine.within_cooldown?
        next unless conditions_met?(routine)

        routine.fire!(event: @event)
      rescue StandardError => e
        Rails.logger.error("Routine::EventDispatcher: routine #{routine.id} failed: #{e.class}: #{e.message}")
      end
    end

    private

    def candidates
      @event.team.routines.active.webhook.select { |routine| routine.matches_event?(@event) }
    end

    # Every condition (dotted path → expected value) must equal the payload
    # value at that path. No conditions → always fires.
    def conditions_met?(routine)
      conditions = routine.trigger_config["conditions"]
      return true unless conditions.is_a?(Hash) && conditions.any?

      conditions.all? { |path, expected| dig_path(path) == expected }
    end

    def dig_path(path)
      path.to_s.split(".").reduce(@event.payload) do |node, key|
        node.is_a?(Hash) ? node[key] : nil
      end
    end
  end
end
