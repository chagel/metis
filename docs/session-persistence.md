# Session Persistence

## Context

A conversation with pi is stateful: pi keeps a session transcript (its
`--session-dir`) and a workspace (files it creates). Turn N must see turn
N−1's state. metis runs each turn as a background job on an interchangeable
worker, in a per-turn execution environment.

## Principle: persistence is a per-runtime concern

How a conversation's state survives between turns depends on *where* the
agent ran — so it belongs to the `Runtime`, not to one shared mechanism.

- **`Runtime::Local`** — pi runs as a host subprocess on a stable
  filesystem. pi's own file-based session management is enough: the scope
  lives in a persistent, conversation-stable directory and `--continue`
  resumes it. No archiving.

- **`Runtime::Docker`** — the container is still `--rm` and disposable,
  but the conversation's scope is a **persistent host directory
  bind-mounted into it**. The container's ephemerality stays a security
  boundary; persistence rides on the bind mount, which is metis's
  durable storage. No archive — the host filesystem is the durable
  source. See [`coding-runtime.md`](coding-runtime.md). The constraint
  that follows (workers all need access to the persistent workspace
  root) is the same one `Local` has always had. Under Docker-in-Docker
  (the production setup, where the worker is itself a container) that
  root must sit at an **identical absolute path** on host and worker —
  `METIS_PERSISTENT_ROOT`, default `/srv/metis/agent` in prod — so the
  per-turn bind mount the host daemon performs resolves to the same
  files. See coding-runtime's provisioning notes. The host scope is a
  **reclaimable hot cache**, not permanent storage — idle `workspace/`
  trees are warm-evicted by `EvictDockerWorkspacesJob` (see
  [Docker workspace eviction](#docker-workspace-eviction) below).

- **`Runtime::E2b`** — the microVM has no host bind mount, but E2B
  natively pauses and resumes a sandbox by id. First turn:
  `Sandbox.create` → run → `pause` → save sandbox_id. Subsequent
  turns: `Sandbox.connect(id)` → `resume` → run → `pause`. The same
  microVM carries the working tree, transcript, and installed
  dependencies across turns. See [`coding-runtime.md`](coding-runtime.md).
  E2B keeps paused sandboxes indefinitely, so metis runs
  `EvictPausedSandboxesJob` to kill long-idle ones — the next turn
  provisions fresh.

- **`Runtime::Daytona`** — the Daytona analog of E2b: an elastic cloud
  sandbox resumed by id. "Pause" maps to `stop`, "resume" to `start`
  (Daytona persists a stopped sandbox's filesystem on its runner). First
  turn: `client.create` → run → `stop` → save sandbox_id. Subsequent
  turns: `client.get(id)` → `start` → run → `stop`. The economics differ
  from E2B, though: a suspended E2B sandbox is free, but Daytona keeps
  billing a *stopped* sandbox for disk storage (archived is cheaper but
  slower to resume). So stopping each turn only ends *compute* billing;
  to bound the residual storage cost there is **no eviction job** —
  `create` sets Daytona's native `autoArchive` and `autoDelete` intervals
  (idle sandbox → cheap object storage → reaped), and `autoStop` is set
  high as a crash-only safety net. The next turn against a deleted sandbox
  provisions fresh.

`Agent::SessionArchive` is gone. The tar-to-Active-Storage path is no
longer needed by any runtime.

## Context rehydration on a reaped sandbox

When a cloud sandbox is reaped (E2B eviction, Daytona auto-delete, manual
delete), the next turn provisions a *fresh* one — and pi's `--session-dir`
transcript is gone with it, so pi would resume with no memory of the
conversation. metis still holds every turn in the DB (`Message` rows), so
on that fresh-provision-after-a-prior-session case it replays the
conversation back into the new sandbox as restored context.

This is **not** an archive of pi's session state — it's a projection of
durable Rails state, exactly like uploads or `AGENTS.md`. The transcript
is rendered into the per-turn `AGENTS.md` (`Agent::Identity`, gated on
`Runtime::Base#context_lost?` — fresh sandbox **and** a prior
`backend_session_id`), so it lands in pi's context every turn without a
separate read step. The render is bounded (recent turns within a char
budget) and leads with a warning that the workspace files are gone too —
the agent must not act as if anything it wrote earlier is still on disk.

## Docker workspace eviction

Docker's persistent host scopes accumulate repository clones, `.git`,
dependency installs, and build output indefinitely — workflow runs
amplify this because every run owns a conversation. `EvictDockerWorkspacesJob`
(recurring, **every 15 minutes** in production) treats them as a hot
cache and reclaims idle ones.

**Warm eviction** deletes only `scope/workspace/` and preserves
`scope/sessions/` — pi's transcript survives, so the next turn resumes
with `--continue` as usual and **no DB history replay happens** (this is
not the reaped-sandbox case above). What's lost is exactly the working
files: repos, dependencies, artifacts, uncommitted WIP. Durable Rails
state — `Message` rows, attachments, the projected inputs — is
untouched and re-staged as always.

Retention is per lifecycle class, each an independent env knob
(invalid values fail boot):

| Class | Window | Measured from |
|---|---|---|
| Workflow run in a terminal status (`completed` / `failed` / `cancelled`) — `METIS_DOCKER_WORKFLOW_EVICTION_HOURS` | 24h | later of the run's `updated_at` and `docker_workspace_last_used_at` |
| Archived ordinary conversation — `METIS_DOCKER_ARCHIVED_WORKSPACE_EVICTION_HOURS` | 24h | later of `archived_at` and `docker_workspace_last_used_at` |
| Other ordinary conversation — `METIS_DOCKER_WORKSPACE_EVICTION_HOURS` | 168h (7d) | `docker_workspace_last_used_at`, falling back to the conversation's `updated_at` for legacy rows |

Workflow classification wins over archived/ordinary. Only
conversations whose **last turn ran on Docker** are eligible — Local,
E2B, and Daytona storage is never touched by this job. A conversation
with an in-flight turn, or whose workflow run is in any active status
(`queued` / `pending` / `running` / `awaiting_approval` /
`awaiting_local`), is never evicted — a run parked at an approval or
local gate keeps its workspace no matter how long it waits.

**Serialization.** `ConversationTurn.start` and the eviction job take
the same Conversation **row lock**; eviction re-checks eligibility
after acquiring it and holds it through deletion, so a turn can never
be born mid-eviction. Successful eviction records
`docker_workspace_evicted_at` + `docker_workspace_eviction_reason`
(`workflow_terminal` / `archived_idle` / `ordinary_idle` / `low_disk`)
on the conversation. While the marker is set, `Agent::Identity` puts a
verbatim warning in the next Docker turn's `AGENTS.md` telling the
agent its earlier files are gone; a **successful** Docker turn clears
the marker (a failed one keeps it, so the warning repeats).

**Low-disk emergency.** When the filesystem holding
`METIS_PERSISTENT_ROOT` drops below
`METIS_PERSISTENT_LOW_WATERMARK_PERCENT` free (default 15), the job
warm-evicts otherwise-eligible Docker scopes **oldest-first,
retention windows waived**, re-checking free space after each
deletion, until `METIS_PERSISTENT_RECOVERY_WATERMARK_PERCENT` (default
25) is reached or eligible scopes run out — active work is never
sacrificed. Boot validates `0 <= low < recovery <= 100`. If free space
can't be determined safely (missing root, `df` failure, unparseable
output), the job logs and deletes nothing — unknown never reads as
"disk full".

**Permanent deletion.** Destroying a `Conversation` enqueues
`CleanupPersistentWorkspaceJob` after commit (never `rm_rf` inside the
destroy transaction), which removes the **whole scope including
`sessions/`**, idempotently, from the captured scalar ids.

**Path safety.** All deletion paths go through
`Agent::WorkspaceCleanup`: built only from validated positive-integer
ids into the exact `u<ID>/c<ID>[/workspace]` shape, verified beneath
the expanded root, symlinks unlinked rather than followed (measurement
is no-follow too), canonicalization mismatches refused. **Orphan
scopes** — directories with no matching Conversation row — are flagged
by the report but never auto-deleted.

**Operations.** `bin/rails metis:workspaces:report` prints a read-only
usage report: free space, per-scope byte counts (total / `sessions/` /
`workspace/`), each scope's conversation / runtime / workflow /
archive / in-flight / eviction state, and `orphan=true|false`. The
eviction job logs structured events (`docker_workspace_evicted`,
`…_skipped`, `…_failed`, `…_summary`, `persistent_workspace_destroyed`)
— disk scans run only in the background jobs and this task, never in
request paths.

## Scope layout

    scope/
      sessions/           pi --session-dir : the transcript
      workspace/          pi cwd : files the agent itself creates
        uploads/          staged user uploads — see below

## Projected inputs are not session state

Some workspace contents are *projections* of durable Rails state, not
agent-produced output: user uploads, the rendered MCP connector config,
the agent's per-turn boot identity. Each is read straight from its
durable source at the start of every turn and **overwritten in place**
in the persistent workspace — host filesystem for `Local` and `Docker`,
the resumed microVM for `E2b`, the resumed sandbox for `Daytona`.

| Projected input | Source |
|---|---|
| `workspace/uploads/*` | `Message` attachments (Active Storage) |
| `workspace/.mcp.json` | `Connector` + `ConnectorCredential` (see [`connectors.md`](connectors.md)) |
| `workspace/AGENTS.md` | `Conversation` + `Team` + runtime (see [`agent-identity.md`](agent-identity.md)) |
| `workspace/.pi/skills/*` | The repo's `.pi/skills/` tree + the team's enabled `Skill` rows — see [`skills.md`](skills.md) |

The projection writes overwrite the previous turn's copy in place
on every runtime — durable Rails state is read once per turn at its
canonical source, regardless of how the workspace itself persists.
