# User memory

Metis learns about each user as they chat and applies what it learned in
every later conversation. This is phase P0 of the "Metis, one step ahead"
plan: the memory every later phase (decision log, foresight, the decision
ladder) builds on.

## Model

`UserMemory` belongs to a `Team` and a `User`: one user's memories within
one team, so context learned in a work team never reaches a personal team.

| Column | Meaning |
| --- | --- |
| `content` | One short fact, encrypted, at most 500 characters |
| `kind` | `preference`, `correction`, `fact`, `goal`, `commitment`, `experience` |
| `source` | `stated` (the user said it) or `inferred` (Metis concluded it) |
| `confidence` | `low`, `medium`, `high`; stated memories are `high` |
| `source_conversation` | Where it was learned; nullified if that chat is deleted |
| `last_applied_at` | Last time a turn reported the memory shaped its reply |

A soft limit of 100 per user per team keeps the prompt bounded: past it a
save is refused and the agent is told to update or forget one (concurrent
saves can briefly overshoot). Leaving a team deletes your memories there
(`Membership` `after_destroy`).

## Record

The agent decides what to record. Four tools in
`.pi/extensions/metis-workflow`, through `Agent::HostBridge` to
`Agent::MemoryManager`:

- `metis_remember` — a new memory (defaults to `inferred`/`low`)
- `metis_update_memory` — revise content, kind or confidence by id. New
  wording is a new claim: it becomes `inferred` from this conversation
  unless the agent marks it `stated`; a confidence-only change keeps the
  provenance
- `metis_forget` — delete by id
- `metis_note_applied` — report which memories shaped this reply

Every op is scoped to the conversation's own user and team, so a turn can
only touch that user's memories; there is no admin gate. Tool results
report the id and labels, not the text.

## Where memory applies

Every conversation of the user's, except workflow runs (team processes) and
conversations in a team the user has since left (`UserMemory.available_in?`).
Team-visible and shared chats included: who sees a conversation is the
user's call, and sharing one shares what the agent knew in it.

## Apply

`Agent::Identity` renders "What you've learned about the operator" after
the operator's own `about_you` / `custom_instructions`: every memory as
`[id · kind · source/confidence] content`, the rules for applying them
(by default; low confidence is a hunch; the current request wins and the
memory gets updated), and what to record or never record. When a memory
shapes a reply, the agent says so in a few words and calls
`metis_note_applied`.

## Control

`/settings/memory` (`Settings::MemoriesController`) lists the current
team's memories by kind with their provenance. The user can edit, confirm
(an inference becomes `stated`/`high`), delete, or clear all. Deleting a
memory removes it from the list every later turn is given. It doesn't
erase chat history: a resumed pi session still holds the turn where the
memory was said or written.

## Learning (P1)

Memories improve from what the user does with the replies they shaped.

**Signals.** `metis_note_applied` also stores the ids on the turn's reply
(`Message#applied_memory_ids`). When the next message corrects, redoes or
rejects a reply, the agent calls `metis_note_correction`, which sets
`Message#corrected_at` and an encrypted `correction_note` on the previous
finished reply. Cancels (`streaming_status: canceled`) and forks
(`Conversation#forked_from_message_id`) need no call. A reply with none of
these counts as accepted. On `/settings/memory`, an edit marks the memory
`stated`/`high` with `edited_by_user_at`; a delete keeps only
`{ kind, at }` in `Membership#memory_deletions` (30 days, no text).

**Report.** `Agent::MemoryReport` (tool `metis_memory_report`) summarises
a window: per memory, replies applied / corrected / cancelled / forked;
corrections on replies that used no memory; the user's own edits and
deletions; corrections this window against the one before. It also carries
the user's workflow gate decisions (their `review` messages, so a "requested
changes" note reads as a correction), hunches used or dismissed (with the
dismiss reason; expiries only as a count, never as feedback), every
correction note from the last 30 days (`correction_history`, so a
correction repeated across nights is visible), the window's chat titles,
and whether the user may propose skills (`can_propose_skills`, team admins).
Three new chats in the window count as activity on their own, so a task that
keeps coming back wakes the review.

**Nightly review.** The first memory a user saves in a team creates a
"Memory review" routine for them (`MemoryReview`, personal, daily at 03:00
in their zone, on their own default model, marked
`trigger_config["purpose"] = "memory_review"`). Each fire is an ordinary
turn: it reads the report from the previous review on, tidies memories
with the existing tools, and replies with a short "what I learned" note.
`Routine#fire_scheduled!` skips a night with no activity since the last
review's reply (so the review's own edits don't count) without running a
turn. The memory page shows the last review, corrections this week against
last week, and a link to the routine's settings.

A review is an ordinary personal routine: only its user sees, edits or runs
it, under "My routines". Pause it to turn reviews off; deleting it only lasts
until the next new memory recreates it. Its prompt is stored on the routine
when it's created; a migration moves reviews still on the shipped prompt to a
new one (a user-edited prompt is left alone).

**History.** Every change to a memory writes a `MemoryChange` from
`UserMemory`'s own callbacks: action (created / updated / forgotten), actor
(`review`, `chat`, the `user` on `/settings/memory`, or `system` when a
write names no one; see `UserMemory#changed_by`), the conversation, encrypted before/after snapshots
and the agent's one-line `reason` (the memory tools take an optional
`reason`). Rows outlive a forgotten memory and are pruned after 90 days
(`MemoryChange.prune!`, daily). On the memory page each memory lists its own
revisions (the history icon), forgotten ones sit under "Recently forgotten",
and the status line links a waiting skill proposal. There's no
undo yet; the snapshots are what one would restore.

**Skill proposals.** When the conversation titles show a task coming back,
the review may call `metis_propose_skill` (HostBridge `propose_skill`, allowed
unattended only in the review). The host allows one proposal per review
conversation, and only for a team admin. It creates a team skill
through `Agent::SkillManager.propose`: disabled, with `proposed_by` set, so
only that user sees it (`Skill.visible_to`). Enabling it clears
`proposed_by` and publishes it to the team; deleting it discards it.
Agent-written skill files and GitHub imports can't overwrite someone else's
proposal (`Skill.upsert_from_files`).

## Not yet

Undo for memory changes, and a general decision log with levels (P4, the
decision ladder).
