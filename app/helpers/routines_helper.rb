module RoutinesHelper
  def routine_frequency_options
    %w[hourly daily weekly monthly custom].map { |k| [ t("routines.form.frequencies.#{k}"), k ] }
  end

  def routine_hour_options
    (0..23).map { |h| [ routine_hour_label(h), h ] }
  end

  # 0 → "12 AM", 9 → "9 AM", 13 → "1 PM".
  def routine_hour_label(hour)
    display = hour % 12
    display = 12 if display.zero?
    "#{display} #{hour < 12 ? "AM" : "PM"}"
  end

  def routine_minute_options
    (0..55).step(5).map { |m| [ format(":%02d", m), m ] }
  end

  # cron day-of-week: Sun=0, Mon=1 … Sat=6. Rendered Monday-first.
  def routine_day_options
    slugs = %w[sun mon tue wed thu fri sat]
    [ 1, 2, 3, 4, 5, 6, 0 ].map { |n| [ n, t("routines.form.day_abbr.#{slugs[n]}") ] }
  end

  # Label carries the GMT offset (ActiveSupport::TimeZone#to_s); value is the
  # IANA id fugit needs.
  def routine_timezone_options
    ActiveSupport::TimeZone.all.map { |tz| [ tz.to_s, tz.tzinfo.name ] }
  end

  # Event-type suggestions drawn from what the team has actually received — the
  # exact stored types plus a "family.*" wildcard per family. Correctly cased
  # per provider (GitHub "pull_request.opened", Linear "Issue.create"), unlike
  # a hardcoded guess; empty until the team's webhooks are wired and firing.
  def routine_event_type_suggestions
    types = current_team.webhook_events.distinct.pluck(:event_type)
    families = types.filter_map { |type| "#{type.split(".").first}.*" if type.include?(".") }
    (types + families).uniq.sort
  end
end
