# Add, pause and delete directions; they live on the Hunches tab.
class DirectionsController < ApplicationController
  before_action :set_direction, only: %i[destroy toggle]

  def create
    direction = directions.new(params.require(:direction).permit(:title, :brief))
    if direction.save
      redirect_to hunches_path(direction: direction.id), notice: t("flash.directions.create.notice")
    else
      redirect_to hunches_path, alert: direction.errors.full_messages.to_sentence
    end
  end

  def toggle
    @direction.update!(status: @direction.active? ? :paused : :active)
    redirect_to hunches_path(direction: @direction.id)
  end

  def destroy
    @direction.destroy!
    redirect_to hunches_path, notice: t("flash.directions.destroy.notice")
  end

  private

  def directions = Direction.for(current_user, current_team)

  def set_direction
    @direction = directions.find(params[:id])
  end
end
