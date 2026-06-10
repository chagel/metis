module Api
  module Bridge
    # Payload builders and task scoping shared by the REST surface
    # (TasksController) and its MCP facade (McpController).
    module TaskPayloads
      private

      # Scoped to delegated tasks in the caller's teams — a token from
      # another team can't reach this task.
      def find_delegated_task(id)
        Task.joins(:workflow_run)
            .where(delegated: true, workflow_runs: { team_id: current_bridge_user.team_ids })
            .find(id)
      end

      def claim_queue
        Task.claimable_by(current_bridge_user)
            .order(:dispatched_at)
            .includes(workflow_run: [ :workflow, { conversation: :project } ])
      end

      def index_entry(task)
        run = task.workflow_run
        {
          task_id: task.id,
          run_id: run.id,
          name: task.name,
          prompt: task.prompt,
          workflow: run.workflow&.name,
          project: run.conversation.project&.name,
          dispatched_at: task.dispatched_at&.iso8601
        }
      end

      def claim_payload(task)
        run = task.workflow_run
        {
          task_id: task.id,
          run_id: run.id,
          name: task.name,
          prompt: task.prompt,
          context: {
            project: project_context(run),
            prior_steps: prior_step_summaries(run, task)
          }.compact
        }
      end

      def project_context(run)
        project = run.conversation.project
        return unless project

        { name: project.name, about: project.about }
      end

      # Distilled context for the local agent — completed prior steps'
      # outcomes, not a pi session (no continuity across machines).
      def prior_step_summaries(run, task)
        run.tasks.completed.where("position < ?", task.position).order(:position).filter_map do |prior|
          summary = step_summary(prior)
          { name: prior.name, summary: summary } if summary.present?
        end
      end

      def step_summary(task)
        task.result["summary"].presence || task.assistant_message&.content.to_s.truncate(400).presence
      end
    end
  end
end
