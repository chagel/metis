module Api
  module Bridge
    # The pull surface: a local agent claims the next dispatched delegated
    # task, optionally streams progress, and reports a result. See
    # docs/local-bridge.md.
    class TasksController < BaseController
      include TaskPayloads

      before_action :set_task, only: %i[show events result]
      before_action :ensure_task_live, only: %i[events result]

      # The claim queue, read-only — a client picks by repo instead of
      # blind-claiming FIFO.
      def index
        render json: { tasks: claim_queue.map { |task| index_entry(task) } }
      end

      # Claims FIFO, or a specific task via ?id=, or scoped via ?project=
      # — 409 when that task is gone (claimed, settled, or never yours).
      def claim
        task = Task.claim_next_for(current_bridge_user, client: bridge_client_name,
                                   id: params[:id], project: params[:project])
        return render json: claim_payload(task) if task

        params[:id].present? ? head(:conflict) : head(:no_content)
      end

      # Liveness check for an unattended client: a daemon polls this
      # between agent events and kills the agent when the task settled or
      # its claim moved (cancellation / reclaim — the active upgrade of
      # stop-on-410).
      def show
        render json: {
          task_id: @task.id, ref: @task.ref, status: @task.status,
          claimed_by: @task.claimed_by
        }
      end

      def events
        entry = params.permit(:kind, :text).to_h
        @task.log_progress!(entry) if entry.present?
        head :accepted
      end

      def result
        @task.workflow_run.complete_delegated_task!(@task, result: result_params)
        head :ok
      end

      private

      def set_task
        @task = find_delegated_task(params[:id])
      end

      # 410 means stop work now: the run was cancelled or the claim was
      # reclaimed — the claim that holds the task wins, not the last writer.
      def ensure_task_live
        head :gone unless @task.reportable_by?(current_bridge_user)
      end

      def result_params
        params.permit(:status, :summary, :agent, :model,
                      artifacts: [ :type, :url, :files_changed, :insertions, :deletions ]).to_h
      end
    end
  end
end
