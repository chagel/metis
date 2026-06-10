module Api
  module Bridge
    # The pull surface: a local agent claims the next dispatched delegated
    # task, optionally streams progress, and reports a result. See
    # docs/local-bridge.md.
    class TasksController < BaseController
      before_action :set_task, only: %i[events result]

      # GET /api/bridge/tasks — the claim queue, read-only. Lets a client
      # show the user what's waiting and pick (e.g. by matching a task's
      # project to its cwd) instead of blind-claiming FIFO.
      def index
        tasks = Task.claimable_by(current_bridge_user)
                    .order(:dispatched_at)
                    .includes(workflow_run: [ :workflow, { conversation: :project } ])
        render json: { tasks: tasks.map { |task| index_entry(task) } }
      end

      # GET /api/bridge/tasks/next — claim FIFO, or a specific task via
      # ?id=. 409 when the requested task is gone (claimed, settled, or
      # never yours).
      def claim
        task = Task.claim_next_for(current_bridge_user, client: bridge_client_name, id: params[:id])
        return render json: claim_payload(task) if task

        params[:id].present? ? head(:conflict) : head(:no_content)
      end

      # POST /api/bridge/tasks/:id/events
      def events
        entry = params.permit(:kind, :text).to_h
        @task.log_progress!(entry) if entry.present?
        head :accepted
      end

      # POST /api/bridge/tasks/:id/result
      def result
        @task.workflow_run.complete_delegated_task!(@task, result: result_params)
        head :ok
      end

      private

      # Scoped to delegated tasks in the caller's teams — a token from
      # another team can't reach this task.
      def set_task
        @task = Task.joins(:workflow_run)
                    .where(delegated: true, workflow_runs: { team_id: current_bridge_user.team_ids })
                    .find(params[:id])
      end

      def result_params
        params.permit(:status, :summary, artifacts: [ :type, :url, :files_changed, :insertions, :deletions ]).to_h
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
