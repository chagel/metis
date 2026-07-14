module Agent
  # Read-only usage report over the persistent workspace root — one
  # deterministic row per u*/c* scope, symlinks never followed. Backs
  # `bin/rails metis:workspaces:report`. Orphan scopes (no matching
  # Conversation row) are flagged, never deleted.
  class WorkspaceReport
    class ScanError < StandardError; end

    def initialize(root: Workspace::PERSISTENT_ROOT)
      @root = Pathname.new(root).expand_path
    end

    def to_s
      space = WorkspaceCleanup.free_space(root: @root)
      raise ScanError, "cannot determine free space for #{@root}" unless space

      all = rows
      lines = [
        "root=#{@root} free_percent=#{space.free_percent.round(1)} " \
        "total_kb=#{space.total_kb} available_kb=#{space.available_kb}",
        "scopes=#{all.size} total_bytes=#{all.sum { |row| row[:total_bytes] }}"
      ]
      (lines + all.map { |row| format_row(row) }).join("\n")
    end

    def rows
      raise ScanError, "persistent root #{@root} is not a directory" unless @root.directory?

      WorkspaceCleanup.scan_scopes(root: @root)
        .sort_by { |scope| [ scope[:user_id], scope[:conversation_id] ] }
        .map { |scope| row_for(scope) }
    rescue SystemCallError => e
      raise ScanError, "cannot scan #{@root}: #{e.message}"
    end

    private

    def row_for(scope)
      conversation = Conversation.find_by(id: scope[:conversation_id], user_id: scope[:user_id])
      {
        user_id: scope[:user_id],
        conversation_id: scope[:conversation_id],
        total_bytes: WorkspaceCleanup.bytes_under(scope[:path]),
        sessions_bytes: WorkspaceCleanup.bytes_under(scope[:path].join("sessions")),
        workspace_bytes: WorkspaceCleanup.bytes_under(scope[:path].join("workspace")),
        conversation: conversation.present?,
        runtime: conversation&.runtime_label,
        workflow_status: conversation&.workflow_run&.status,
        archived: conversation ? conversation.archived? : nil,
        inflight: conversation ? conversation.turn_in_progress? : nil,
        evicted_at: conversation&.docker_workspace_evicted_at,
        eviction_reason: conversation&.docker_workspace_eviction_reason,
        orphan: conversation.nil?
      }
    end

    def format_row(row)
      "scope " + row.map { |key, value| "#{key}=#{format_value(value)}" }.join(" ")
    end

    def format_value(value)
      case value
      when nil  then "-"
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601
      else value.to_s.match?(/\s/) ? value.to_s.inspect : value.to_s
      end
    end
  end
end
