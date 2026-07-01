# Authoring for routines — saved prompts that fire on a schedule or a webhook
# event (docs/routines.md). Firing happens in the engine (RoutineSchedulerJob,
# Routine::EventDispatcher); `run` is the manual "fire now".
class RoutinesController < ApplicationController
  layout "settings"

  before_action :set_routine, only: %i[edit update destroy toggle run]
  before_action :require_team_admin!, except: :index

  def index
    @routines = current_team.routines.order(:name)
  end

  def new
    tz = ActiveSupport::TimeZone[current_user.timezone.to_s]&.tzinfo&.name || "UTC"
    @routine = current_team.routines.new(user: current_user, timezone: tz)
  end

  def create
    @routine = current_team.routines.new(routine_params)
    @routine.user = current_user
    apply_cooldown
    apply_model
    if @routine.save
      redirect_to routines_path, notice: t("flash.routines.create.notice")
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
    if @routine.save
      redirect_to edit_routine_path(@routine), notice: t("flash.routines.update.notice")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @routine.name
    @routine.destroy
    redirect_to routines_path, notice: t("flash.routines.destroy.notice", name: name)
  end

  def toggle
    @routine.update(enabled: !@routine.enabled)
    redirect_to routines_path
  end

  def run
    conversation = @routine.fire!
    redirect_to conversation_path(conversation), notice: t("flash.routines.run.notice", name: @routine.name)
  end

  private

  def set_routine
    @routine = current_team.routines.find(params[:id])
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
  # catalog, as the composer does); blank inherits the deployment default.
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
