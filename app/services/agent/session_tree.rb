require "json"

module Agent
  # Truncates a copied pi session transcript to a snapshot — the file half of
  # pi's `fork`. pi writes a conversation as a single JSONL file of tree
  # entries ({ id, parentId, type, message }) appended in order; Metis never
  # branches a conversation in place (no /tree, /fork), so the file is linear
  # and file order is the active path. Dropping every line from the Nth user
  # entry onward yields exactly what pi's fork would: the active path up to
  # that user message's parent, leaf at the preceding assistant turn.
  module SessionTree
    module_function

    # Rewrite the active session file in `session_dir`, keeping entries before
    # the `user_index`-th user message. A nil index or one past the last user
    # entry keeps everything (a clone). Returns true if it truncated.
    def truncate_before_user(session_dir:, user_index:)
      file = active_session_file(session_dir)
      return false unless file

      lines = File.readlines(file)
      parsed = lines.map { |line| JSON.parse(line) rescue nil }
      return false if parsed.any?(&:nil?) # unknown format — let the caller fall back

      user_lines = parsed.each_index.select { |i| parsed[i].dig("message", "role") == "user" }
      return false if user_index.nil? || user_index >= user_lines.size

      File.write(file, lines[0...user_lines[user_index]].join)
      true
    end

    # The session pi will --continue: the most recent transcript. Filenames are
    # ISO-timestamp-prefixed, so lexical max is newest.
    def active_session_file(session_dir)
      Dir.glob(File.join(session_dir.to_s, "*.jsonl")).max
    end
  end
end
