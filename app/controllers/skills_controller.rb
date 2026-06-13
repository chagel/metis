class SkillsController < ApplicationController
  layout "settings"

  TABS = %w[team builtin marketplace].freeze

  before_action :set_skill, only: %i[edit update destroy add_file destroy_file download_file]
  # Members use the team's skills (view, download); only admins curate them.
  before_action :require_team_admin!, except: %i[index download_file]

  def index
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "team"
    case @tab
    when "team"
      @skills = team.skills.order(updated_at: :desc)
    when "builtin"
      @repo_skills = Agent::RepoSkills.all
    when "marketplace"
      @featured = Agent::SkillMarketplace::FEATURED
      @existing_slugs = team.skills.pluck(:slug).to_set
    end
  end

  def new
    @skill = team.skills.new
  end

  def create
    @skill = team.skills.new(skill_params)
    @skill.created_by = current_user
    @skill.updated_by = current_user
    write_skill_md!(@skill, params.dig(:skill, :skill_md))

    if @skill.save
      redirect_to edit_skill_path(@skill), notice: t("flash.skills.create.notice")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    @skill.assign_attributes(skill_params)
    @skill.updated_by = current_user
    write_skill_md!(@skill, params.dig(:skill, :skill_md))

    if @skill.save
      redirect_to edit_skill_path(@skill), notice: t("flash.skills.update.notice")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @skill.destroy
    redirect_to skills_path, notice: t("flash.skills.destroy.notice", slug: @skill.slug)
  end

  def import_form
  end

  def import
    url = params[:url].to_s.strip
    return redirect_to skills_path, alert: t("flash.skills.import.blank_url") if url.blank?

    ImportSkillJob.perform_later(team_id: team.id, by_user_id: current_user.id, url: url)
    redirect_to skills_path,
                notice: t("flash.skills.import.notice", name: File.basename(url))
  end

  def add_file
    path = params[:path].to_s.strip
    upload = params[:file]

    unless upload.respond_to?(:read)
      return redirect_to edit_skill_path(@skill), alert: t("flash.skills.add_file.no_file")
    end
    unless Skill.valid_file_path?(path)
      return redirect_to edit_skill_path(@skill), alert: t("flash.skills.add_file.invalid_path", depth: Skill::MAX_FILE_PATH_DEPTH)
    end
    if upload.size > Skill::MAX_FILE_SIZE
      return redirect_to edit_skill_path(@skill),
             alert: t("flash.skills.add_file.too_large", size: Skill::MAX_FILE_SIZE / 1.megabyte)
    end

    @skill.replace_file!(path, upload.read, upload.content_type.presence)
    @skill.update!(updated_by: current_user)
    redirect_to edit_skill_path(@skill), notice: t("flash.skills.add_file.notice", path: path)
  end

  def destroy_file
    attachment = @skill.files.find_by(id: params[:file_id])
    return redirect_to edit_skill_path(@skill), alert: t("flash.skills.destroy_file.not_found") unless attachment

    rel = @skill.relative_path(attachment)
    attachment.purge
    @skill.update!(updated_by: current_user)
    redirect_to edit_skill_path(@skill), notice: t("flash.skills.destroy_file.notice", rel: rel)
  end

  def download_file
    attachment = @skill.files.find_by(id: params[:file_id])
    return head :not_found unless attachment

    send_data attachment.download,
              filename: File.basename(@skill.relative_path(attachment)),
              type: attachment.content_type,
              disposition: "inline"
  end

  private

  def team
    current_team
  end

  def set_skill
    @skill = team.skills.find(params[:id])
  end

  def skill_params
    params.require(:skill).permit(:slug, :description, :enabled)
  end

  # Blank body means "don't touch" — slug/enabled may still be saving.
  def write_skill_md!(skill, body)
    return if body.nil?
    skill.replace_skill_md!(body.to_s)
  end
end
