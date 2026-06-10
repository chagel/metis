module Api
  module Bridge
    # The pull surface: a local agent claims the next dispatched delegated
    # task, optionally streams progress, and reports a result. See
    # docs/local-bridge.md.
    class TasksController < BaseController
      include TaskPayloads

      before_action :set_task, only: %i[events result]

      # GET /api/bridge/tasks — the claim queue, read-only. Lets a client
      # show the user what's waiting and pick (e.g. by matching a task's
      # project to its cwd) instead of blind-claiming FIFO.
      def index
        render json: { tasks: claim_queue.map { |task| index_entry(task) } }
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

      def set_task
        @task = find_delegated_task(params[:id])
      end

      def result_params
        params.permit(:status, :summary, artifacts: [ :type, :url, :files_changed, :insertions, :deletions ]).to_h
      end
    end
  end
end
