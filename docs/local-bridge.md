# Local bridge (design + build plan)

> Status: **design + build plan**, not yet implemented. Companion to
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
  demoted to a **daemon-internal detail**. ACP matters only if/when a
  `metis-bridge` daemon drives a *headless* agent unattended (Phase 3); it
  normalizes Claude Code / Codex / Gemini / pi behind one stdio protocol.
  In the lightest v1 (the user's own Claude Code pulls via MCP) there is
  no ACP — the agent *is* the client.

## Transport: pull-based REST core

One token-authed REST surface is the whole core. **Pull, not push:** the
laptop makes outbound GETs, so NAT is a non-issue, no persistent
connection is held, no worker blocks, and a laptop offline for hours costs
Metis zero state. A push-notification (the existing email / in-app "needs
you" path, or an optional SSE *tickle*) is a later latency optimization —
the **data path stays pull**. A true bidirectional WebSocket is a Phase-N
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
        Phase 2: MCP server   │                         │  Phase 3: metis-bridge daemon
        (user's Claude Code   │                         │  (polls, spawns pi/Claude Code
         self-pulls via       │                         │   via ACP, reports — unattended)
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
(the client name).

```jsonc
// 200
{
  "task_id": 5521,
  "run_id": 880,
  "name": "Implement the retry-budget cap",
  "prompt": "Implement the retry-budget cap described in the plan…",
  "context": {
    "project":  { "name": "metis-api", "about": "Rails 8 API; conventions in…" },
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
client that only reports a final result is fine.

### `POST /api/bridge/tasks/:id/result`

```jsonc
{
  "status": "completed",            // completed | failed
  "summary": "Capped retries at 5 with jittered backoff; tests green.",
  "artifacts": [
    { "type": "pr",   "url": "https://github.com/acme/metis-api/pull/123" },
    { "type": "diff", "files_changed": 4, "insertions": 61, "deletions": 12 }
  ]
}
```

Metis records the result on the `Task`, optionally appends the timeline
summary line, sets the task `completed` (or `awaiting_approval` if the step
carries a review gate), flips the run back to `running`, and enqueues
`WorkflowAdvanceJob` — the exact re-entry `approve_current_gate!` uses.

## Auth — a per-user token, no device registry

The credential is a **per-user bridge token** — the PAT model, the same
shape Claude Code's remote control uses (the credential *is* the pairing;
no machine enrollment). Generate it on `/settings/account`, plaintext
shown once (`mbt_…`, digest stored on `users.bridge_token_digest`), then
`export METIS_BRIDGE_TOKEN=…` (or put it in an `.mcp.json` header for MCP
mode). Regenerating revokes the old token — that *is* revocation; there
is no `Device` row, no enrollment flow, no `metis bridge login` CLI.

- Token scopes: pull dispatched tasks across the user's teams, post
  progress + results.
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

## VISION posture — cleaner than the runtime design

[`VISION.md`](../VISION.md) holds **no second agent backend**. The
delegation model honors it more cleanly than a runtime would: **Metis
hands off a task and records a result — it never drives the agent.** There
is no second adapter, no second streaming path, no Metis-operated agent
process. The local agent is the **user's own tool on the user's own
machine**, reached through a task API that looks like any other connector.
v1 needs no ACP at all (the user's Claude Code self-pulls); ACP only
appears inside an optional daemon in Phase 3, behind one normalized stdio
protocol — argued there, not assumed here.

## Build phases

### Phase 0 — Token + presence (no delegation yet) ✅
- **Migration**: `users.bridge_token_digest` (unique index) +
  `users.bridge_seen_at`. No devices table.
- **`User`**: `generate_bridge_token!` (plaintext shown once),
  `.authenticate_bridge_token`, `bridge_seen!`.
- **`/settings/account` → Local bridge card**: generate/regenerate +
  copy, last-connected hint.
- **Tests:** token mint/rotate/verify; account action auth.

### Phase 1 — Delegation core (REST + engine lifecycle) ✅
- `WorkflowRun#status += awaiting_local`; `Task` delegation columns +
  `delegated?`.
- `Api::Bridge::TasksController` — `next` (claim), `events`, `result` —
  bearer-authed by the user's bridge token.
- `WorkflowAdvanceJob` delegated-step branch;
  `WorkflowRun#complete_delegated_task!`.
- Run-view delegated-step card; optional timeline summary line.
- **Tests:** a delegated workflow dispatches → `awaiting_local`; a posted
  result advances the run; a `failed` result fails the step; an
  approval-gated delegated step routes to `awaiting_approval`; token auth
  scoping (a token can't reach another team's task).

### Phase 2 — hosted MCP facade (lightest local surface) ✅
- `POST /api/bridge/mcp` — a stateless streamable-HTTP MCP server in
  Rails, exposing `list_tasks` / `get_next_task` / `report_progress` /
  `submit_result` over the same models as the REST surface (same bearer
  auth, same team scoping). Nothing to install on the laptop; a coding
  agent needs one URL and the token:

  ```bash
  claude mcp add --transport http metis-bridge \
    https://your-metis-host/api/bridge/mcp \
    --header "Authorization: Bearer mbt_…"   # from /settings/account
  ```

  Serving our own task API over MCP does not breach VISION's "no
  Rails-side MCP client" line — Rails answers here, it never consumes
  an MCP server (that stays pi's job). The intended loop: the agent
  calls `list_tasks`, picks the task whose project matches its checkout
  (or asks), claims it by id, works, then `submit_result` — the run
  resumes in Metis.
- `GET /api/bridge/skill` — the client-side skill (SKILL.md, served
  unauthenticated with the deployment URL baked in) that teaches a local
  agent that loop: MCP setup, list-before-claim, the worktree-isolation
  rule, submit-once etiquette, failure reporting. One install:

  ```bash
  curl -fsSL --create-dirs https://your-metis-host/api/bridge/skill \
    -o ~/.claude/skills/metis-bridge/SKILL.md
  ```

### Phase 3 — Daemon + ACP (unattended)
- `metis-bridge` daemon polls the REST surface, spawns the agent
  (`pi --mode rpc`, or Claude Code / Codex via ACP over stdio), reports
  back. For hands-off automation and non-pi agents.

### Phase 4 — Notifications + live progress
- Push-notify dispatched tasks (in-app, email, Slack); optional SSE tickle
  to cut poll latency; optional progress streaming into the run card.

## Open questions

- **Context handoff fidelity.** Settled one notch past the original
  plan: the bundle carries prior steps' *full* outputs + artifact URLs
  (the first dogfood run showed a 400-char truncation starves the
  implementer of its spec). Still open: whether the full
  `replayable_history` or a rendered `agents_md` ever needs to ride
  along too.
- **Result trust.** Metis records what the local agent reports
  (`pr_url`, diff stat) without verifying it. A later step can verify
  (CI, a cloud review turn), but v1 trusts the report. Worth a note in the
  gate copy.
- **Claim contention.** Two clients both `GET next-task` — FIFO claim
  with a single-claim DB guard (SKIP LOCKED).
- **Repo binding.** How `repo_hint` resolves to a local checkout — the
  daemon/agent's own cwd, or a client-side config map (project → path).
- **Mid-flight loss.** A client claims a task then never reports
  (laptop dies). A reclaim window: `dispatched_at` past a TTL returns the
  task to the unclaimed pool.
- **Worktree isolation.** Learned live: a delegated task whose target
  repo's checkout is doing other duty (serving the dev instance, holding
  a feature branch mid-work) must not switch that checkout's branch —
  the first dogfood run briefly knocked the bridge API off the dev
  server it was reporting to. The Phase 3 daemon should run tasks in a
  `git worktree`; until then the coding-step prompt should say so.
