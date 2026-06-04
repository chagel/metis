# Coding runtime (v2)

> **Status — shipped (Docker and E2b).** Both sandbox runtimes use the
> v2 lifetime shape. The shapes differ — Docker keeps an ephemeral
> container with a persistent host bind mount; E2b keeps the same
> microVM resumed via `pause`/`resume` — but in both cases the
> conversation's working tree, transcript, and installed dependencies
> survive between turns. `Agent::SessionArchive` is gone.

## Context

The sandbox runtimes (`Docker`, `E2b`) were per-turn disposable before
this change: each turn provisioned a fresh container or microvm,
restored the conversation's scope from a tar archive, ran pi, captured
the scope back, and tore the runtime down. That shape was right for
the chat-as-tool-use case metis grew out of — pi writes a small
script, runs it, returns output — and it preserved the worker-
fungibility the Rails background-job model needs.

It is the wrong shape for multi-turn coding. The cost shows up in three
places that compound on a real codebase:

- **Dependency installs** (`npm install`, `bundle install`, `cargo
  build`) pay their full cost every turn, or get committed to the repo
  to escape it. Neither answer is right.
- **WIP only survives by being pushed to GitHub** at end-of-turn. The
  agent has to choose between committing unfinished work or losing it
  — a forced distortion that no engineer working on their own laptop
  would accept.
- **Archive latency dominates the turn** as the workspace grows.
  Serializing a tarball through Active Storage on every turn is
  acceptable when "workspace" means a handful of agent-produced files;
  it stops being acceptable when it means a checked-out repo plus its
  build artifacts.

The natural unit of coding work is the *conversation*, not the turn.
The sandbox should live for the conversation.

## Decision: per-conversation sandbox lifetime

The sandbox is provisioned once at the conversation's first turn and
persists between turns; idle conversations are reaped after an
eviction window. A conversation whose state has been evicted provisions
fresh on its next turn — same path as the very first turn.

Worker fungibility is preserved because the persistent state lives in
**addressable remote storage** (E2B's snapshot store, or the host
filesystem at a deterministic path), not in a worker process. A turn
doesn't pin to a worker — any worker can pick up any turn, as before.

### Per-runtime shape

**`Runtime::Docker`** — see "Docker: persistent host workspace" below.

**`Runtime::E2b`** — see "E2b: pause/resume the microVM" below.

**`Runtime::Daytona`** — the Daytona analog of E2b. Same resume-by-id
shape, but "pause" is Daytona's `stop` and "resume" is `start`. The
economics differ: an E2B suspended sandbox is free, whereas a *stopped*
Daytona sandbox still bills disk storage (an *archived* one — cheaper,
slower to resume — less). So stopping each turn ends compute billing, and
the cost ladder is Daytona-native (`autoArchive`/`autoDelete` intervals at
create) rather than `EvictPausedSandboxesJob`; `autoStop` is a crash-only
net set above the longest turn. The sandbox id lives on
`Conversation#daytona_sandbox_id`.

**`Runtime::Local`** — unchanged. Persistence has always been pi-native
(the scope dir lives between turns on a stable host filesystem).
`Local` is dev-only; the v2 lifetime shape is for the sandbox runtimes.

### Docker: persistent host workspace

The draft of this doc originally proposed a long-lived `metis-c<id>`
container with `docker exec` per turn and an eviction job to reap idle
containers. What landed is simpler: **the container stays
`docker run --rm` ephemeral, but the conversation's workspace moves
from `Workspace.scratch` (under `tmp/`) to `Workspace.persistent`
(under `storage/`) — already the shape `Local` uses — and the bind
mount into the container preserves the working tree across turns**.

The split, framed by what survives a turn:

| Survives | Doesn't |
|---|---|
| Files under the bind-mounted workspace — repo, `.git`, untracked WIP, `node_modules`, build artifacts | Anything outside the workspace — `apt install`s, global npm, `$HOME` config, `/tmp` |

For coding work the surviving column is what matters: the repo, the
in-progress branch, the installed dependencies. The "doesn't" column
is honest about what the agent should not rely on (it shouldn't `apt
install` and expect it to be there next turn).

The simpler shape avoids two pieces of infrastructure the persistent-
container shape needs:

- **No eviction job.** Containers are gone the moment the turn ends.
  Idle conversations cost no Docker resources, just disk for the
  persistent workspace.
- **No "container wedged" recovery path.** Every turn starts a fresh
  container.

It also keeps turn startup a hair slower (cost of `docker run` vs.
`docker exec`) — order of hundreds of milliseconds, not a real
problem for chat turns that take seconds to minutes. The persistent-
container shape stays available as a future optimisation if that
latency starts mattering.

### E2b: pause/resume the microVM

E2B's SDK supports first-class pause/resume of a running sandbox: a
paused VM has its full state (filesystem, in-memory daemons, anything)
preserved server-side and can be resumed by id from any worker.

- **First turn** — `Sandbox.create(template:)` → run → `sandbox.pause`
  → save `sandbox_id` on the `Conversation`.
- **Subsequent turns** — `Sandbox.connect(sandbox_id)` →
  `sandbox.resume(timeout:)` → run → `sandbox.pause`.
- **Stale id** — if `Sandbox.connect` raises `NotFoundError` (paused
  state expired, manual kill, eviction already happened), the runtime
  clears the id and provisions fresh. No user-visible error.

**Eviction is metis's responsibility.** E2B explicitly keeps paused
sandboxes *indefinitely* — no TTL, no auto-cleanup. Without eviction,
every conversation a user ever opens leaves a paused sandbox on
E2B's servers forever, paying for storage we don't use.
`EvictPausedSandboxesJob` runs hourly (Solid Queue recurring), kills
sandboxes whose conversation has been idle past
`config.x.agent.e2b_eviction_window` (default 24h via
`METIS_E2B_EVICTION_HOURS`), and clears the stored id.

The other half of the eviction contract is
`Conversation#before_destroy`, which kills the paused sandbox on
explicit deletion. Without this, deleted conversations leak.

### What stops being needed

- **`Agent::SessionArchive`.** Both runtimes are off it; the class is
  gone. The `pi_session_archive` attachment on `Conversation` goes
  with it. Existing Active Storage blobs are orphaned by this change
  and can be cleaned up out-of-band.
- **`Workspace#reset!` in Docker's `run`.** There is no scratch dir to
  reset; the workspace is the durable state holder.
- **The hydrate / persist tar round-trip in E2b's `run`.**
  Pause/resume replaces it.
- **The "push to survive" rule in `AGENTS.md`.** The working tree
  persists across turns; commits and pushes return to their natural
  meaning (publishing work that is ready, not a save mechanism).

### What stays the same

- **Credential pass-through.** `Runtime::Base#sandbox_env` keeps
  composing the per-turn env (`GH_TOKEN`, git identity) from the
  user's `OauthGrant`s. The bearer must remain a per-turn projection
  even though the sandbox persists — OAuth tokens refresh, and a
  stale token cached in `~/.netrc` would silently fail. Each turn
  injects a fresh bearer; the sandbox should not persist it.
- **Per-turn projected inputs** — `workspace/uploads/`,
  `workspace/.mcp.json`, `workspace/AGENTS.md`,
  `workspace/.pi/skills/` — keep being re-staged each turn from
  their durable Rails sources. The sandbox's copy is always a
  projection; the conversation's durable state lives in Rails.
  Each projector carries its own signature marker to skip the
  re-stage on a no-drift turn (e.g. `.staged.sig` for skills).
- **The Adapter / `UiEvent` / `ChatJob` / `ChatBroadcaster` stack.**
  Orthogonal. The runtime-shape change is below the streaming
  protocol; the chat path is unchanged.
- **The `Runtime::Base` interface.** `#run`, `#session_dir`,
  `#extension_paths`, `#mcp_config`, `#identity_content`,
  `#sandbox_env` all keep their meaning. What changes is what `#run`
  *does* under the hood.

### Migration

Both runtimes shipped with **no migration path**: existing
conversations' `pi_session_archive` attachments are ignored on the
first v2 turn. The user-visible loss is one-time and bounded to "the
agent's prior working tree and pi transcript are gone" — the
conversation's message history is on `Message` rows and is
unaffected. Orphaned Active Storage blobs from the old attachment can
be GC'd later out-of-band.

## Out of scope for this change

- **Credential model change.** OAuth user grant stays. The GitHub App
  user-to-server token path (see
  [`connectors.md`](connectors.md#credential-pass-through-to-the-sandbox))
  is a future option for narrower per-repo scoping, but does not
  block — or depend on — sandbox-lifetime work.
- **`Project` or `RepoBinding` resource.** Not introduced as part of
  this. The repo the user mentions in chat continues to be the only
  binding; the agent clones what is asked, when it is asked, using
  the bearer it was given.

## Open

- **E2b paused-storage pricing.** Not published by E2B; the 24h
  default eviction window is a conservative guess. Worth measuring
  once we have meaningful usage, then tuning `METIS_E2B_EVICTION_HOURS`.
- **Docker multi-worker.** A single-host self-host is fine; a
  multi-worker deployment needs the persistent workspace root on
  shared FS (NFS or equivalent) or per-conversation host pinning.
  Same constraint `Local` has always had; worth deciding before the
  second host appears, not after.
- **Workspace size cap.** Per-conversation disk budget — a runaway
  `git clone` of a huge monorepo should fail predictably, not
  consume host disk (Docker) or E2B quota.
