module Agent
  # What happened to one user's memories in one team since a point in time:
  # which replies used them and how the user reacted (correct, cancel, fork,
  # or nothing, which counts as accepted). Read by the nightly review through
  # metis_memory_report, by its idle check, and by the memory page.
  class MemoryReport
    DEFAULT_WINDOW = 7.days

    def initialize(user, team, since: nil)
      @user = user
      @team = team
      @since = since || DEFAULT_WINDOW.ago
    end

    def activity?
      memories.where(updated_at: @since..).exists? || replies.applying_memories.exists? ||
        corrections.exists? || deletions.any?
    end

    def corrections_count = corrections.count

    def to_h
      {
        since: @since.iso8601,
        memories: memories.ordered.map { |memory| memory_entry(memory) },
        corrections_without_memory: corrections.where(applied_memory_ids: []).map { |reply| { at: reply.corrected_at.iso8601, note: reply.correction_note } },
        deleted_by_you: deletions,
        totals: { replies: replies.count, corrections: corrections_count, corrections_previous_window: previous_corrections }
      }
    end

    private

    def memories = UserMemory.for(@user, @team)

    def replies = Message.replies_of(@user, @team).where(created_at: @since..)

    def corrections = Message.replies_of(@user, @team).where(corrected_at: @since..)

    def previous_corrections
      Message.replies_of(@user, @team).where(corrected_at: (@since - (Time.current - @since))...@since).count
    end

    def deletions
      @deletions ||= Membership.find_by(user: @user, team: @team)&.memory_deletions_since(@since) || {}
    end

    def memory_entry(memory)
      {
        id: memory.id, kind: memory.kind, source: memory.source, confidence: memory.confidence,
        content: memory.content, new: memory.created_at >= @since,
        edited_by_you: memory.edited_by_user_at.present? && memory.edited_by_user_at >= @since,
        outcomes: outcomes.fetch(memory.id, {})
      }
    end

    # memory id => { "applied" => n, "corrected" => n, "cancelled" => n, "forked" => n }
    def outcomes
      @outcomes ||= begin
        applied = replies.applying_memories.pluck(:id, :applied_memory_ids, :corrected_at, :streaming_status)
        forked = Conversation.where(forked_from_message_id: applied.map(&:first)).distinct.pluck(:forked_from_message_id).to_set
        applied.each_with_object({}) do |(reply_id, memory_ids, corrected_at, status), counts|
          memory_ids.each do |memory_id|
            tally = counts[memory_id] ||= Hash.new(0)
            tally["applied"] += 1
            tally["corrected"] += 1 if corrected_at
            tally["cancelled"] += 1 if status == "canceled"
            tally["forked"] += 1 if forked.include?(reply_id)
          end
        end
      end
    end
  end
end
