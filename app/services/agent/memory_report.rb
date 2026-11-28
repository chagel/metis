module Agent
  # What happened to one user's memories in one team since a point in time:
  # which replies used them and how the user reacted (correct, cancel, fork,
  # or nothing, which counts as accepted), plus the other outcomes Metis sees
  # (workflow gate decisions, hunches used or dismissed). Read by the nightly
  # review through metis_memory_report, by its idle check, and by the memory page.
  class MemoryReport
    DEFAULT_WINDOW = 7.days
    HISTORY = 30.days
    LIST_CAP = 50
    # New chats that alone make a night worth reviewing: enough to spot a
    # task coming back.
    RECURRING_CHATS = 3

    def initialize(user, team, since: nil)
      @user = user
      @team = team
      @since = since || DEFAULT_WINDOW.ago
    end

    def activity?
      memories.where(updated_at: @since..).exists? || replies.applying_memories.exists? ||
        corrections.exists? || deletions.any? || gate_decisions.exists? || hunch_outcomes.exists? ||
        new_chats.count >= RECURRING_CHATS
    end

    def corrections_count = corrections.count

    def previous_corrections_count
      all_replies.where(corrected_at: (@since - (Time.current - @since))...@since).count
    end

    def to_h
      {
        since: @since.iso8601,
        memories: memories.ordered.map { |memory| memory_entry(memory) },
        corrections_without_memory: corrections.where(applied_memory_ids: []).map { correction_entry(it) },
        deleted_by_you: deletions,
        correction_history: correction_history,
        gate_decisions: gate_decisions.limit(LIST_CAP).map { |message| { at: message.created_at.iso8601, decision: message.content } },
        hunches: hunch_outcomes.limit(LIST_CAP).map { |hunch| hunch_entry(hunch) },
        hunches_expired: hunches_expired,
        conversation_titles: conversation_titles,
        can_propose_skills: @team.managed_by?(@user),
        totals: { replies: replies.count, corrections: corrections_count, corrections_previous_window: previous_corrections_count }
      }
    end

    private

    def memories = UserMemory.for(@user, @team)

    def all_replies = Message.replies_of(@user, @team)
    def replies = all_replies.where(created_at: @since..)
    def corrections = all_replies.where(corrected_at: @since..)

    # Older than the window too, so a correction repeated across nights shows.
    def correction_history
      all_replies.where(corrected_at: HISTORY.ago..).order(corrected_at: :desc).limit(LIST_CAP).map { correction_entry(it) }
    end

    def correction_entry(reply) = { at: reply.corrected_at.iso8601, note: reply.correction_note }

    def gate_decisions
      Message.review.joins(:conversation).where(conversations: { team_id: @team.id }, sender_id: @user.id, created_at: @since..)
             .order(:created_at)
    end

    def hunch_outcomes
      Hunch.for(@user, @team).where(status: %i[used dismissed], outcome_at: @since..).includes(:direction).order(:outcome_at)
    end

    def hunches_expired = Hunch.for(@user, @team).expired.where(outcome_at: @since..).count

    def hunch_entry(hunch)
      { title: hunch.title, outcome: hunch.status, direction: hunch.direction&.title, reason: hunch.dismiss_reason }.compact
    end

    def new_chats = Conversation.chats.where(user: @user, team: @team, created_at: @since..)

    def conversation_titles
      new_chats.where.not(title: [ nil, "" ]).order(:created_at).limit(LIST_CAP).pluck(:title)
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
