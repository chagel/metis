# Bridge tools

> Status: **draft plan** — nothing built yet. Companion to
> [`local-bridge.md`](local-bridge.md), which delegates a *whole step* to
> an agent installed on the user's machine. This doc inverts that: the
> agent stays in the Metis sandbox and only its **tools** run on the
> user's machine. The `metis` daemon needs no Claude Code, Codex, or pi
> installed — it is the hands, Metis is the brain.

## The shape

A regular chat turn, with pi running in its usual sandbox runtime, whose
`bash` / `read` / `write` / `edit` / `ls` calls execute in the user's
real checkout. The daemon polls for tool calls the way it already polls
for tasks; pi reaches the daemon through the one sandbox→host channel
Metis already has, `Agent::HostBridge`.

```
   sandbox pi ──(bridge_bash …)──▶ metis-bridge extension
                                    ctx.ui.input("metis:bridge_call", …)
                                          │  pi RPC (extension UI)
                                          ▼
   Rails: Agent::HostBridge#bridge_call ── insert BridgeCall ── wait ──▶ result JSON
                                          │                        ▲
                token-authed              │                        │
                pull surface   GET  /api/bridge/calls/next        │
                               POST /api/bridge/calls/:id/heartbeat
                               POST /api/bridge/calls/:id/result ─┘
                                          │
                               metis daemon (serve_tools) — runs it in the
                               project's mapped path, posts the result
```

Why this and not the alternatives:

- **Not a Rails-side MCP client.** Rails consumes nothing; it records a
  call and waits for a result, exactly like a delegated task.
- **Not a new `Runtime`.** The turn is an ordinary `ChatJob` turn on an
  ordinary runtime. Streaming, cancel, stats, artifacts all unchanged.
- **Not a second agent.** pi is the only agent; the daemon runs no loop.
- **Not an MCP server in the daemon.** An MCP path would need a
  per-turn token in `.mcp.json`, a new pi-facing HTTP endpoint, and a
  held Puma thread per tool call. HostBridge rides pi's RPC, needs no
  token, and its wait runs on the ChatJob worker that is already held for
  the whole turn (pi-agent-rb services each extension-UI request on its
  own thread, so the wait never stalls the event stream).
- **Pull, not websocket.** Same reasons as `local-bridge.md`: NAT,
  multi-process Rails, zero state for an offline machine.

## Pieces

### 1. `BridgeCall` (Rails model + migration)

`bridge_calls`: `user_id`, `conversation_id`, `project_id`, `tool`,
`args:jsonb`, `status` (pending / running / done / failed / cancelled),
`claimed_by`, `claimed_at`, `last_reported_at`, `result:jsonb`,
timestamps. Index `(user_id, status)`.

- `claim_next_for(user, client:, project:)` — copy of
  `Task.claim_next_for`: `FOR UPDATE SKIP LOCKED`, stamps `claimed_by`
  and `last_reported_at`. `?project=` narrows to calls whose project the
  daemon has a path for, so a second machine never claims work it can't
  run.
- Scoped to the **conversation's user only**. Team pooling makes no sense
  here: the tools must run on the machine that has that user's checkout.
- `live?` — pending or running, and the conversation has not requested
  cancel. Everything that posts against a dead call gets `410`.

### 2. HostBridge op `bridge_call`

Add `bridge_call` to `Agent::HostBridge::OPS`. It inserts a `BridgeCall`
and waits: poll the row every 250 ms until `done` / `failed`, or the
conversation's `cancel_requested_at` flips, or `config.x.bridge.call_ttl`
elapses (default 10 minutes; the tool passes a shorter `timeout` for
`read` / `ls`). Returns the result hash the extension turns into the
tool result: `{ ok, output, exit_code, truncated }`, or
`{ ok: false, error: "…" }` on timeout, cancel, or no daemon online.

Guard up front: if `user.bridge_online?` is false (see §5), return the
error immediately with the daemon install hint, so the model never waits
on a machine that isn't there.

### 3. Daemon-facing REST (`Api::Bridge::CallsController`)

Bearer bridge token, same base controller, same presence stamp.

- `GET /api/bridge/calls/next?project=…&wait=20` — long-poll: loop
  checking for a claimable call up to `wait` seconds, `204` on timeout.
  One held Puma thread per connected daemon. Acceptable for v1; a
  Solid Cable tickle is the later optimization.
- `POST /api/bridge/calls/:id/heartbeat` — stamps `last_reported_at`
  while a long `bash` runs. `410 Gone` when the call died: the daemon
  kills the process group and moves on. This is cancellation.
- `POST /api/bridge/calls/:id/result` — `{ ok, output, exit_code,
  truncated }`. `410` if dead.
- `ReclaimSilentBridgeCallsJob` (recurring, every minute): a claimed
  call silent past `config.x.bridge.call_silence_ttl` (default 60 s) is
  **failed**, not reclaimed — re-running a shell command on a second
  machine is unsafe. The waiting HostBridge sees `failed` and the model
  gets "your machine went silent".

### 4. The pi extension (`.pi/extensions/metis-bridge/index.ts`)

Mirrors `metis-workflow`. Registers `bridge_bash`, `bridge_read`,
`bridge_write`, `bridge_edit`, `bridge_ls`, each with the same schema as
pi's builtin, each calling `hostCall(ctx, "bridge_call", { tool, args })`.
Descriptions say where they run: "on the user's own machine, in the
project checkout".

**Spike first (see Phase 0):** if pi lets an extension register a tool
under a builtin's name, register them *as* `bash` / `read` / `write` /
`edit` / `ls` instead. Then bridge mode is just "load the extension": the
model's habits, skills, and AGENTS.md conventions carry over untouched,
and there is no two-filesystems confusion. If pi does not allow
shadowing, bridge-mode turns pass `--tools` as a strict allowlist of the
`bridge_*` tools plus the `metis_*` and `web_*` extension tools, and
`Agent::Identity` adds one paragraph telling the model the sandbox
filesystem is not the repo.

Staged only for bridge-mode turns, via the runtime's `extension_paths`,
the same way `metis-workflow` reaches the sandbox today.

### 5. Turning it on

- **Presence:** `User#bridge_online?` = `bridge_seen_at` within the last
  minute. The daemon's `calls/next` long-poll keeps it fresh for free.
  Add `users.bridge_serves_tools` (boolean, stamped by the daemon's first
  `calls/next`) so the UI can tell "daemon running" from "daemon serving
  tools".
- **Per conversation:** `conversation.settings["bridge"] = true`. Requires
  a project (the daemon maps project name → path). A composer toggle,
  "Run on *mikes-mbp*", enabled only when the user is online and the
  conversation has a project. The client name comes from
  `users.bridge_client`, already stamped.
- **Adapter:** `Agent::Adapters::Pi#pi_args` adds the extension (and
  `--tools`, if the spike says so) when the conversation is in bridge
  mode.
- **Timeline:** `tool_call_started` for `bridge_*` (or shadowed builtins
  in a bridge-mode conversation) renders with a machine glyph and the
  client name. `UiEvent#native_ref` already carries `toolName`.

### 6. Daemon (`clients/metis`)

New `tools.go` + `tools_test.go`. `metis daemon` starts a second loop
when `serve_tools: true` in config (or `--serve-tools`), alongside the
task loop. Per server:

- Long-poll `calls/next?project=<each mapped project>`; run at most
  `max_workers` calls concurrently (pi issues most calls serially, read-only
  ones may overlap).
- **Path resolution:** `project` → path via the existing `Projects` map.
  Unknown project → result `{ ok: false, error: "no local path for
  project X" }`, so the model learns on the first call.
- **Executors:** `bash` via `sh -c` in the project path, process group,
  per-call timeout, output capped (64 KB, `truncated: true`); `read`
  with offset/limit; `write`; `edit` as exact-string replace with the
  same uniqueness rule as pi's; `ls`. File tools resolve symlinks and
  refuse paths outside the project root. `bash` can `cd` anywhere — that
  is inherent to running shell on the user's machine and is documented,
  not defended.
- **Heartbeat** every 15 s while a `bash` runs; `410` → kill the group.
- Reuse `Api` (`do`, `post`, `statusError`) — three new methods, no new
  HTTP plumbing.

## Phases

**Phase 0 — spike (half a day).** Two facts decide the extension design:

1. Can a pi extension register `bash` and shadow the builtin? (pi 0.84.4
   docs; try it in a local pi.)
2. Does `ctx.ui.input` carry a default timeout that would cut off a
   long `bash`? (`ExtensionUI::Request#timeout_ms` exists; confirm the
   extension can pass a long or absent one.)

**Phase 1 — core, hidden.** `BridgeCall` + migration, HostBridge op,
`CallsController`, sweeper, `config.x.bridge.call_ttl` /
`call_silence_ttl`, daemon `tools.go`. Exercise it from a Rails console
by inserting a call by hand and watching the daemon answer. Tests:
claim under `SKIP LOCKED`, HostBridge wait with a thread posting the
result, controller `204` / `410` paths, sweeper fails silent calls, Go
executors (path guard, truncation, timeout, kill on `410`).

**Phase 2 — the turn.** Extension, `pi_args` wiring, `bridge_online?`,
`bridge_serves_tools`, composer toggle, identity paragraph, timeline
glyph. Dogfood: "run the test suite in metis and fix what fails" from
the web UI against a local checkout.

**Phase 3 — hardening + docs.** Cancel propagation end to end (stop
button → `410` → process killed → tool error → turn ends), output caps
tuned, `metis doctor` line for `serve_tools`, this doc marked shipped,
`local-bridge.md` cross-linked, `VISION.md` note under "what we won't
build" that bridge tools are a connector-shaped channel, not a runtime.

**Later, not v1.** A workflow's delegated step choosing "cloud step with
bridge tools" instead of "daemon-spawned agent". The engine stays
untouched until the chat path has proven the channel.

## Open questions

- **Cost attribution.** Delegation's selling point was the user's own
  subscription. Bridge tools spend the deployment's provider key on
  work that touches a personal machine. Fine for personal teams; a
  team-billed deployment may want a per-user switch.
- **Secrets in output.** `bash` output flows into the conversation and
  to the provider. Same exposure as any local agent, but the transcript
  is now stored server-side and shareable. Worth a line in the toggle's
  help text.
- **Multiple machines.** First `calls/next` with a matching `?project=`
  wins, per call. Two daemons mapping the same project could interleave
  calls of one turn across machines. Claim affinity per conversation
  (prefer `claimed_by` of the previous call) is a cheap server-side fix
  if it ever bites.
- **Builtin shadowing vs. `--tools`.** Decided by Phase 0.
