# Memory review routines store their prompt at creation. Move the ones still
# on the shipped prompt to the new one (memory history reasons, gate and hunch
# outcomes, skill proposals); a prompt the user edited is left alone.
class RefreshMemoryReviewPrompt < ActiveRecord::Migration[8.1]
  OLD = <<~MD
      Nightly memory review. Call metis_memory_report, then tidy what you know about me
      with metis_update_memory, metis_forget and metis_remember:

      - Merge duplicates and settle contradictions; keep the one I stated, else the newer.
      - Memories used in replies I didn't correct, cancel or fork: raise confidence a step.
      - Memories used in replies I corrected: rewrite them from the correction notes, or
        lower confidence; forget ones that keep failing.
      - A correction that shows up three or more times becomes a high-confidence preference.
      - Corrections on replies that used no memory point to something missing: record it.
      - Memories I edited or deleted myself are final: never undo an edit or re-learn a
        deleted kind of thing without new evidence.

      Then reply with a short note in a few bullets: what you changed and why. If the
      report shows nothing new, reply "Nothing new." and stop.
  MD

  NEW = <<~MD
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
      - If can_propose_skills is true and conversation_titles show the same kind of task
        coming back that no skill covers (metis_list_skills), propose one with
        metis_propose_skill. At most one per review.

      Then reply with a short note in a few bullets: what you changed and why. If the
      report shows nothing new, reply "Nothing new." and stop.
  MD

  def up = swap(OLD, NEW)
  def down = swap(NEW, OLD)

  private

  def swap(from, to)
    execute <<~SQL
      UPDATE routines SET prompt = #{connection.quote(to)}, updated_at = NOW()
      WHERE trigger_config->>'purpose' = 'memory_review' AND prompt = #{connection.quote(from)}
    SQL
  end
end
