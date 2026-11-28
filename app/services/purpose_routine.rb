# A routine Metis creates per user per team for one purpose (MemoryReview,
# Foresight). The extending module defines PURPOSE, NAME, CRON, PROMPT,
# WRITE_OPS (HostBridge writes only its runs may make unattended) and
# activity?(routine) (false skips a scheduled fire).
module PurposeRoutine
  ALL = %w[MemoryReview Foresight].freeze

  def self.all = ALL.map(&:constantize)

  def self.for(purpose) = all.find { |mod| mod::PURPOSE == purpose }

  def routine_for(user, team)
    team.routines.where(user: user).find_by("trigger_config->>'purpose' = ?", self::PURPOSE)
  end

  def last_run_for(user, team) = routine_for(user, team)&.conversations&.order(created_at: :desc)&.first

  def ensure_for(user, team)
    routine_for(user, team) || team.routines.create!(
      user: user, name: self::NAME, prompt: self::PROMPT, cron: self::CRON,
      timezone: user.iana_timezone, enabled: true, trigger_config: { "purpose" => self::PURPOSE }
    )
  end
end
