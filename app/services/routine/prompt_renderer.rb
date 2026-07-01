class Routine
  # Interpolates a routine's prompt: replaces {{name}} placeholders with
  # built-in context vars (date/time/team/user, plus event_* on the webhook
  # path) merged over the routine's own trigger_config["variables"]. Unknown
  # placeholders are left untouched.
  class PromptRenderer
    PLACEHOLDER = /\{\{\s*([\w.]+)\s*\}\}/

    def self.render(routine, event: nil)
      new(routine, event).render
    end

    def initialize(routine, event)
      @routine = routine
      @event = event
    end

    def render
      @routine.prompt.gsub(PLACEHOLDER) { |match| vars.fetch(Regexp.last_match(1), match) }
    end

    private

    # Custom vars are the base; builtins and event vars win, so a user variable
    # named `date` or `event_payload` can't shadow the real value.
    def vars
      @vars ||= custom_vars.merge(event_vars).merge(builtins)
    end

    def builtins
      now = Time.current.in_time_zone(@routine.timezone)
      {
        "date" => now.strftime("%Y-%m-%d"),
        "time" => now.strftime("%H:%M"),
        "datetime" => now.strftime("%Y-%m-%d %H:%M %Z"),
        "day_of_week" => now.strftime("%A"),
        "timezone" => @routine.timezone,
        "team" => @routine.team.name,
        "user" => @routine.user.display_name,
        "routine" => @routine.name
      }
    end

    def event_vars
      return {} unless @event

      {
        "event_type" => @event.event_type.to_s,
        "event_provider" => @event.provider.to_s,
        "event_payload" => JSON.pretty_generate(@event.payload)
      }
    end

    def custom_vars
      vars = @routine.variables
      return {} unless vars.is_a?(Hash)

      vars.transform_keys(&:to_s).transform_values(&:to_s)
    end
  end
end
