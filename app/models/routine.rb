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

  validates :name, presence: true, length: { maximum: NAME_MAX }, format: { without: /[\r\n]/ }
  validates :name, uniqueness: { scope: :team_id, case_sensitive: false, conditions: -> { visibility_team } }, if: :visibility_team?
  validates :name, uniqueness: { scope: %i[team_id user_id], case_sensitive: false, conditions: -> { visibility_personal } }, if: :visibility_personal?
  validates :prompt, presence: true
  validates :cron, presence: true, if: :schedule?
  validates :event_type, presence: true, if: :webhook?
  validate :cron_is_parseable, if: -> { schedule? && cron.present? }
  validate :timezone_is_known
  validate :project_in_team

  scope :active, -> { where(enabled: true) }
  scope :due, -> { active.schedule.where("next_run_at <= ?", Time.current) }
  # Personal routines belong to their user alone; team routines are open to
  # every member and managed by admins (docs/tenancy.md, scope within a team).
  scope :visible_to, ->(user) { visibility_team.or(where(user: user)) }
  scope :named, ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip).order(:id) }

  before_validation { self.visibility = :personal if team&.personal? }
  before_save :refresh_next_run_at

  store_accessor :trigger_config, :variables

  # The conversation settings (model/provider) a fired run launches with; an
  # unset routine gets its user's default model, like any new chat.
  def run_settings
    trigger_config["settings"].presence || {}
  end

  def manageable_by?(someone)
    visibility_personal? ? user_id == someone.id : team.managed_by?(someone)
  end

  # Connector names (plus GithubApp::BotServer::NAME) an unattended fire may
  # reach; set only from the routine form (docs/unattended-runs.md).
  def granted_connectors
    Array(trigger_config.dig("grants", "connectors")).map(&:to_s)
  end

  # label => grant, for the form. Connectors on one OAuth provider share the
  # user's token, so they're one grant ("provider:google"); the bot is its own.
  def grantable_connectors
    connectors = team.connectors.order(:name).to_a
    by_provider, others = connectors.partition { |connector| connector.catalog_app&.oauth_provider }
    choices = others.to_h { |connector| [ connector.catalog_app&.name || connector.name, connector.name ] }
    by_provider.group_by { |connector| connector.catalog_app.oauth_provider }.each do |provider, group|
      choices[provider_label(provider, group)] = Agent::RunPolicy.provider_grant(provider)
    end
    choices[I18n.t("routines.form.grants_github_bot")] = GithubApp::BotServer::NAME if GithubApp::BotServer.eligible(connectors)
    choices
  end

  def granted_actions
    Array(trigger_config.dig("grants", "actions")).map(&:to_s)
  end

  def grantable_actions
    Agent::RunPolicy::GRANTABLE_OPS.to_h { |op| [ I18n.t("routines.form.grants_actions.#{op}"), op ] }
  end

  def memory_review?
    trigger_config["purpose"] == MemoryReview::PURPOSE
  end

  def foresight?
    trigger_config["purpose"] == Foresight::PURPOSE
  end

  def cooldown_seconds
    trigger_config["cooldown_seconds"].to_i
  end

  # Fire the routine: start one chat turn in a fresh conversation owned by the
  # routine's user, and stamp last_run_at. `event` (a WebhookEvent) feeds the
  # prompt's event_* variables on the webhook path; `note` is appended to the
  # prompt for this fire only. Returns the conversation.
  def fire!(event: nil, note: nil)
    conversation = user.with_lock do
      UnattendedBudget.new(user).check!
      user.conversations.create!(
        team: team, project: project, routine: self,
        settings: run_settings.merge("fired_by_routine" => true), visibility: visibility, title: name
      )
    end
    ConversationTurn.start(conversation, content: [ rendered_prompt(event), note ].compact.join("\n\n"))
    update!(last_run_at: Time.current)
    conversation
  end

  # Scheduler path: row-locked so two overlapping scheduler ticks can't
  # double-fire, and it advances next_run_at past now so it won't reselect.
  def fire_scheduled!
    with_lock do
      return false unless enabled? && schedule? && next_run_at && next_run_at <= Time.current

      fire_unless_over_budget unless quiet?
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

  def provider_label(provider, group)
    brand = provider == "github" ? "GitHub" : provider.capitalize
    names = group.map { |connector| connector.catalog_app.name.delete_prefix("#{brand} ") }
    names == [ brand ] ? brand : "#{brand} (#{names.join(", ")})"
  end

  # A purpose-built routine with nothing to work on skips the night.
  def quiet?
    (memory_review? && !MemoryReview.activity?(self)) || (foresight? && !Foresight.activity?(self))
  end

  def fire_unless_over_budget
    fire!
  rescue UnattendedBudget::Exceeded => error
    Rails.logger.warn("Routine #{id} skipped: #{error.message}")
  end

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
