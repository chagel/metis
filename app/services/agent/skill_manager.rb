module Agent
  # Agent-driven management of team Skill rows for the operations the workspace
  # file path can't express: listing (including disabled skills, which aren't
  # staged into the workspace), toggling `enabled`, and deletion. Reached from
  # a chat over pi's Extension UI channel (Agent::HostBridge).
  #
  # Creating and editing skills stays on the native file path
  # (`.pi/skills/<slug>/` → Skill.upsert_from_files at turn end) — richer
  # (multi-file) and pi's native unit; don't duplicate it here. Writes are
  # team-admin-gated, matching SkillsController. Returns plain data for `list`
  # and `{ ok:, ... }` results the agent relays for the writes.
  class SkillManager
    def self.list(conversation)
      new(conversation).list
    end

    def self.set_enabled(conversation, params)
      new(conversation, params).set_enabled
    end

    def self.delete(conversation, params)
      new(conversation, params).delete
    end

    def initialize(conversation, params = {})
      @conversation = conversation
      @params = params
    end

    def list
      @conversation.team.skills.order(:slug).map do |skill|
        { slug: skill.slug, description: skill.description, enabled: skill.enabled }
      end
    end

    def set_enabled
      with_skill do |skill|
        skill.update!(enabled: truthy(@params["enabled"]), updated_by: @conversation.user)
        { ok: true, slug: skill.slug, enabled: skill.enabled }
      end
    end

    def delete
      with_skill do |skill|
        skill.destroy!
        { ok: true, slug: skill.slug, deleted: true }
      end
    end

    private

    # Shared guard + lookup for the write ops: not from inside a run, admin
    # only, skill must exist. Yields the resolved skill; rescues to { ok: false }.
    def with_skill
      return failure("Can't manage skills from inside a workflow run.") if @conversation.workflow_run.present?
      return failure("Only team admins can manage skills.") unless admin?

      skill = @conversation.team.skills.find_by(slug: slug)
      return failure("No skill named #{quoted(slug)} on this team.") unless skill

      yield skill
    rescue StandardError => e
      Rails.logger.error("SkillManager failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong managing the skill.")
    end

    def slug = @params["slug"].to_s.strip.downcase

    def truthy(value) = [ true, "true", 1, "1" ].include?(value)

    def admin?
      @conversation.user.memberships.find_by(team: @conversation.team)&.manages_team? || false
    end

    def failure(error) = { ok: false, error: error }
    def quoted(value) = "\"#{value.presence || "?"}\""
  end
end
