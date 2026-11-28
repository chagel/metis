module Agent
  # Agent-driven management of team Skill rows from a chat, over pi's Extension
  # UI channel (Agent::HostBridge).
  #
  # `list` covers both sources the runtime merges into the workspace: the repo's
  # built-in skills (always active, read-only) and the team's DB skills (which
  # may be disabled, and so aren't staged into the workspace). `create` and
  # `update` manage team skills only; update also toggles `enabled`. There is no
  # delete — removing a skill stays an operator action in the UI. Multi-file
  # skills still go through the native file path (`.pi/skills/<slug>/`); these
  # tools handle the single SKILL.md case. Writes are team-admin-gated, matching
  # SkillsController, and refused from inside a workflow run.
  class SkillManager
    def self.list(conversation)
      new(conversation).list
    end

    def self.create(conversation, params)
      new(conversation, params).create
    end

    def self.update(conversation, params)
      new(conversation, params).update
    end

    # The memory review's suggestion of a skill for a task that keeps coming
    # back: created disabled and visible only to its user until they enable it.
    def self.propose(conversation, params)
      new(conversation, params).propose
    end

    def initialize(conversation, params = {})
      @conversation = conversation
      @params = params
    end

    def list
      builtin = Agent::RepoSkills.all.map do |skill|
        { slug: skill.slug, description: skill.description, source: "builtin", status: "built-in" }
      end
      team = @conversation.team.skills.visible_to(@conversation.user).order(:slug).map do |skill|
        { slug: skill.slug, description: skill.description, source: "team",
          status: skill.status }
      end
      builtin + team
    end

    def create
      guarded do
        return failure("A skill named #{quoted(slug)} already exists — use metis_update_skill.") if taken?
        return failure("A new skill needs SKILL.md content.") if content.blank?

        skill = @conversation.team.skills.new(slug: slug, created_by: @conversation.user)
        skill.enabled = truthy(@params["enabled"]) if @params.key?("enabled")
        return failure(skill.errors.full_messages.join("; ")) unless skill.valid?

        persist(skill, "created")
      end
    end

    def propose
      guarded do
        return failure("A skill named #{quoted(slug)} already exists.") if taken?
        return failure("A proposal needs SKILL.md content.") if content.blank?

        persist(@conversation.team.skills.new(slug: slug, enabled: false, created_by: @conversation.user,
                                              proposed_by: @conversation.user), "proposed")
      end
    end

    def update
      guarded do
        skill = existing
        return failure("No team skill named #{quoted(slug)} on this team.") unless skill

        skill.enabled = truthy(@params["enabled"]) if @params.key?("enabled")
        persist(skill, "updated")
      end
    end

    private

    def guarded
      return failure("Can't manage skills from inside a workflow run.") if @conversation.workflow_run.present?
      return failure("Only team admins can manage skills.") unless admin?

      yield
    rescue StandardError => e
      Rails.logger.error("SkillManager failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong saving the skill.")
    end

    def persist(skill, action)
      skill.updated_by = @conversation.user
      if content.present?
        skill.replace_skill_md!(content)
        desc = Skill.parse_description(content)
        skill.description = desc if desc.present?
      end
      return failure(skill.errors.full_messages.join("; ")) unless skill.save

      { ok: true, action: action, slug: skill.slug, enabled: skill.enabled }
    end

    # Someone else's proposal is invisible here, so it can't be edited or enabled.
    def existing = @conversation.team.skills.visible_to(@conversation.user).find_by(slug: slug)
    def taken? = @conversation.team.skills.exists?(slug: slug)
    def slug = @params["slug"].to_s.strip.downcase
    def content = @params["content"].to_s
    def truthy(value) = [ true, "true", 1, "1" ].include?(value)

    def admin? = @conversation.team.managed_by?(@conversation.user)

    def failure(error) = { ok: false, error: error }
    def quoted(value) = "\"#{value.presence || "?"}\""
  end
end
