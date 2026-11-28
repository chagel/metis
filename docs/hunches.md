# Hunches

A **hunch** is a guess at what a user will need soon, with the work already
done: a draft, a research summary, a review, a plan. Metis forms hunches on
its own each morning from the user's **directions**, goal memories and
commitment memories, and puts them on the **Hunches** page (`/hunches`),
where the user continues each in chat, marks it useful, or dismisses it. Those outcomes are the
measure of whether Metis is one step ahead. This is P3 slice 1 (issue #246).

## Directions

A `Direction` (team + user, personal only) is something the user asked Metis
to follow: "keep me current on proactive agents", "watch our payments
service". It holds a `title` and `brief` (what to follow and why), plus the
state Metis keeps: `view` (current understanding, rewritten each run),
`open_questions`, `last_explored_at`, and `status` (`active` | `paused`).
Up to `Direction::MAX_PER_USER` (10) per user per team.

Managed on the Hunches tab (add from the sidebar's +; pause or delete in a
selected direction's header, `DirectionsController`), or from chat: the
agent's `metis_add_direction` adds one when the user asks to follow something.

## Foresight

`Foresight` (`app/services/foresight.rb`) owns a per-user "Foresight"
routine, the same pattern as `MemoryReview`: an ordinary personal routine
marked `trigger_config["purpose"] = "foresight"`, created with the user's
first direction, firing daily at 06:00 in the user's zone. Its prompt has
the agent:

1. read the directions (`metis_list_directions`) and the goal and
   commitment memories already in its context;
2. research each active direction and record its view and open questions
   (`metis_update_direction`), looking for evidence against the current view
   too;
3. do the work for at most `Hunch::MAX_PER_RUN` (3) things the user will
   probably need, recording each with `metis_record_hunch`. Every hunch names
   its origin: a `direction_id`, or a `memory_id` of a goal or commitment;
   the host refuses one with neither.

`Routine#fire_scheduled!` skips a night with no active directions and no
goal or commitment memories (`Foresight.activity?`). **Read my mind** on the
Hunches page fires it immediately.

Every foresight fire is an unattended run (`docs/unattended-runs.md`). It
starts with no grants, so it researches with web search and fetch only;
grant it connectors on its routine form if a direction needs them. Only a
foresight run may call `update_direction` and `record_hunch` unattended
(`Foresight::WRITE_OPS`); adding a direction is a chat action.
Runs count against `UnattendedBudget`.

## Hunch

`Hunch` (team + user): `title`, `body` (encrypted Markdown, the finished
work), `why_now`, `evidence` (`[{ title, url }]`, http(s) only), `impact`
and `confidence` (`low` | `medium` | `high`), optional `direction` and
`source_memory`, and the `conversation` of the run that made it.
`Agent::ForesightManager#record` refuses a hunch without evidence, below
medium impact, or past the per-run cap.

## The Hunches tab

`/hunches` has its own sidebar (`hunches/_nav`): **Ready** (hunches waiting
for you, with a count), **History** (past hunches and their outcomes), then
**Directions**, each with its ready count and when it was last explored (+
in the group header adds one inline). A hunch from a goal or commitment has
no direction; its card names the memory instead ("Goal: …").

`status` is the outcome: `ready`, then `used` (Useful, or the first message
of a chat continued from it), `dismissed` (with an optional reason), or `expired` (left `ready` for
`Hunch::TTL`, 14 days; `Hunch.expire_stale!` runs hourly from
`config/recurring.yml`).

## Measures

- Per direction, in its header on the Hunches tab: used, dismissed,
  and total hunches.
- Quality: used hunches whose chat then got a correction (`Message#corrected_at`,
  recorded by `metis_note_correction`) were close but not right; the rest
  were right as prepared. Not surfaced yet.
- On History (`Hunch.outcome_stats`): used / dismissed / expired counts, the
  share used, and cost per used hunch, which is every foresight run's
  `Message#cost` divided by hunches used. Fired runs carry their routine's
  purpose in `settings["purpose"]` (`Conversation.purpose_runs`), so runs from
  a deleted routine still count. A run with an unpriced reply leaves the cost
  out rather than counting it as zero.

## Known gaps

- Network egress is open (P2 PR B parked). A foresight run reads the open
  web and sees the user's memories, so a hijacked run could send memories to
  an outside host. Accepted for this slice.
- Not yet: event triggers, notifications, an exploration share,
  value-of-information scoring, team-shared directions.
