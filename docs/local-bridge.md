# Local bridge

> Status: **shipped** — token + presence, the delegation core, the hosted
> MCP facade, delegation reliability, and the `metis` daemon are all built;
> push notifications and live progress streaming are not. Companion to
> [`workflows.md`](workflows.md) — the bridge is how a workflow's
> *implementation step* runs on the user's own machine instead of a
> Metis-operated sandbox.

A **bridge** lets a remote Metis workflow **delegate a step** to a coding
agent running on the **user's own machine** — Claude Code, Codex, pi —
against their **real working copy**, with their real toolchain, env, and
(for Claude Code) their **own Claude subscription** rather than Metis's
API budget. Metis stays the governor: it sequences steps and gates, hands
off the work, and records the result. It does **not** drive the agent.

## The shape: delegation, not a runtime

The tempting design is a fourth `Runtime` (`Local`/`Docker`/`E2b`/`Daytona`
→ `Bridge`) that streams the local agent's turn back as an assistant
`Message`. **We reject it.** Forcing local work through the runtime /
adapter seam means every local turn has to masquerade as a streamed
`Message` bound to a `ChatJob`: a blocked Solid Queue worker held open for
the whole turn, a persistent cloud→laptop stream across NAT, a
per-conversation runtime flip, and the full `UiEvent` streaming contract
(`token_totals` shapes, `#artifacts`, cancel-polling) that local work
doesn't naturally produce. The cloud↔local boundary doesn't behave like
the cloud sandbox runtimes do, and pretending it does buys impedance, not
reuse.

Instead, **a local step is a [`Task`](workflows.md) handed off — and the
engine waits for a *report* the same way it already waits for a human
*approval*.** Metis already has both primitives:

- `Task` — a workflow step instance, with status + audit, *not* tied to a
  streamed turn.
- The **gate** — a turn boundary the engine won't cross until an external
  signal arrives.

A delegated step is simply a **sibling of the approval gate**:
`awaiting_local → report → advance` instead of `awaiting_approval → click
→ advance`. No new runtime, no adapter, no streaming contract.

```
WorkflowAdvanceJob reaches a delegated step
   → task.dispatched  ·  run.awaiting_local!  ·  notify     (engine STOPS — like a gate)
                                                            │
        ── local pulls over a token-authed REST surface ────
                                                            │
   GET  next-task        → prompt + context bundle (prior step summaries, project, repo hint)
   POST progress (opt)   → log lines onto the Task (timeline, NOT a streamed Message)
   POST result           → { status, summary, artifacts: [pr_url, branch, diff_stat] }
                                                            │
   → task.completed! (or awaiting_approval if a review gate follows)
   → run.running!  ·  WorkflowAdvanceJob.perform_later       (same re-entry as approve_current_gate!)
```

### What this drops vs. the runtime design

`Adapters::Bridge`, `Conversation#runtime`, the per-turn `UiEvent`
streaming contract, blocked workers, the SSE long-hold, cancel-polling,
the `#artifacts` gotcha. **The local work never touches `Adapters.for` /
`ChatJob`.**

### What it keeps

The per-user bridge token (scopes the pull API), and the gate-shaped
pause/resume the engine already runs (`approve_current_gate!` is the
template for `complete_delegated_task!`).

### Outside the conversation

The step stays a workflow `Task` — so sequencing, gates, and audit hold —
but it lives **outside the conversation message stream**: no streamed
assistant turn, no runtime binding. The run view renders it as a
*delegated step card* (status + result), beside the normal step cards. On
completion Metis may append **one compact summary line** to the timeline
("🔧 Implemented on `macbook-pro` → PR #123") for coherence — a plain
message, not a streamed turn. That is the "hand off *outside* the
conversation" the design calls for.

## Why local at all

- The implementation step should edit the user's **actual repo** with
  their real tools, env, and credentials — not a fresh sandbox scope.
- Metis is in the cloud; the laptop is behind NAT. **Only the laptop can
  dial out** — which is exactly what a *pull* model needs and nothing more.
- Delegating to local Claude Code uses the user's **own Claude
  subscription**, moving spend off Metis's API budget.

## What the references teach

- **[agentrq](https://github.com/agentrq/agentrq)** — now the **direct
  model**, not just an influence. A remote task board, a local agent that
  **pulls** assigned tasks (`getNextTask`), reports status
  (`updateTaskStatus`), and replies (`reply`); **workspace-id + token**
  auth; SSE only to *notify*, not to carry the work. This is precisely the
  delegated-Task + pull-REST shape above. Earlier this was filed under
  "Mode B, rejected"; the pivot makes it the spine — because for *handing
  off a discrete step* (vs. driving a live chat turn), agent-pull is the
  natural fit, and it keeps Metis from having to drive anything.
- **[ACP](https://agentclientprotocol.com)** (Agent Client Protocol) —
  demoted twice: first to a daemon-internal detail, then, once the daemon
  shipped, to a **future adapter** behind the daemon's `Agents` seam. pi, Claude
  Code, and Codex all have native headless JSON streams, so the daemon
  drives those directly; one generic ACP adapter joins the registry the
  first time an agent without a native stream is needed. In the lightest
  loop (the user's own Claude Code pulls via MCP) there is no ACP at all
  — the agent *is* the client.

## Transport: pull-based REST core

One token-authed REST surface is the whole core. **Pull, not push:** the
laptop makes outbound GETs, so NAT is a non-issue, no persistent
connection is held, no worker blocks, and a laptop offline for hours costs
Metis zero state. A push-notification (the existing email / in-app "needs
you" path, or an optional SSE *tickle*) is a later latency optimization —
the **data path stays pull**. A true bidirectional WebSocket is a later
upgrade only if live progress streaming is ever wanted.

**Layering (the v1 decision):** build only the REST surface. The **MCP
server** and the **daemon** are both thin clients of it, added later:

```
                    ┌───────────────────────────── Metis (cloud) ─────────────┐
                    │  WorkflowAdvanceJob ──(delegated step)──▶ awaiting_local │
                    │                                                          │
   token-authed     │   GET  /api/bridge/tasks/next                           │
   REST surface ◀───┼──  POST /api/bridge/tasks/:id/events    (progress)      │
   (the core)       │   POST /api/bridge/tasks/:id/result                     │
                    └──────────────────────────────────────────────────────────┘
                              ▲                         ▲
        ── pulls (outbound) ──┤                         ├── pulls (outbound) ──
                              │                         │
        the MCP server        │                         │  the metis daemon
        (user's Claude Code   │                         │  (polls, spawns the agent
         self-pulls via       │                         │   headless, reports — unattended)
         .mcp.json tools)     │                         │
```

## The REST surface

All endpoints bearer-authed by the user's bridge token, scoped to the
user's teams. An optional `X-Bridge-Client` header names the machine
("mikes-mbp") for the run timeline — display only, no registry behind it.

### `GET /api/bridge/tasks`

The claim queue, read-only: dispatched, unclaimed tasks across the
user's teams (`task_id`, `ref`, `name`, `prompt`, `workflow`,
`project`, `dispatched_at`). Lets a client show the queue and pick —
e.g. match a task's project to its cwd — instead of blind-claiming
FIFO. `ref` is a Sentry-style short reference ("CHEESE-1G", the
workflow slug + base36 id) accepted anywhere a task id is — claim
`?id=`, events, result, and the MCP tools.

### `GET /api/bridge/tasks/next`

Claims and returns the next dispatched delegated task (FIFO), or a
specific one via `?id=` — `204` when the queue is empty, `409` when the
requested id is no longer claimable. Claiming stamps `task.claimed_by`
(the client name). `?project=` narrows the FIFO to tasks under one
project — how an unattended client avoids blind-claiming work for a repo
it doesn't have. Like `X-Bridge-Client`, it's self-reported scoping per
request, not a capability registry; the interactive MCP loop gets the
same effect by list-then-pick.

```jsonc
// 200
{
  "task_id": 5521,
  "run_id": 880,
  "run_ref": "CHEESE-R1G",                 // keys the daemon's per-run worktree + branch
  "step": 3,                               // 1-based position — how far a resumed session is behind
  "name": "Implement the retry-budget cap",
  "prompt": "Implement the retry-budget cap described in the plan…",
  "context": {
    "input":    "review pr 75",            // the run's subject; omitted when blank
    "project":  { "name": "metis-api", "about": "Rails 8 API; conventions in…" },
    "uploads": [                           // what the operator attached to the run; omitted when none
      { "name": "chart.png", "url": "https://…/files/blobs/…signed…" }
    ],
    "prior_steps": [                       // the cloud steps so far, in full
      {
        "name": "spec",
        "content": "<the step's full output — a delegated step's result summary, or the whole assistant turn, untruncated>",
        "artifacts": [{ "name": "spec.md", "url": "https://…/files/blobs/…signed…" }]
      }
    ]
  },
  "env": { "GH_TOKEN": "ghu_…" }           // optional; omit → local uses own creds
}
```

`context.uploads` is what the operator attached to the run
(`WorkflowRun#uploads`). A cloud step gets these staged into
`workspace/uploads/` by its runtime; a delegated step has no runtime, so it
gets them the way it gets a prior step's artifacts — as links the daemon
renders into the prompt, for the agent to fetch if the step needs them. It
is a separate field, not a synthetic entry in `prior_steps`: uploads are the
run's seed rather than a step's output, and the prior-step bundle is skipped
for a resumed session that already saw it.

The `context` bundle is how prior cloud steps reach the local agent — full
step outputs plus signed URLs for any files they published, but **not a
session.** There is no pi-session continuity across the cloud→local
boundary (different machines); this bundle is the local agent's entire
brief, which is why nothing in it is truncated. (`repo_hint` and a
rendered `agents_md` stay future work — projects don't yet carry a repo
binding.)

### `POST /api/bridge/tasks/:id/events` (optional progress)

```jsonc
{ "kind": "log", "text": "Edited retry.rb; running tests…" }
```

Appended to the task for the run timeline. Lightweight and optional — a
client that only reports a final result is fine. Progress doubles as the
**liveness signal and the cancellation channel**: every post stamps the
task's `last_reported_at` (see *Reliability* below), and a post against a
task that is no longer live — run cancelled, step rejected, claim
reclaimed — returns `410 Gone`, which means **stop work now**. The served
skill teaches both halves.

### `POST /api/bridge/tasks/:id/result`

```jsonc
{
  "status": "completed",            // completed | failed
  "summary": "Capped retries at 5 with jittered backoff; tests green.",
  "detail": "Changed retry.rb and config/retry.yml; committed as abc123 on the run branch. …",
  "artifacts": [
    { "type": "pr",   "url": "https://github.com/acme/metis-api/pull/123" },
    { "type": "diff", "files_changed": 4, "insertions": 61, "deletions": 12 }
  ]
}
```

`summary` is the one-line timeline entry; `detail` is the agent's full
closing report — it is what later steps read (the next claim's
`prior_steps[].content`, and the fold-in when a cloud step follows), so
a summary-only result starves the handoff. Metis records the result on
the `Task`, optionally appends the timeline summary line, sets the task
`completed` (or `awaiting_approval` if the step carries a review gate),
flips the run back to `running`, and enqueues `WorkflowAdvanceJob` —
the exact re-entry `approve_current_gate!` uses.
A result posted after the task died (reclaimed, cancelled) is discarded
with `410 Gone` — the claim that holds the task wins, not the last
writer.

## Auth — a per-user token, no device registry

The credential is a **per-user bridge token** — the PAT model, the same
shape Claude Code's remote control uses (the credential *is* the pairing;
no machine enrollment). Generate it on `/settings/account`, plaintext
shown once (`mbt_…`, digest stored on `users.bridge_token_digest`), then
`export METIS_BRIDGE_TOKEN=…` (or put it in an `.mcp.json` header for MCP
mode). Regenerating revokes the old token — that *is* revocation; there
is no `Device` row, no enrollment flow, no `metis bridge login` CLI.

- Token scopes: pull dispatched tasks across the user's teams, post
  progress + results. Claiming obeys run visibility: a personal run's
  steps are claimable only by its launcher's machines; a team-visible
  run's steps are pooled across every member's daemon.
- Presence is one column: `users.bridge_seen_at`, stamped on every
  authenticated pull — drives the "is your machine connected" hint only.
- Machine identity is self-reported per request (`X-Bridge-Client`) and
  kept on the task as a display string. A device *registry* returns only
  if multi-device-per-user ever demands it — with evidence, not upfront.
- **Provider keys:** the local agent uses the **user's own** credentials
  by default; Metis sends a scoped `env` bearer only if configured.

## Workflow-engine integration

- **`WorkflowRun#status`** gains `awaiting_local` (sibling of
  `awaiting_approval`; included in `active`).
- **A step is marked delegated** in the workflow's `steps` jsonb (e.g.
  `"run": "local"`); `Task` carries it (a `delegated` boolean) plus
  delegation state: `claimed_by` (client-reported machine name),
  `result:jsonb`, `dispatched_at`.
- **`WorkflowAdvanceJob`**, on a delegated next task:
  `task.update!(status: :running, dispatched_at: …)`, `run.awaiting_local!`,
  notify, **stop**. (No `ConversationTurn.start`, no `ChatJob`.)
- **`WorkflowRun#complete_delegated_task!(task, result:)`** —
  records the result, advances exactly like `approve_current_gate!`. A
  delegated step may *also* carry an approval gate: the agent reports →
  `awaiting_approval` → human reviews the PR → advance.
- **Offline is just latency.** A dispatched task sits in `awaiting_local`
  until a client pulls it; `users.bridge_seen_at` only drives
  *notification* ("your laptop is offline"), never blocks the engine.

## Reliability: reclaim, retry, cancellation

Delegation is only as trustworthy as its failure story. A laptop that
dies mid-task must not park a run on `awaiting_local` forever — the same
hang class the engine already had fixed once at the gate level. Three
server-side mechanisms close it, none of which require the client to be
well-behaved.

**Progress is the heartbeat.** There is no heartbeat endpoint. Claiming,
posting an event, and posting a result all stamp
`tasks.last_reported_at` — the liveness signal *is* the work. A claimed
task that goes silent is indistinguishable from a dead client, by
design.

**Stale-claim sweeper.** A recurring job reclaims claims that have gone
silent past a TTL (minutes-scale, tuned to the progress cadence the
skill teaches): the task returns to the unclaimed pool — `claimed_by`
cleared, a reclaim counter bumped — and the run stays `awaiting_local`,
so the next pull picks it up with no human in the loop. After N reclaims
the task fails and the run notifies: a step that keeps killing its
client should surface, not cycle. Claiming itself is guarded by
`FOR UPDATE SKIP LOCKED`, so two clients racing `next` can never
double-claim.

**Failure classes are not interchangeable.** *Infrastructure* failures
(a reclaim, a claim that never started) re-dispatch silently — a laptop
crash should never read as a failed step. *Agent-reported* failures
(`"status": "failed"` in the result) fail the step and surface to the
human — the agent tried and couldn't, and retrying that burns time on
work that needs a person. Conflating the two either turns flaky networks
into noise or auto-retries judgment calls.

**Cancellation propagates on contact.** When a run is cancelled or a
step rejected while a client holds the task, the client's next `events`
or `result` post returns `410 Gone` and it stops. The attended loop
learns this from the served skill; the daemon upgrades it to
active status polling and terminates the agent process. v1 accepts the
window between cancellation and the next post — bounded by the progress
cadence, not by the turn.

## VISION posture — cleaner than the runtime design

[`VISION.md`](../VISION.md) holds **no second agent backend**. The
delegation model honors it more cleanly than a runtime would: **Metis
hands off a task and records a result — it never drives the agent.** There
is no second adapter, no second streaming path, no Metis-operated agent
process. The local agent is the **user's own tool on the user's own
machine**, reached through a task API that looks like any other connector.
v1 needs no ACP at all (the user's Claude Code self-pulls); ACP appears
only inside the optional daemon, behind one normalized stdio protocol.

## Open questions

- **Context handoff fidelity.** Settled two notches past the original
  plan: the bundle carries prior steps' *full* outputs + artifact URLs
  (the first dogfood run showed a 400-char truncation starves the
  implementer of its spec), and a delegated step's output is its result
  `detail` — the agent's full closing report — not the one-line summary
  (the second dogfood run re-created the same starvation local→local).
  Still open: whether the full `replayable_history` or a rendered
  `agents_md` ever needs to ride along too.
- **Cross-machine run continuity.** The per-run worktree hands repo
  state between steps only when one machine claims them all. When a
  team-pooled run's steps land on different machines, the later step
  starts from the checkout's HEAD — committed work reaches it only if
  the repo shares a remote the daemon could push/fetch (not built).
  Candidates, in escalation order: claim affinity (prefer the machine
  that claimed the run's earlier steps — cheap, server-side only), then
  an explicit push/fetch of the run branch. Wait for the friction to
  show before building either.
- **Result trust.** Metis records what the local agent reports
  (`pr_url`, diff stat) without verifying it. A later step can verify
  (CI, a cloud review turn), but v1 trusts the report. Worth a note in the
  gate copy.
- **Repo binding.** The `?project=` claim filter settles *which task* a
  client takes; how a project resolves to a path on disk stays the
  client's job — the agent's own cwd judgment in the attended loop, a
  project → path config map in the daemon.
- **Explicit per-step assignee — deferred until cost attribution bites.**
  Team-visible pooling means the claimer's machine spends the claimer's
  agent subscription. If teammates' daemons "helpfully" claiming heavy
  steps becomes friction, add an `assignee` (a person, defaulting to
  the launcher) folded into `claimable_by` — never a machine pin; which
  of their machines serves it stays their daemon's business.
- **Attended-claim ergonomics — deferred until the daemon.**
  Two known frictions in stop-and-go attended work, parked on purpose:
  a result against a *running-but-unclaimed* task 410s even when no one
  else wants the claim (it should atomically re-claim and be accepted),
  and stepping away has no voluntary *release* — the sweeper reclaim
  bumps `reclaims_count`, so deliberate pauses share a strike counter
  with crashed machines. Revisit once a workable daemon shows which
  frictions remain.

(Settled since the first draft: claim contention → `SKIP LOCKED` guard;
mid-flight loss → the stale-claim sweeper; worktree isolation → the
daemon's worktree-per-run rule, keyed by run since the 8-step dogfood
showed per-task trees strand each step's work. See *Reliability*.)
