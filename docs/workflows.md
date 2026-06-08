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
# 3. app/jobs/workflow_advance_job.rb — the whole state machine
class WorkflowAdvanceJob < ApplicationJob
  def perform(workflow_run_id)
    run = WorkflowRun.find(workflow_run_id)
    return unless run.active?

    settle_running_task(run)        # link msg; complete or fail it
    return if run.failed?

    case (task = run.tasks.next_pending.first)
    in nil
      run.completed!; broadcast_done(run)
    in Task if task.approval?
      task.awaiting_approval!; run.awaiting_approval!
      notify_gate(run, task)        # broadcast gate card + notify; STOP
    else
      task.running!; run.running!
      user, asst = ConversationTurn.start(run.conversation, content: task.prompt)
      task.update!(assistant_message: asst)
      # ChatJob completion → signal_turn_finished → re-enters this job
    end
  end
end
```

```ruby
# 4. Approve / reject — WorkflowApprovalsController#update
#    approve: task.completed!; run.running!; WorkflowAdvanceJob.perform_later(run.id)
#             → next turn resumes the SAME sandbox via backend_session_id
#    reject : task.rejected!; run.cancelled!   (v1; request-changes loop = later phase)
```

```ruby
# 5. Start a run — WorkflowRun.start(workflow:, team:, input:, trigger:)
#    creates Conversation (settings from template/defaults) + run + tasks,
#    then WorkflowAdvanceJob.perform_later(run.id). One creator, three callers
#    (composer, catalog button, trigger).
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

1. **Born** — created with the run; provider/model seeded from template.
2. **Workflow-driven** — while `active?`, turns are engine-driven; the
   composer is replaced by the gate card / running state.
3. **Free** — on `completed`/`cancelled`, the rail collapses to a summary
   and the composer returns. It's an ordinary conversation now: keep
   chatting, fork, share. No special-casing.

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

Each phase is independently shippable and testable.

### Phase 0 — Data + invariant (no behavior)
- Migrations: `workflows`, `workflow_runs` (unique index on
  `conversation_id`), `tasks` (index on `[workflow_run_id, position]`).
- Models + enums + scopes; `Conversation has_one :workflow_run`.
- **Test**: model specs for associations, enums, `active`/`next_pending`.
- Ships nothing user-visible; pure foundation.

### Phase 1 — Engine
- `ConversationTurn` extraction (refactor `Composing#start_turn`); the
  `ChatJob` hook; `WorkflowAdvanceJob`; `WorkflowRun.start`.
- **Test**: a 2-step auto workflow runs end to end; a gated workflow
  pauses at the gate; approve resumes and finishes; reject cancels; an
  errored turn fails the run. Exercise via job tests + `rails console`.
- No bespoke UI yet — verified by tests.

### Phase 2 — Run UI
- Run view (conversation `show` when `workflow_run` present): progress
  rail, step stamps, inline **gate card**.
- `WorkflowApprovalsController` (approve / reject).
- Sidebar status pills (`Needs you` / `Running` / done / failed) +
  `ChatBroadcaster` extensions to push rail + gate changes live.
- **Test**: controller tests for approve/reject auth (team membership);
  system test of the gate round-trip.

### Phase 3 — Authoring + launch
- `/settings/workflows` CRUD: catalog (index) + editor (steps + gate
  toggles + trigger choice + optional default project). Mirrors the Skills
  settings pattern.
- `Workflow#default_project_id` (nullable) + project picker in the editor
  and launch composer; `WorkflowRun.start(project:)` sets it on the
  conversation (the only schema add of this phase).
- Composer launcher → `WorkflowRunsController#create` → `WorkflowRun.start`.
- **"Needs you"** inbox (team-wide `WorkflowRun.awaiting`).
- **Test**: workflow CRUD; starting a run from the composer; project context
  reaches `AGENTS.md`.

### Phase 4 — Triggers + notifications
- `WebhooksController` (Sentry/GitHub → `WorkflowRun.start`, no auth,
  signature-verified). Scheduled triggers via Solid Queue recurring.
- Gate notifications: in-app + email (Slack later).
- **Test**: webhook signature + run creation; scheduled enqueue.

### Phase 5 — Deferred
- Request-changes loop (re-run a step with human feedback as input).
- Promote-a-chat-to-a-workflow.
- Structured-outcome branching (declared labels only).
- Project memory — separate effort, not here.

## Open questions

- One trigger per workflow (inline `trigger_source`/`trigger_config`) vs.
  a `Trigger` model for many-per-workflow. Plan assumes inline for v1;
  extract if multi-trigger demand appears.
- Should step-prompt user messages be visually hidden in the run view, or
  shown as "Step N" cards? Leaning "Step N" cards (Phase 2 view work).
- Reject semantics in v1: cancel the run (current plan) vs. always offer
  request-changes. Cancel now; request-changes in Phase 5.
