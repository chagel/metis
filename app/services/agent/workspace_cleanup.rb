require "open3"
require "timeout"

module Agent
  # Safe deletion and measurement of persistent conversation scopes
  # (Agent::Workspace.persistent). Warm eviction deletes workspace/ and
  # keeps sessions/ so pi can still --continue; scope destruction removes
  # everything after the conversation row is gone. All paths are built
  # from validated integer ids and verified against the expanded root —
  # never derived from filenames or job-provided paths. See
  # docs/session-persistence.md.
  class WorkspaceCleanup
    class UnsafePath < StandardError; end

    SCOPE_SHAPE = %r{\Au\d+/c\d+(/workspace)?\z}

    FreeSpace = Struct.new(:total_kb, :available_kb) do
      def free_percent
        available_kb * 100.0 / total_kb
      end
    end

    attr_reader :user_id, :conversation_id

    def self.for(conversation)
      new(user_id: conversation.user_id, conversation_id: conversation.id)
    end

    def initialize(user_id:, conversation_id:, root: Workspace::PERSISTENT_ROOT)
      @user_id = validate_id!(:user_id, user_id)
      @conversation_id = validate_id!(:conversation_id, conversation_id)
      @root = Pathname.new(root).expand_path
    end

    def scope_dir
      verify!(@root.join("u#{@user_id}", "c#{@conversation_id}"))
    end

    def workspace_dir
      verify!(scope_dir.join("workspace"))
    end

    def workspace_bytes
      self.class.bytes_under(workspace_dir)
    end

    # Warm eviction: delete only workspace/, preserving sessions/. Returns
    # bytes reclaimed; 0 when already absent (idempotent).
    def evict_workspace!
      remove(workspace_dir)
    end

    # Full cleanup after permanent conversation destruction — sessions too.
    def destroy_scope!
      remove(scope_dir)
    end

    # Free space of the filesystem holding `root`, or nil when it cannot
    # be determined safely (missing root, command failure, unparseable or
    # zero-total output). nil must never be read as "disk full" — callers
    # skip emergency eviction on it.
    def self.free_space(root: Workspace::PERSISTENT_ROOT)
      root = Pathname.new(root).expand_path
      return free_space_failure("missing_root") unless root.directory?

      out, err, status = Timeout.timeout(5) { Open3.capture3("df", "-Pk", root.to_s) }
      return free_space_failure("command_failed", detail: err) unless status.success?

      fields = out.lines[1].to_s.split
      total, available = fields.values_at(-5, -3)
      unless [ total, available ].all? { |value| value.to_s.match?(/\A\d+\z/) }
        return free_space_failure("unparseable_output")
      end
      return free_space_failure("zero_total") unless total.to_i.positive?

      FreeSpace.new(total.to_i, available.to_i)
    rescue StandardError => e
      free_space_failure("exception", error: e)
    end

    def self.free_space_failure(reason, detail: nil, error: nil)
      message = "event=persistent_free_space_failed reason=#{reason}"
      message += " detail=#{detail.to_s.strip.inspect}" if detail.present?
      message += " error_class=#{error.class} error=#{error.message.inspect}" if error
      Rails.logger.warn(message)
      nil
    end

    # Recursive size without following symlinks — a link counts as itself,
    # never its target.
    def self.bytes_under(path)
      stat = File.lstat(path.to_s)
      return stat.size unless stat.directory?

      Dir.children(path.to_s).sum { |child| bytes_under(File.join(path.to_s, child)) }
    rescue Errno::ENOENT
      0
    end

    # Enumerate u*/c* scope directories under `root` (symlinks skipped) as
    # { user_id:, conversation_id:, path: } — for the eviction job's disk
    # view and metis:workspaces:report.
    def self.scan_scopes(root: Workspace::PERSISTENT_ROOT)
      root = Pathname.new(root).expand_path
      return [] unless root.directory?

      root.children.flat_map do |user_dir|
        next [] unless real_directory?(user_dir) && user_dir.basename.to_s =~ /\Au(\d+)\z/

        user_id = $1.to_i
        user_dir.children.filter_map do |scope|
          next unless real_directory?(scope) && scope.basename.to_s =~ /\Ac(\d+)\z/

          { user_id: user_id, conversation_id: $1.to_i, path: scope }
        end
      end
    end

    def self.real_directory?(path)
      File.lstat(path.to_s).directory?
    rescue Errno::ENOENT
      false
    end

    private

    def validate_id!(name, value)
      raise ArgumentError, "#{name} must be a positive integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?

      value
    end

    def verify!(path)
      relative = path.relative_path_from(@root).to_s
      raise UnsafePath, "#{path} escapes #{@root}" unless SCOPE_SHAPE.match?(relative)

      path
    end

    # Deletes `path` and returns the bytes it held. A symlink at the path
    # is unlinked, never followed; a parent-component symlink that escapes
    # the root refuses (canonicalization mismatch).
    def remove(path)
      lstat = File.lstat(path.to_s)
      if lstat.symlink?
        File.unlink(path.to_s)
        return 0
      end

      real = File.realpath(path.to_s)
      real_root = File.realpath(@root.to_s)
      raise UnsafePath, "#{path} resolves outside #{@root}" unless real.start_with?("#{real_root}/")

      bytes = self.class.bytes_under(path)
      FileUtils.rm_r(path)
      raise Errno::EIO, "failed to remove #{path}" if path.exist? || path.symlink?

      bytes
    rescue Errno::ENOENT
      raise if path.exist? || path.symlink?

      0
    end
  end
end
