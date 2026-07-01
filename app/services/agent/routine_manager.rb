module Agent
  # Agent-driven management of team Routine rows from a chat, over pi's
  # Extension UI channel (Agent::HostBridge). `list` reads; `create`/`update`
  # mutate. Writes are team-admin-gated (matching RoutinesController) and
  # refused from inside a workflow run. A routine the agent creates starts
  # disabled — a self-firing rule shouldn't go live without the operator
  # enabling it. There's no delete tool — removing a routine stays an operator
  # action in the UI. Never raises into the turn — a failure is { ok: false }.
  class RoutineManager
    TRIGGERS = %w[schedule webhook].freeze
    VISIBILITIES = %w[personal team].freeze

    def self.list(conversation) = new(conversation).list
    def self.create(conversation, params) = new(conversation, params).create
    def self.update(conversation, params) = new(conversation, params).update

    def initialize(conversation, params = {})
      @conversation = conversation
      @params = params
    end

    def list
      @conversation.team.routines.order(:name).map do |routine|
        {
          name: routine.name, trigger: routine.trigger_source,
          schedule: (routine.schedule? ? "#{routine.cron} (#{routine.timezone})" : nil),
          event_type: (routine.webhook? ? routine.event_type : nil),
          visibility: routine.visibility, enabled: routine.enabled?
        }
      end
    end

    def create
      guarded do
        return failure("A routine named #{quoted(name)} already exists — use metis_update_routine.") if existing

        # Always starts disabled — a self-firing rule the agent authored
        # shouldn't go live without the operator enabling it (via the UI or
        # metis_update_routine).
        routine = @conversation.team.routines.new(user: @conversation.user, enabled: false)
        if (error = apply(routine))
          return failure(error)
        end

        persist(routine, "created")
      end
    end

    def update
      guarded do
        routine = existing
        return failure("No routine named #{quoted(name)} on this team.") unless routine

        if (error = apply(routine))
          return failure(error)
        end
        routine.enabled = ActiveModel::Type::Boolean.new.cast(@params["enabled"]) if @params.key?("enabled")

        persist(routine, "updated")
      end
    end

    private

    # Sets the supplied fields on the routine; returns an error string or nil.
    # Partial — update touches only the keys the agent passed. name is the
    # lookup key on update, so it never renames.
    def apply(routine)
      routine.name = name if routine.new_record?
      routine.prompt = arg(:prompt) if has?(:prompt)
      routine.cron = arg(:cron) if has?(:cron)
      routine.timezone = arg(:timezone) if has?(:timezone)
      routine.event_type = arg(:event_type) if has?(:event_type)

      if has?(:trigger)
        return "Trigger must be one of: #{TRIGGERS.join(", ")}." unless TRIGGERS.include?(arg(:trigger))

        routine.trigger_source = arg(:trigger)
      end

      if has?(:visibility)
        return "Visibility must be one of: #{VISIBILITIES.join(", ")}." unless VISIBILITIES.include?(arg(:visibility))

        routine.visibility = arg(:visibility)
      end

      if has?(:cooldown_seconds)
        routine.trigger_config = routine.trigger_config.merge("cooldown_seconds" => arg(:cooldown_seconds).to_i)
      end

      if has?(:model) || has?(:provider)
        settings, error = Agent::ModelSelection.resolve(routine.run_settings, model: arg(:model), provider: arg(:provider))
        return error if error

        routine.trigger_config = routine.trigger_config.merge("settings" => settings)
      end

      apply_project(routine)
    end

    def apply_project(routine)
      return nil unless has?(:project)

      project_name = arg(:project)
      if project_name.blank?
        routine.project = nil
        return nil
      end

      project = @conversation.team.projects.named(project_name).first
      return "No project named #{quoted(project_name)} on this team." unless project

      routine.project = project
      nil
    end

    def guarded
      return failure("Can't manage routines from inside a workflow run.") if @conversation.workflow_run.present?
      return failure("Only team admins can manage routines.") unless admin?

      yield
    rescue StandardError => e
      Rails.logger.error("RoutineManager failed for conversation #{@conversation.id}: #{e.class}: #{e.message}")
      failure("Something went wrong saving the routine.")
    end

    def persist(routine, action)
      return failure(routine.errors.full_messages.join("; ")) unless routine.save

      { ok: true, action: action, name: routine.name, enabled: routine.enabled,
        url: Rails.application.routes.url_helpers.edit_routine_path(routine) }
    end

    def existing = @conversation.team.routines.named(name).first
    def name = @params["name"].to_s.strip
    def admin? = @conversation.team.managed_by?(@conversation.user)
    def has?(key) = @params.key?(key.to_s)
    def arg(key) = @params[key.to_s].to_s.strip
    def failure(error) = { ok: false, error: error }
    def quoted(value) = "\"#{value.presence || "?"}\""
  end
end
