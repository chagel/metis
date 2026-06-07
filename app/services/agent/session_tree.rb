require "json"

module Agent
  # A pi session is one JSONL file of {id, parentId, message} entries; Metis
  # never branches in place, so file order is the active path and dropping from
  # the Nth user line down is exactly what pi's own `fork` yields.
  module SessionTree
    module_function

    def truncate_before_user(session_dir:, user_index:)
      file = active_session_file(session_dir)
      return false unless file

      lines = File.readlines(file)
      parsed = lines.map { |line| JSON.parse(line) rescue nil }
      return false if parsed.any?(&:nil?) # unknown format — caller falls back

      user_lines = parsed.each_index.select { |i| parsed[i].dig("message", "role") == "user" }
      return false if user_index.nil? || user_index >= user_lines.size

      File.write(file, lines[0...user_lines[user_index]].join)
      true
    end

    # Filenames are ISO-timestamp-prefixed, so lexical max is the newest.
    def active_session_file(session_dir)
      Dir.glob(File.join(session_dir.to_s, "*.jsonl")).max
    end
  end
end
