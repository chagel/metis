# Authoring for routines — saved prompts that fire on a schedule or a webhook
# event (docs/routines.md). Firing happens in the engine (RoutineSchedulerJob,
# Routine::EventDispatcher); `run` is the manual "fire now".
class RoutinesController < ApplicationController
  layout "settings"

  before_action :set_routine, only: %i[edit update destroy toggle run]
  before_action :require_manageable!, only: %i[edit update destroy toggle run]

  def index
    current_team.memberships.load
    routines = current_team.routines.visible_to(current_user).includes(:user, :project).order(:name)
    @mine, @team = current_team.personal? ? [ routines.to_a, [] ] : routines.partition(&:visibility_personal?)
    @tab = params[:tab].presence_in(%w[mine team]) || (@mine.empty? && @team.any? ? "team" : "mine")
  end

  def new
    @routine = current_team.routines.new(user: current_user, timezone: current_user.iana_timezone)
  end

  def create
    @routine = current_team.routines.new(routine_params)
    @routine.user = current_user
    apply_cooldown
    apply_model
    return refuse unless @routine.manageable_by?(current_user)

    if @routine.save
      redirect_to routines_path(tab: tab_for(@routine)), notice: t("flash.routines.create.notice")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @routine.assign_attributes(routine_params)
    apply_cooldown
    apply_model
    return refuse unless @routine.manageable_by?(current_user)

    if @routine.save
      redirect_to edit_routine_path(@routine), notice: t("flash.routines.update.notice")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @routine.name
    @routine.destroy
    redirect_to routines_path(tab: tab_for(@routine)), notice: t("flash.routines.destroy.notice", name: name)
  end

  def toggle
    @routine.update(enabled: !@routine.enabled)
    redirect_to routines_path(tab: tab_for(@routine))
  end

  def run
    conversation = @routine.fire!
    redirect_to conversation_path(conversation), notice: t("flash.routines.run.notice", name: @routine.name)
  end

  private

  def require_manageable!
    refuse unless @routine.manageable_by?(current_user)
  end

  def refuse
    redirect_to routines_path, alert: t("flash.routines.not_allowed")
  end

  def tab_for(routine)
    return if current_team.personal?

    routine.visibility_personal? ? "mine" : "team"
  end

  def set_routine
    @routine = current_team.routines.visible_to(current_user).find(params[:id])
  end

  # Merged, not assigned, so it doesn't clobber other trigger_config keys
  # (run settings, variables) the agent or a future form may have set.
  def apply_cooldown
    return unless params.dig(:routine, :cooldown_seconds)

    @routine.trigger_config = @routine.trigger_config.merge(
      "cooldown_seconds" => params[:routine][:cooldown_seconds].to_i
    )
  end

  # The fired conversation runs on this model (provider derived from the
  # catalog, as the composer does); blank uses the user's default model.
  def apply_model
    return unless params.dig(:routine).key?(:model)

    model = params[:routine][:model].presence
    settings = model ? { "model" => model, "provider" => Agent::Catalog.provider_for(model) }.compact : {}
    @routine.trigger_config = @routine.trigger_config.merge("settings" => settings)
  end

  def routine_params
    permitted = params.require(:routine).permit(
      :name, :prompt, :trigger_source, :visibility, :project_id,
      :cron, :timezone, :event_type
    )
    permitted[:project_id] = nil if permitted[:project_id].blank?
    permitted
  end
end
