# Workflows (dev plan)

> Status: **design + build plan**, not yet implemented. UI mockups live
> at `docs/mockups/workflows.html` (git-ignored, local-only).

A **workflow** is a saved, multi-step recipe the agent runs on its own,
pausing at **gates** where a human decides before it crosses to the next
step. It is the depth + time axis of Metis v2: turn-based chat becomes a
gated, optionally event-triggered run, with the human as gatekeeper
rather than operator.

Naming is **"workflow" everywhere** — UI label and code names match, no
translation tax.

## The one idea that makes this cheap

A **gate is a turn boundary that requires approval to cross.** Metis
already pauses between turns (E2B `pause`, Daytona `stop`, Docker's
durable host dir) and resumes on the next `ChatJob` via the
conversation's `backend_session_id`. So:

- **run = a Conversation** — the durable substrate (transcript, sandbox
  scope, usage, `replayable_history`, sharing, forking).
- **step (task) = a turn** — one `ChatJob` with the step's prompt as input.
- **gate = a turn boundary the engine won't auto-cross** until a human acts.

The engine is therefore a thin state machine that decides *whether, and
with what prompt, to enqueue the next `ChatJob`*. It never decides what
the agent does inside a turn. That keeps the VISION.md guardrails intact:
**pi executes; Rails governs**, and there is **no second agent backend**.

## Guardrails (hold these on review)

- The engine sequences turns + gates. It must never branch on the
  *content* of agent output. A `Task` prompt is instructions to pi, not
  Ruby control flow.
- **v1 is linear + gates only.** No conditional routing. When branching
  is added later, it routes on a small *declared* outcome label the agent
  emits (e.g. a skill writes `outcome: pass|fail`) — Rails reads the
  label, never inspects diffs or logs itself.
- No new datastore for "project memory" in this work. Out of scope.
- A finished run is just a normal conversation again (see lifecycle).

## Data model

Three new tables, all team-scoped, integer enums per house style. The FK
that ties a run to its conversation lives on `workflow_runs`, so the hot
`conversations` table is **untouched** — every existing chat keeps working.

```ruby
# app/models/workflow.rb — the template (authored in UI; repo-import later)
class Workflow < ApplicationRecord
  belongs_to :team
  has_many :workflow_runs, dependent: :nullify

  enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual

  scope :enabled, -> { where(enabled: true) }

  # steps: jsonb array — [{ "key", "name", "prompt", "gate" }, ...]
  # trigger_config: jsonb — { "secret", "source" } | { "cron" }
end

# app/models/workflow_run.rb — one execution; owns one Conversation
class WorkflowRun < ApplicationRecord
  belongs_to :team
  belongs_to :workflow, optional: true            # nil = ad-hoc run
  belongs_to :conversation
  has_many :tasks, -> { order(:position) }, dependent: :destroy

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, failed: 4, cancelled: 5 }, default: :pending

  scope :active,   -> { where(status: %i[pending running awaiting_approval]) }
  scope :awaiting, -> { where(status: :awaiting_approval) }
end

# app/models/task.rb — a step instance
class Task < ApplicationRecord
  belongs_to :workflow_run
  belongs_to :assistant_message, class_name: "Message", optional: true  # audit link
  belongs_to :approved_by, class_name: "User", optional: true

  enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                  completed: 3, rejected: 4, failed: 5, skipped: 6 }, default: :pending
  # auto runs as a turn; approval pauses for a human. ("none" would clash
  # with ActiveRecord's Model.none.)
  enum :gate, { auto: 0, approval: 1 }, default: :auto

  scope :next_pending, -> { pending.order(:position) }
end
```

```ruby
# app/models/conversation.rb — one line added
has_one :workflow_run, dependent: :destroy
# invariant: workflow_run.present? ⇒ render the rail; while the run is
# active, turns are engine-driven, not human-typed.
```

`Task#assistant_message` is the audit trail for free: tokens, cost,
model, and the rendered transcript already live on `Message` (see
`ChatJob#run`). A completed run's timeline is just its tasks + their
messages.

Step prompts are persisted as ordinary `role: :user` messages (so
`replayable_history` and the transcript stay coherent); the run view
renders them with a "Step N" treatment instead of a user bubble.

## The engine

One job plus a one-line hook. Extract the turn-start core so the
controller and the engine share it.

```ruby
# 1. Extract from Composing#start_turn → a service both callers use.
#    app/services/conversation_turn.rb
module ConversationTurn
  def self.start(conversation, content:, attachments: [])
    # ... the existing transaction + ChatJob.perform_later ...
    [ user_message, assistant_message ]
  end
end
# Composing#start_turn delegates to it (no behavior change).
```

```ruby
# 2. The hook — end of ChatJob#run, after refresh_composer (chat_job.rb:80)
WorkflowRun.signal_turn_finished(conversation)   # no-op unless an active run
```

```ruby
# 3. app/jobs/workflow_advance_job.rb — the whole state machine.
#    A step RUNS its prompt as a turn; `approval` means "pause AFTER that
#    turn for review" (not "pause instead of running"). So settle() — not
#    advance() — is where a gate happens, once the step's turn is done.
class WorkflowAdvanceJob < ApplicationJob
  def perform(workflow_run_id)
    run = WorkflowRun.find(workflow_run_id)
    return unless run.active?

    case settle(run)                # the running step's turn just settled
    when :wait        then return                       # still streaming
    when :gate, :failed then return broadcast(run)      # paused / dead
    end                                                  # :continue → advance
    advance(run); broadcast(run)
  end

  # done + approval → :gate (awaiting_approval); done + auto → :continue;
  # errored/canceled → :failed; still streaming → :wait.
  def settle(run); end

  # next pending step: nil → completed; blank prompt → pure checkpoint
  # (approval) or skip (auto); else start its turn.
  def advance(run); end
end
```

```ruby
# 4. Gate decisions — WorkflowRunsController + WorkflowRun
#    approve:         task.completed!; run.running!; advance   → next turn
#                     resumes the SAME sandbox via backend_session_id
#    reject:          task.rejected!; run.cancelled!
#    request_changes: re-run the SAME step with the human's feedback as the
#                     turn prompt, in the same session, then gate again
```

```ruby
# 5. Start a run — WorkflowRun.start(workflow:, team:, user:, project:, input:)
#    creates an untitled Conversation (auto-titled from the first turn) +
#    run + tasks, folds `input` into step 1, then enqueues the advance job.
#    Callers: the new-chat composer launcher and (Phase 4) triggers.
```

Why this is safe without new infra:

- **Concurrency**: `ConversationTurn.start` hits the existing
  `index_messages_on_one_in_progress_turn` unique index; the engine only
  starts the next turn after the prior assistant message is terminal, so
  no collision.
- **Gate cost**: zero compute while paused — the sandbox was already
  paused after the turn. Resume is the normal `--continue` path.
- **Long gates**: if `EvictPausedSandboxesJob` reaps an idle E2B sandbox
  mid-gate, the next turn rehydrates context from
  `replayable_history → AGENTS.md`. Already handled.
- **Stalled turns**: `ReapStalledTurnsJob` only touches in-progress
  turns; during a gate there is none, so it leaves the run alone.

## Lifecycle of the conversation

1. **Born** — created untitled with the run, in the chosen project; the
   LLM auto-titler names it from the first turn.
2. **Workflow-driven** — while `active?`, turns are engine-driven; the
   composer is replaced by the run-status note / gate card.
3. **Free** — on `completed`/`cancelled`/`failed`, the run-status slot shows
   a one-line summary (steps + cost) and the composer returns on reload.
   It's an ordinary conversation now: keep chatting, fork, share.

## Projects (context vs. process)

A `Project` in Metis is a team-scoped **context object** — `name` + `about`
free-text that `Agent::Identity` injects into `AGENTS.md` every turn. It
carries *standing context and standards* (conventions, sources, the repo
it maps to), not a sandbox binding.

Workflows and projects are orthogonal, and that orthogonality is the
point — N workflows × M projects, not N×M bespoke things:

- **Workflow = the process** — which steps, which gates, definition of
  done. Reusable across projects.
- **Project = the context/standards** — by what rules, against what
  resources. Reusable across workflows.
- **Run = process × context** — a Conversation in a project.

Where the link lives:

- **Run level — yes, and nearly free.** A run owns one Conversation, and
  `Conversation belongs_to :project` already exists. `WorkflowRun.start`
  takes a `project:` and sets it on the conversation; `Agent::Identity`
  then feeds that project's `about` into `AGENTS.md` on every step turn —
  no new identity code. **No `project_id` on `workflow_runs`**:
  `run.conversation.project` is the single source of truth.
- **Workflow (template) level — optional default only.** A nullable
  `Workflow#default_project_id` pre-selects context at launch but is
  overridable. Keep templates project-agnostic so "Triage Sentry error"
  works across repos. (Phase 3.)
- **Task (step) level — no.** One run = one conversation = one
  `AGENTS.md` = one project context. Switching projects per step would
  fracture the substrate. If two steps need different contexts, that's two
  workflows.

So "R&D software dev" vs. "product analysis research" differ on *both*
axes: different **workflow** (steps/gates) run against a different
**project** (standards/sources). The template may suggest a default
project; the operator can override at launch.

## Build phases

Each phase is independently shippable and testable. **Phases 0–3 are
shipped** (the engine, run UI, authoring, and composer launch); Phase 4 is
deferred.

### Phase 0 — Data + invariant (no behavior) ✅
- Migrations: `workflows`, `workflow_runs` (unique index on
  `conversation_id`), `tasks` (index on `[workflow_run_id, position]`).
- Models + enums + scopes; `Conversation has_one :workflow_run`.
- **Test**: model specs for associations, enums, `active`/`next_pending`.
- Ships nothing user-visible; pure foundation.

### Phase 1 — Engine ✅
- `ConversationTurn` extraction (refactor `Composing#start_turn`); the
  `ChatJob` hook; `WorkflowAdvanceJob`; `WorkflowRun.start`.

### Phase 2 — Run UI ✅
- Run view (conversation `show` when `workflow_run` present): progress
  rail + inline **gate card** + a run-status composer slot.
- `WorkflowRunsController#approve/#reject`; `WorkflowBroadcaster` pushes
  rail/gate/composer to the conversation stream and the sidebar pill.

### Phase 3 — Authoring + launch ✅
- `/settings/workflows` CRUD: catalog + editor (drag-orderable steps, each
  an auto turn or approval gate, optional default project). Settings is
  authoring-only — launch lives in the composer.
- `Workflow#default_project_id`; the new-chat composer launcher
  (`workflow-launch`) → `WorkflowRunsController#create` → `WorkflowRun.start`,
  folding the typed subject into step 1; optional per-launch project override.
- Runs are created **untitled** so the LLM auto-titler names each from its
  subject. **"Needs you"** section on the catalog lists `WorkflowRun.awaiting`.
- **Run-UX refinements** (driven out by dogfooding): gate runs-then-pauses;
  the **request-changes loop** (re-run a step with feedback); engine-started
  turns broadcast their message rows to the live thread; injected step
  prompts render as a `STEP` boundary (`messages.workflow_generated`).

### Phase 4 — Triggers + notifications (deferred)
- `WebhooksController` (Sentry/GitHub → `WorkflowRun.start`, no auth,
  signature-verified). Scheduled triggers via Solid Queue recurring.
- Gate notifications: in-app + email (Slack later).

### Phase 5 — Later
- Promote-a-chat-to-a-workflow.
- Structured-outcome branching (declared labels only).
- Project memory — separate effort, not here.

## Open questions / known gaps

- **Team visibility of run conversations** (deferred). A run is a team
  operation — the "Needs you" inbox and the gate's "routed to your team"
  copy are team-wide — but `conversations#show` only authorizes the owner
  (or an explicitly-shared conversation), so a teammate can't yet open
  another member's run. Decide whether a workflow-run conversation should be
  team-readable, then relax `show` auth accordingly. (No issue in a personal
  team-of-one.)
- One trigger per workflow (inline `trigger_source`/`trigger_config`) vs. a
  `Trigger` model for many-per-workflow. Inline for now; extract if needed.
