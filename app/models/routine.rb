# A saved prompt that fires on its own — on a cron schedule or a webhook
# event. Firing starts a normal chat turn with the prompt, so the agent can
# do anything (answer, hit a connector, open a PR, or metis_start_workflow).
# See docs/routines.md.
class Routine < ApplicationRecord
  belongs_to :team
  belongs_to :user
  belongs_to :project, optional: true
  has_many :conversations, dependent: :nullify

  NAME_MAX = 80

  enum :trigger_source, { schedule: 0, webhook: 1 }, default: :schedule
  enum :visibility, { personal: 0, team: 1 }, prefix: :visibility, default: :personal

  normalizes :name, with: ->(name) { name.to_s.strip }
  normalizes :timezone, with: ->(tz) { tz.to_s.strip.presence || "UTC" }

  validates :name, presence: true,
                   uniqueness: { scope: :team_id, case_sensitive: false },
                   length: { maximum: NAME_MAX },
                   format: { without: /[\r\n]/ }
  validates :prompt, presence: true
  validates :cron, presence: true, if: :schedule?
  validates :event_type, presence: true, if: :webhook?
  validate :cron_is_parseable, if: -> { schedule? && cron.present? }
  validate :timezone_is_known
  validate :project_in_team

  scope :active, -> { where(enabled: true) }
  scope :due, -> { active.schedule.where("next_run_at <= ?", Time.current) }
  scope :named, ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip).order(:id) }

  before_save :refresh_next_run_at

  store_accessor :trigger_config, :variables

  # The conversation settings (model/provider) a fired run launches with; an
  # unset routine inherits the deployment defaults like any new chat.
  def run_settings
    trigger_config["settings"].presence || {}
  end

  def cooldown_seconds
    trigger_config["cooldown_seconds"].to_i
  end

  # Fire the routine: start one chat turn in a fresh conversation owned by the
  # routine's user, and stamp last_run_at. `event` (a WebhookEvent) feeds the
  # prompt's event_* variables on the webhook path. Returns the conversation.
  def fire!(event: nil)
    conversation = user.conversations.create!(
      team: team, project: project, routine: self,
      settings: run_settings, visibility: visibility, title: name
    )
    ConversationTurn.start(conversation, content: rendered_prompt(event))
    update!(last_run_at: Time.current)
    conversation
  end

  # Scheduler path: row-locked so two overlapping scheduler ticks can't
  # double-fire, and it advances next_run_at past now so it won't reselect.
  def fire_scheduled!
    with_lock do
      return false unless enabled? && schedule? && next_run_at && next_run_at <= Time.current

      fire!
      update!(next_run_at: next_cron_time)
      true
    end
  end

  # Does this routine respond to the given WebhookEvent? Exact event_type, or a
  # "pull_request.*" wildcard matching the type's prefix.
  def matches_event?(event)
    return false unless enabled? && webhook?

    pattern = event_type.to_s.strip
    return true if pattern == event.event_type
    return false unless pattern.end_with?(".*")

    event.event_type.to_s.start_with?(pattern.delete_suffix("*"))
  end

  def within_cooldown?
    cooldown_seconds.positive? && last_run_at.present? && last_run_at > cooldown_seconds.seconds.ago
  end

  def friendly_schedule
    return unless schedule? && cron.present?

    Fugit::Cron.parse(cron)&.to_cron_s
  end

  private

  def rendered_prompt(event)
    Routine::PromptRenderer.render(self, event: event)
  end

  def refresh_next_run_at
    if schedule? && enabled? && cron.present?
      self.next_run_at = next_cron_time if next_run_at.nil? || will_save_change_to_cron? || will_save_change_to_timezone? || will_save_change_to_enabled?
    else
      self.next_run_at = nil
    end
  end

  # The IANA zone is embedded as cron's trailing field so fugit evaluates the
  # fields in that zone (a TimeWithZone argument alone is ignored).
  def next_cron_time
    cron_obj = Fugit::Cron.parse([ cron, timezone ].join(" "))
    return nil unless cron_obj

    cron_obj.next_time.utc
  end

  # Require exactly 5 fields: next_cron_time appends the timezone as cron's 6th
  # field, so a cron already carrying a zone would become unparseable there and
  # silently never fire.
  def cron_is_parseable
    errors.add(:cron, :invalid) unless cron.to_s.split.size == 5 && Fugit::Cron.parse(cron)
  end

  def timezone_is_known
    errors.add(:timezone, :invalid) if ActiveSupport::TimeZone[timezone.to_s].nil?
  end

  def project_in_team
    return if project_id.blank?
    return if team&.projects&.exists?(project_id)

    errors.add(:project_id, :not_in_team)
  end
end
