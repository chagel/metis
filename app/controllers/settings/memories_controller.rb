class Settings::MemoriesController < ApplicationController
  layout "settings"

  before_action :set_memory, only: %i[update destroy confirm]

  def index
    @memories = memories.newest_first.load
    @review = MemoryReview.routine_for(current_user, current_team)
    @last_review = @review&.conversations&.order(created_at: :desc)&.first
    week = Agent::MemoryReport.new(current_user, current_team, since: 1.week.ago)
    @corrections_this_week = week.corrections_count
    @corrections_last_week = week.previous_corrections_count
  end

  def update
    if @memory.edit_by_user(memory_params[:content])
      respond_with_row
    else
      redirect_to memories_path, alert: @memory.errors.full_messages.to_sentence
    end
  end

  def confirm
    @memory.confirm!
    respond_with_row
  end

  def destroy
    current_membership.record_memory_deletions!([ @memory.kind ])
    @memory.destroy
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@memory)) }
      format.html { redirect_to memories_path, notice: t("flash.settings.memories.destroy.notice") }
    end
  end

  def clear
    current_membership.record_memory_deletions!(memories.pluck(:kind))
    memories.delete_all
    redirect_to memories_path, notice: t("flash.settings.memories.clear.notice")
  end

  private

  def memories = UserMemory.for(current_user, current_team)

  def set_memory
    @memory = memories.find(params[:id])
  end

  def memory_params
    params.require(:user_memory).permit(:content)
  end

  def respond_with_row
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(helpers.dom_id(@memory), partial: "settings/memories/memory", locals: { memory: @memory }) }
      format.html { redirect_to memories_path }
    end
  end
end
