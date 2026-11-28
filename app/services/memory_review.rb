# The nightly "Memory review" routine: one per user per team, created with
# their first memory. Each fire is an ordinary turn that reads
# metis_memory_report and tidies the memories; Routine#fire_scheduled! skips
# nights with nothing new. See docs/memory.md.
module MemoryReview
  extend PurposeRoutine

  PURPOSE = "memory_review".freeze
  CRON = "0 3 * * *".freeze
  NAME = "Memory review".freeze
  WRITE_OPS = %w[remember update_memory forget_memory propose_skill].freeze

  PROMPT = <<~MD.freeze
    Nightly memory review. Call metis_memory_report, then tidy what you know about me
    with metis_update_memory, metis_forget and metis_remember. Give every change a
    one-line reason; I read them in my memory history.

    - Merge duplicates and settle contradictions; keep the one I stated, else the newer.
    - Memories used in replies I didn't correct, cancel or fork: raise confidence a step.
    - Memories used in replies I corrected: rewrite them from the correction notes, or
      lower confidence; forget ones that keep failing.
    - Treat my "requested changes" gate decisions and hunches I dismissed with a reason
      as corrections too. Expired hunches are not feedback.
    - A correction that shows up three or more times in correction_history becomes a
      high-confidence preference; cite the corrections in its reason.
    - Corrections on replies that used no memory point to something missing: record it.
    - Memories I edited or deleted myself are final: never undo an edit or re-learn a
      deleted kind of thing without new evidence.
    - If conversation_titles show the same kind of task coming back and no skill covers
      it (metis_list_skills), propose one with metis_propose_skill. At most one per review.

    Then reply with a short note in a few bullets: what you changed and why. If the
    report shows nothing new, reply "Nothing new." and stop.
  MD

  # Where the current review's report starts: the review before it.
  def self.window_start(user, team, before: Time.current)
    routine_for(user, team)&.conversations&.where(created_at: ...before)&.maximum(:created_at)
  end

  # Counted from when the last review's reply was written, so the review's
  # own memory edits aren't activity.
  def self.activity?(routine)
    since = Message.where(conversation: routine.conversations).maximum(:updated_at) || routine.created_at
    Agent::MemoryReport.new(routine.user, routine.team, since: since).activity?
  end
end
