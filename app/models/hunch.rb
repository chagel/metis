# A guess at what a user will need, with the work already done: a draft,
# a research summary, a review. Recorded by the foresight run, then used,
# or dismissed on the Hunches page; those outcomes are the measure.
class Hunch < ApplicationRecord
  MAX_PER_RUN = 3
  TTL = 14.days

  enum :impact,     { low: 0, medium: 1, high: 2 }, prefix: true
  enum :confidence, { low: 0, medium: 1, high: 2 }, prefix: true
  enum :status,     { ready: 0, used: 1, dismissed: 2, expired: 3 }

  belongs_to :team
  belongs_to :user
  belongs_to :direction, optional: true
  belongs_to :source_memory, class_name: "UserMemory", optional: true
  belongs_to :conversation, optional: true

  encrypts :body, :why_now, :dismiss_reason

  validates :title, presence: true, length: { maximum: 160 }
  validates :body, presence: true

  scope :for, ->(user, team) { where(user: user, team: team) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :stale, -> { ready.where(created_at: ...TTL.ago) }

  def self.expire_stale!
    stale.update_all(status: statuses[:expired], outcome_at: Time.current, updated_at: Time.current)
  end

  def use!
    update!(status: :used, outcome_at: Time.current)
  end

  def dismiss!(reason = nil)
    update!(status: :dismissed, dismiss_reason: reason.to_s.strip.presence, outcome_at: Time.current)
  end

  # The opening message of the chat a used hunch starts.
  def prompt
    lines = [ "#{I18n.t("hunches.prompt.intro")} **#{title}**", "", body ]
    lines += [ "", "#{I18n.t("hunches.prompt.why_now")} #{why_now}" ] if why_now.present?
    sources = Array(evidence).filter_map { |e| e["url"].presence && "- [#{e["title"].presence || e["url"]}](#{e["url"]})" }
    lines += [ "", I18n.t("hunches.prompt.evidence"), *sources ] if sources.any?
    lines.join("\n")
  end
end
