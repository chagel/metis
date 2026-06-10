module Api
  module Bridge
    # Payload builders and task scoping shared by the REST surface
    # (TasksController) and its MCP facade (McpController).
    module TaskPayloads
      private

      def find_delegated_task(ref_or_id)
        Task.delegated_for(current_bridge_user).find(Task.dereference(ref_or_id))
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
          ref: task.ref,
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
          ref: task.ref,
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

      # Prior steps' full output + artifact URLs. This bundle is the local
      # agent's entire brief (no session crosses machines) — never truncate it.
      def prior_step_summaries(run, task)
        run.tasks.completed.where(position: ...task.position).order(:position)
           .includes(assistant_message: { artifacts_attachments: :blob })
           .filter_map do |prior|
          content = step_content(prior)
          next if content.blank?

          entry = { name: prior.name, content: content }
          artifacts = step_artifacts(prior)
          entry[:artifacts] = artifacts if artifacts.any?
          entry
        end
      end

      def step_content(task)
        task.result_summary || task.assistant_message&.content.presence
      end

      def step_artifacts(task)
        attachments = task.assistant_message&.artifacts
        return [] unless attachments&.attached?

        attachments.map do |artifact|
          { name: artifact.filename.to_s, url: rails_blob_url(artifact, host: request.base_url) }
        end
      end
    end
  end
end
