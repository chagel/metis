# Routines

A **routine** is a saved prompt that fires on its own — on a cron
**schedule** or when a **webhook event** arrives — each fire running as a
normal agent turn. It's the autonomy axis of Metis: where a workflow is a
multi-step recipe a human gates, a routine is a single prompt the clock or
an event triggers, with no human in the loop.

Naming is **"routine" everywhere** — UI label and code names match.

## The one idea that makes this cheap

A routine doesn't need its own execution engine. Metis already turns a
prompt into a run: `ConversationTurn.start` creates a conversation and a
turn, and the agent does the rest — including reaching connectors, skills,
or starting a workflow (`metis_start_workflow`) if the prompt says so. So a
routine is just **(schedule | event) → `ConversationTurn.start`**:

- **routine = a `Routine` row** — the saved prompt + its trigger.
- **a fire = a `Conversation`** — `routine.fire!` starts one turn; the
  conversation is tagged with `routine_id` for provenance.
- **the prompt is generic** — it is *not* bound to a workflow. It can
  answer, call a tool, open a PR, or launch a workflow; the routine only
  decides *when*.

Because firing is an ordinary turn, everything that already works in a
chat — runtimes, credential pass-through, connectors, skills, observability
— works in a routine for free.

## Model

`Routine` (`app/models/routine.rb`), team-owned like every resource
(`docs/tenancy.md`):

| Field | Meaning |
|---|---|
| `trigger_source` | enum `{ schedule, webhook }` — how it fires |
| `prompt` | the instruction, run each fire; supports `{{variables}}` |
| `cron` + `timezone` | 5-field cron and IANA zone (schedule kind) |
| `event_type` | webhook event to match, exact or `family.*` (webhook kind) |
| `visibility` | enum `{ personal, team }` — who can open the fired runs |
| `enabled` | off pauses it; agent-created routines start disabled |
| `next_run_at` / `last_run_at` | scheduler cursor + cooldown anchor |
| `trigger_config` | jsonb: `cooldown_seconds`, `conditions`, `variables`, run `settings` |
| `project` | optional — gives runs a project's repo/standards as context |

Cron is parsed with **fugit**, the IANA zone embedded as cron's trailing
field so fields evaluate in that zone. `next_run_at` is recomputed on save
and advanced past now after each scheduled fire.

`PromptRenderer` (`app/services/routine/prompt_renderer.rb`) interpolates
`{{date}}`, `{{time}}`, `{{team}}`, `{{user}}`, and — on the webhook path —
`{{event_type}}` / `{{event_payload}}`. Built-ins and event vars take
precedence over the routine's own `trigger_config["variables"]`, so a custom
variable can't shadow `{{date}}`. Unknown placeholders are left untouched.

A routine can pin the **LLM** its fires run on — model/provider live in
`trigger_config["settings"]` and are fed into the fired conversation's
`settings` by `Routine#run_settings`. Both the form and the chat tools resolve
the choice against the deployment catalog via `Agent::ModelSelection` (shared
with `WorkflowHandoff`); unset inherits the deployment default.

## The three firing paths

1. **Schedule.** `RoutineSchedulerJob` runs every minute
   (`config/recurring.yml`) → `Routine.due.find_each(&:fire_scheduled!)`.
   `fire_scheduled!` row-locks so two overlapping ticks can't double-fire,
   then advances `next_run_at`. Best-effort per row.
2. **Event.** `WebhookEvent#after_create_commit` enqueues
   `RoutineDispatchJob` → `Routine::EventDispatcher`. It matches the team's
   enabled webhook routines by `event_type` (exact or `family.*` wildcard),
   skips any inside its `cooldown_seconds`, checks optional
   `trigger_config["conditions"]` (dotted-path equality on the payload),
   then fires. **This is the trigger half of the collect-then-trigger split
   the webhook collector set up** (`docs/workflows.md` Phase 4) — the
   collector still triggers nothing on its own.
3. **Manual.** `POST /settings/routines/:id/run` → `routine.fire!`.

## Surface

- **Web** — `RoutinesController` under `/settings/routines`: CRUD plus
  `toggle` (pause/resume) and `run` (fire now). A `routine-form` Stimulus
  controller drives a schedule builder — frequency + hour/minute, a weekday
  picker for weekly, day-of-month for monthly, a live human-readable preview,
  and IANA time zones — composing the hidden cron field and reverse-parsing a
  stored cron on edit, with a raw-cron **Custom** mode as the escape hatch. For
  a webhook routine the event type is a `<select>` **grouped by connector**,
  populated from the event types the team has actually received
  (`RoutinesHelper#routine_event_type_options`) — no free-typing an event that
  would never match. A model picker selects the LLM each fire runs on.
- **Chat** — the agent manages routines over pi's Extension UI channel
  (`Agent::HostBridge` → `Agent::RoutineManager`), the same pattern as
  in-chat workflow and skill management. Tools, defined in
  `.pi/extensions/metis-workflow/index.ts`: `metis_list_routines`,
  `metis_create_routine`, `metis_update_routine` (both writes cover every
  property, model/provider included). No delete tool — removing a routine
  stays an operator action in the UI. Writes are team-admin-gated and refused
  inside a workflow run; a routine the agent creates **starts disabled** until
  the operator enables it.
- **Provenance** — a fired conversation is tagged with `Conversation#routine`,
  surfaced as a clock badge on its sidebar row and a "Routine · <name>" chip on
  its show header, so it's distinguishable from a hand-started chat.

## Boundaries

- The engine never reads agent output — a routine fires a turn and is done;
  whatever the agent does is the agent's business.
- A routine is not a workflow. If a recurring job needs multiple gated
  steps, the routine's prompt starts a workflow; the routine stays the
  trigger, the workflow stays the recipe.
- No per-channel delivery (Telegram/Teams/inbox fan-out, as in the Themis
  sibling). The fired conversation *is* the output surface — visible per
  its `visibility`.
