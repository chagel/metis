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

  PROVIDER_LABELS = { "github" => "GitHub", "linear" => "Linear" }.freeze

  # Event types the team has actually received, grouped by connector for a
  # grouped <select>: [["GitHub", ["pull_request.opened", "pull_request.*"]], …].
  # Each group adds a "family.*" wildcard per family. `current` (the routine's
  # saved type) is folded in even if no longer collected, so editing can't blank
  # it. Empty until the team's webhooks are wired and firing.
  def routine_event_type_options(current = nil)
    groups = current_team.webhook_events.distinct.pluck(:provider, :event_type)
                         .group_by(&:first)
                         .map { |provider, rows| [ routine_provider_label(provider), routine_event_family(rows.map(&:last)) ] }
                         .sort_by(&:first)

    if current.present? && groups.none? { |_label, types| types.include?(current) }
      groups.unshift([ t("routines.form.event_current"), [ current ] ])
    end
    groups
  end

  def routine_event_family(types)
    families = types.filter_map { |type| "#{type.split(".").first}.*" if type.include?(".") }
    (types + families).uniq.sort
  end

  def routine_provider_label(provider)
    key = provider.is_a?(Integer) ? WebhookEvent.providers.key(provider) : provider.to_s
    PROVIDER_LABELS[key] || key.to_s.titleize
  end
end
