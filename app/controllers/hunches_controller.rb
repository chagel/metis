class HunchesController < ApplicationController
  layout "chat"

  DISMISS_REASONS = %w[not_relevant already_done wrong_timing not_good_enough].freeze

  before_action :set_nav_badges, only: :index
  before_action :set_hunch, only: %i[useful dismiss]

  def index
    @directions = directions.order(:status, :created_at)
    @ready_counts = hunches.ready.group(:direction_id).count
    @filter = filter
    @direction = directions.find_by(id: params[:direction]) if @filter == :direction
    @outcomes = Hunch.outcome_counts(hunches.where(direction: @direction)) if @direction
    @stats = Hunch.outcome_stats(current_user, current_team) if @filter == :history
    @hunches = filtered.newest_first.includes(:direction, :source_memory).limit(@filter == :history ? 50 : nil).load
    @last_run = Foresight.last_run_for(current_user, current_team)
  end

  # Fires foresight now, focused on one direction when one is selected; its
  # hunches land here when the run finishes.
  def read_my_mind
    direction = directions.find_by(id: params[:direction_id])
    focus = t("hunches.prompt.focus", id: direction.id, title: direction.title) if direction
    Foresight.ensure_for(current_user, current_team).fire!(note: focus)
    redirect_to hunches_path(direction: direction&.id), notice: t("flash.hunches.read_my_mind.notice")
  rescue UnattendedBudget::Exceeded => error
    redirect_to hunches_path, alert: error.message
  end

  # Right as it was, nothing more to do: it moves to History.
  def useful
    @hunch.use!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@hunch)) }
      format.html { redirect_to hunches_path, notice: t("flash.hunches.useful.notice") }
    end
  end

  def dismiss
    @hunch.dismiss!(dismiss_reason)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@hunch)) }
      format.html { redirect_to hunches_path, notice: t("flash.hunches.dismiss.notice") }
    end
  end

  private

  def hunches = Hunch.for(current_user, current_team)

  # The Hunches sidebar shows only the nav badges, not the chat list.
  def set_nav_badges
    set_sidebar_params
    @needs_you = needs_you_conversations
  end
  def directions = Direction.for(current_user, current_team)

  def filter
    return :history if params[:view] == "history"

    params[:direction].present? ? :direction : :all
  end

  def filtered
    case @filter
    when :history then hunches.where.not(status: :ready)
    when :direction then hunches.ready.where(direction: @direction)
    else hunches.ready
    end
  end

  def dismiss_reason
    key = params[:reason].to_s
    DISMISS_REASONS.include?(key) ? t("hunches.hunch.reasons.#{key}") : params[:reason_text]
  end

  def set_hunch
    @hunch = hunches.ready.find(params[:id])
  end
end
