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
  files. See coding-runtime's provisioning notes. The host root is a
  **reclaimable hot cache, not permanent storage** — see
  [Docker workspace eviction](#docker-workspace-eviction).

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

## Docker workspace eviction

Without a bound, every Docker conversation leaves its clone, dependency
installs, and build output on the host forever. Two jobs keep the
persistent root finite; durable state (`Message` rows, attachments,
projected inputs) is never touched.

- **Warm eviction** — `EvictDockerWorkspacesJob` (hourly,
  `config/recurring.yml`) deletes `workspace/` for Docker conversations
  idle past `METIS_DOCKER_WORKSPACE_EVICTION_HOURS` (default 72; messages
  touch the conversation, so `updated_at` is the idle clock). `sessions/`
  stays, so pi still resumes with `--continue` and no DB history replay.
  In-flight turns and active workflow runs are never evicted; eligibility
  is re-checked under the conversation row lock — the same lock
  `ConversationTurn.start` takes — so an eviction can't race a turn being
  born. No marker column: `Runtime::Docker#workspace_evicted?` derives
  the state from disk (a prior turn ran but `workspace/` is missing) and
  `Agent::Identity` warns that turn its files are gone.
- **Scope destruction** — destroying a `Conversation` enqueues
  `CleanupPersistentWorkspaceJob` (`after_destroy_commit`, immutable
  scalar ids), which removes the whole scope, sessions included.

`Agent::Workspace` owns both deletions (`#evict_workspace!`,
`.destroy_scope!`) so the scope layout and its removal live in one
place; destroy takes bare integer-validated ids because the row is
already gone.

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
