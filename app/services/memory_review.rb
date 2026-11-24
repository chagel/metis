# The nightly "Memory review" routine: one per user per team, created with
# their first memory. Each fire is an ordinary turn that reads
# metis_memory_report and tidies the memories; Routine#fire_scheduled! skips
# nights with nothing new. See docs/memory.md.
module MemoryReview
  PURPOSE = "memory_review".freeze
  CRON = "0 3 * * *".freeze

  PROMPT = <<~MD.freeze
    Nightly memory review. Call metis_memory_report, then tidy what you know about me
    with metis_update_memory, metis_forget and metis_remember:

    - Merge duplicates and settle contradictions; keep the one I stated, else the newer.
    - Memories used in replies I didn't correct, cancel or fork: raise confidence a step.
    - Memories used in replies I corrected: rewrite them from the correction notes, or
      lower confidence; forget ones that keep failing.
    - A correction that shows up three or more times becomes a high-confidence preference.
    - Corrections on replies that used no memory point to something missing: record it.
    - Memories I edited or deleted myself are final: never undo an edit or re-learn a
      deleted kind of thing without new evidence.

    Then reply with a short note in a few bullets: what you changed and why. If the
    report shows nothing new, reply "Nothing new." and stop.
  MD

  def self.routine_for(user, team)
    team.routines.where(user: user).find_by("trigger_config->>'purpose' = ?", PURPOSE)
  end

  def self.ensure_for(user, team)
    routine_for(user, team) || team.routines.create!(
      user: user, name: name_for(user, team), prompt: PROMPT, cron: CRON,
      timezone: iana_zone(user.timezone), enabled: true, trigger_config: { "purpose" => PURPOSE }
    )
  end

  # Where the current review's report starts: the review before it.
  def self.window_start(user, team, before: Time.current)
    routine_for(user, team)&.conversations&.where(created_at: ...before)&.maximum(:created_at)
  end

  def self.activity?(routine)
    Agent::MemoryReport.new(routine.user, routine.team, since: routine.last_run_at || routine.created_at).activity?
  end

  def self.name_for(user, team)
    name = "Memory review · #{user.display_name}".truncate(Routine::NAME_MAX)
    team.routines.named(name).exists? ? "#{name.truncate(Routine::NAME_MAX - 8)} ##{user.id}" : name
  end

  # Users may store a Rails zone name; cron (fugit) needs the IANA one.
  def self.iana_zone(zone)
    ActiveSupport::TimeZone[zone.to_s]&.tzinfo&.name || "UTC"
  end
  private_class_method :name_for, :iana_zone
end
