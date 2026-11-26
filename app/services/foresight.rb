# The per-user "Foresight" routine: one per user per team, created with their
# first direction. Each fire is an ordinary unattended turn that explores the
# user's directions, goals and commitments and records up to
# Hunch::MAX_PER_RUN hunches. Routine#fire_scheduled! skips it when there's
# nothing to follow. See docs/hunches.md.
module Foresight
  extend PurposeRoutine

  PURPOSE = "foresight".freeze
  CRON = "0 6 * * *".freeze
  NAME = "Foresight".freeze
  WRITE_OPS = %w[update_direction record_hunch].freeze

  PROMPT = <<~MD.freeze
    Foresight run. Work out what I'm likely to need soon and have it ready.

    1. Call metis_list_directions. Read my goal and commitment memories in your context too.
    2. For each active direction: research what's new since it was last explored, then
       call metis_update_direction with your current view and open questions. Look for
       evidence against your current view as well as for it.
    3. Pick at most #{Hunch::MAX_PER_RUN} things I'll probably need in the next few days that you can
       do now: a draft, a summary, a review, a plan. Do the work, then record each with
       metis_record_hunch: what it is, the finished work, why now, and the sources.
       Only record a hunch you'd rate at least medium impact and can back with evidence.
    4. Don't send, post or change anything outside Metis.

    Reply with a few bullets: what you explored and which hunches you recorded. If nothing
    was worth preparing, say why and record none.
  MD

  def self.activity?(routine)
    Direction.for(routine.user, routine.team).active.exists? ||
      UserMemory.for(routine.user, routine.team).where(kind: %i[goal commitment]).exists?
  end
end
