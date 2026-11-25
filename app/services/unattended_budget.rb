# Daily limits on one user's unattended work (routine fires), over a rolling
# 24 hours. A fire past either limit is refused before its conversation
# exists. See docs/unattended-runs.md.
class UnattendedBudget
  class Exceeded < StandardError; end

  WINDOW = 24.hours

  def initialize(user)
    @user = user
  end

  def check!
    raise Exceeded, I18n.t("unattended_budget.runs", limit: run_limit) if runs >= run_limit
    raise Exceeded, I18n.t("unattended_budget.cost", limit: format("%.2f", cost_limit)) if cost >= cost_limit
  end

  def runs = recent.count

  def cost = Message.where(conversation: recent, role: :assistant).sum(:cost).to_f

  private

  def recent = @user.conversations.routines.where(created_at: WINDOW.ago..)

  def run_limit = Rails.application.config.x.agent.unattended_daily_runs

  def cost_limit = Rails.application.config.x.agent.unattended_daily_cost
end
