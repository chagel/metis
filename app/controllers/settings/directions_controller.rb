class Settings::DirectionsController < ApplicationController
  layout "settings"

  before_action :set_direction, only: %i[update destroy toggle]

  def index
    @directions = directions.order(:created_at).includes(:hunches)
    @direction = directions.new
  end

  def create
    @direction = directions.new(direction_params)
    if @direction.save
      redirect_to back_to_hunches? ? hunches_path(direction: @direction.id) : directions_path,
                  notice: t("flash.settings.directions.create.notice")
    else
      return redirect_to(hunches_path, alert: @direction.errors.full_messages.to_sentence) if back_to_hunches?

      @directions = directions.where.not(id: nil).order(:created_at).includes(:hunches)
      render :index, status: :unprocessable_content
    end
  end

  def update
    if @direction.update(direction_params)
      redirect_to directions_path, notice: t("flash.settings.directions.update.notice")
    else
      redirect_to directions_path, alert: @direction.errors.full_messages.to_sentence
    end
  end

  def toggle
    @direction.update!(status: @direction.active? ? :paused : :active)
    redirect_to back_to_hunches? ? hunches_path(direction: @direction.id) : directions_path
  end

  def destroy
    @direction.destroy!
    redirect_to directions_path, notice: t("flash.settings.directions.destroy.notice")
  end

  private

  def directions = Direction.for(current_user, current_team)

  def back_to_hunches? = params[:return_to] == "hunches"

  def set_direction
    @direction = directions.find(params[:id])
  end

  def direction_params
    params.require(:direction).permit(:title, :brief)
  end
end
