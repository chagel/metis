module Api
  module Bridge
    # MCP facade over the bridge pull surface (docs/local-bridge.md): a
    # stateless streamable-HTTP server, one JSON-RPC message per POST.
    class McpController < BaseController
      include TaskPayloads

      TOOLS = [
        {
          name: "list_tasks",
          description: "List the delegated Metis workflow tasks waiting to be claimed " \
                       "(read-only). Use it to pick the task matching the repo you are in.",
          inputSchema: { type: "object", properties: {}, required: [] }
        },
        {
          name: "get_next_task",
          description: "Claim a delegated Metis workflow task and receive its prompt and " \
                       "context. Claims the oldest task, or a specific one via task_id " \
                       "(prefer list_tasks + task_id when several are waiting).",
          inputSchema: {
            type: "object",
            properties: {
              task_id: { type: "integer", description: "Claim this specific task instead of the oldest" }
            },
            required: []
          }
        },
        {
          name: "report_progress",
          description: "Post a short progress note onto a claimed Metis task (optional, " \
                       "shows up in the run timeline).",
          inputSchema: {
            type: "object",
            properties: {
              task_id: { type: "integer" },
              text: { type: "string", description: "One line of progress, e.g. 'tests green, opening PR'" }
            },
            required: %w[task_id text]
          }
        },
        {
          name: "submit_result",
          description: "Report a claimed Metis task finished. The workflow run resumes " \
                       "immediately, so call this exactly once, when the work is done.",
          inputSchema: {
            type: "object",
            properties: {
              task_id: { type: "integer" },
              status: { type: "string", enum: %w[completed failed] },
              summary: { type: "string", description: "One or two sentences on the outcome" },
              artifacts: {
                type: "array",
                description: %(Links produced by the work, e.g. [{"type":"pr","url":"…"}]),
                items: {
                  type: "object",
                  properties: { type: { type: "string" }, url: { type: "string" } }
                }
              }
            },
            required: %w[task_id status summary]
          }
        }
      ].freeze

      def handle
        message = JSON.parse(request.raw_post)
        return head :accepted if message["id"].nil? # notification

        case message["method"]
        when "initialize"
          rpc_result(message, {
            protocolVersion: message.dig("params", "protocolVersion") || "2025-03-26",
            capabilities: { tools: {} },
            serverInfo: { name: "metis-bridge", version: "1.0.0" }
          })
        when "ping"
          rpc_result(message, {})
        when "tools/list"
          rpc_result(message, { tools: TOOLS })
        when "tools/call"
          rpc_result(message, call_tool(message.dig("params", "name"),
                                        message.dig("params", "arguments") || {}))
        else
          rpc_error(message["id"], -32_601, "Method not found: #{message["method"]}")
        end
      rescue JSON::ParserError
        rpc_error(nil, -32_700, "Parse error")
      end

      private

      def call_tool(name, args)
        case name
        when "list_tasks"      then list_tasks
        when "get_next_task"   then get_next_task(args["task_id"])
        when "report_progress" then report_progress(args)
        when "submit_result"   then submit_result(args)
        else tool_error("Unknown tool: #{name}")
        end
      rescue ActiveRecord::RecordNotFound
        tool_error("Task #{args["task_id"]} not found in your claim scope.")
      rescue KeyError => e
        tool_error("Missing argument: #{e.key}")
      end

      def list_tasks
        entries = claim_queue.map { |task| index_entry(task) }
        return tool_text("No delegated tasks waiting.") if entries.empty?

        tool_text(JSON.pretty_generate(entries))
      end

      def get_next_task(task_id)
        task = Task.claim_next_for(current_bridge_user, client: bridge_client_name, id: task_id)
        return tool_text(JSON.pretty_generate(claim_payload(task))) if task
        return tool_text("No delegated tasks waiting.") if task_id.blank?

        tool_error("Task #{task_id} is no longer claimable (already claimed or settled). Run list_tasks for the current queue.")
      end

      def report_progress(args)
        task = find_delegated_task(args.fetch("task_id"))
        task.log_progress!({ "kind" => "log", "text" => args.fetch("text").to_s })
        tool_text("Progress recorded.")
      end

      def submit_result(args)
        task = find_delegated_task(args.fetch("task_id"))
        result = {
          "status" => args.fetch("status"),
          "summary" => args.fetch("summary"),
          "artifacts" => args["artifacts"]
        }.compact
        task.workflow_run.complete_delegated_task!(task, result: result)
        tool_text("Result submitted — the run resumes in Metis.")
      end

      def tool_text(text)
        { content: [ { type: "text", text: text } ], isError: false }
      end

      def tool_error(text)
        { content: [ { type: "text", text: text } ], isError: true }
      end

      def rpc_result(message, result)
        render json: { jsonrpc: "2.0", id: message["id"], result: result }
      end

      def rpc_error(id, code, text)
        render json: { jsonrpc: "2.0", id: id, error: { code: code, message: text } }
      end
    end
  end
end
