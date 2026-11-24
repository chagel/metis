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

  # 9, 30 → "9:30 AM"; matches the form preview's timeLabel().
  def routine_time_label(hour, minute)
    display = hour % 12
    format("%d:%02d %s", display.zero? ? 12 : display, minute, hour < 12 ? "AM" : "PM")
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

  # The schedule in words, matching the form's live preview; exotic crons
  # fall back to the raw expression.
  def routine_schedule_text(routine)
    return t("routines.routine.event", type: routine.event_type) unless routine.schedule?

    m, h, dom, mon, dow = routine.cron.to_s.split
    words = ->(key, **vars) { vars.reduce(t("routines.form.preview.#{key}")) { |text, (k, v)| text.sub("{#{k}}", v.to_s) } }
    tz = routine.timezone
    numeric = ->(v) { v.to_s.match?(/\A\d+\z/) }
    return words.(:custom, cron: routine.cron, tz: tz) unless mon == "*" && numeric.(m)
    return words.(:hourly, minute: format(":%02d", m.to_i), tz: tz) if [ h, dom, dow ].all?("*")
    return words.(:custom, cron: routine.cron, tz: tz) unless numeric.(h)

    time = routine_time_label(h.to_i, m.to_i)
    days = routine_cron_days(dow)
    if dom == "*" && dow == "*" then words.(:daily, time: time, tz: tz)
    elsif dom == "*" && days then words.(:weekly, days: days, time: time, tz: tz)
    elsif dow == "*" && numeric.(dom) then words.(:monthly, dom: dom, time: time, tz: tz)
    else words.(:custom, cron: routine.cron, tz: tz)
    end
  end

  # "1-5" / "1,3,5" → "Mon, Tue, …"; nil for steps or names.
  def routine_cron_days(dow)
    numbers = dow.to_s.split(",").flat_map do |token|
      case token
      when /\A\d\z/ then [ token.to_i % 7 ]
      when /\A(\d)-(\d)\z/ then ($1.to_i..$2.to_i).map { |n| n % 7 }
      else return nil
      end
    end.uniq
    return t("routines.form.preview.every_day") if numbers.size == 7

    labels = routine_day_options.to_h
    [ 1, 2, 3, 4, 5, 6, 0 ].select { |n| numbers.include?(n) }.map { |n| labels[n] }.join(", ")
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
