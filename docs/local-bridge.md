# Local bridge (design + build plan)

> Status: **design + build plan**, not yet implemented. Companion to
> [`workflows.md`](workflows.md) — the bridge is how a workflow's
> *implementation step* runs on the user's own machine instead of a
> Metis-operated sandbox.

A **bridge** lets a remote Metis workflow delegate a turn to a coding
agent running on the **user's own machine** — Claude Code, Codex, pi —
against their **real working copy**, with their real toolchain, env, and
(for Claude Code) their **own Claude subscription** rather than Metis's
API budget. Metis stays the governor: it sequences turns and gates; the
local agent only executes the turn.

## Why a fourth place to run

Metis already abstracts *where* the agent runs (`Runtime::Local`,
`Docker`, `E2b`, `Daytona` — see [`coding-runtime.md`](coding-runtime.md)).
All four are runtimes **Metis operates**. The implementation step has the
opposite requirements:

- It should edit the user's **actual repo** with their real tools, env,
  and credentials — not a fresh sandbox scope.
- Metis is in the cloud; the laptop is behind NAT. **Only the laptop can
  dial out.** Nothing inbound-to-laptop is on the table.
- The workflow invariant must survive: *the engine sequences turns +
  gates; the agent executes; Rails governs.* (`workflows.md`)

So the bridge is a new place the agent runs, reached over a channel the
laptop holds open. Conceptually it is **`Runtime::Local` executed on the
user's machine over a wire** — the laptop is the durable host filesystem.

## What the references teach (they answer different questions)

Two prior projects inform the shape, and the insight is that they answer
**different layers**:

- **[agentrq](https://github.com/agentrq/agentrq)** — the *deployment
  shape*. A remote task board hands work to a local agent: a per-workspace
  **MCP server** the agent connects to, **workspace-id + token** auth, SSE
  notifications, Claude Code native + Codex/Gemini via ACP/codex gateways.
  But control sits with the **agent** — it *pulls* (`getNextTask`) and
  self-manages. That inverts Metis's "Rails governs / engine sequences
  turns" invariant.
- **[ACP](https://agentclientprotocol.com)** (Agent Client Protocol) —
  the *agent-driving protocol*. JSON-RPC over stdio: `session/new`,
  `session/prompt`, `session/update` (streamed deltas/tool calls),
  `session/request_permission`, `fs/*`, `terminal/*`; a turn ends when the
  agent answers `session/prompt` with a **stop reason**. Control sits with
  the **client** — exactly what the workflow engine needs. This shape maps
  one-to-one onto Metis's `UiEvent` vocabulary.

**Metis wants agentrq's deployment shape with ACP's control model.** So:

- **Metis ↔ laptop** (over the network): a thin Metis-owned envelope,
  agentrq-style enrollment token, but **push/drive, not pull**.
- **laptop ↔ the local agent** (over stdio): **ACP** as the
  normalization layer — one bridge drives Claude Code, Codex, Gemini, and
  pi without N bespoke drivers.

## The one decision that shapes every payload

Where to cut the cloud/local serialization boundary:

- **(A) tunnel pi's native rpc frames** — pins the wire to pi's protocol,
  makes every `get_session_stats` a round-trip, and gives nothing for
  Claude Code / Codex.
- **(B) ship `Agent::UiEvent`s** — the laptop runs the full
  Runtime+Adapter and emits Metis's **canonical** vocabulary up the wire.
  `UiEvent` exists precisely so the UI "speaks one vocabulary regardless
  of which agent is running" (`app/services/agent/ui_event.rb`). The wire
  should speak it too. **This is the cut.**

Boundary B has a clean consequence: **the cloud-side seam is an *adapter*,
not a runtime.** The "where pi runs" concern moves entirely onto the
laptop; what remains cloud-side is purely "produce the `UiEvent` stream
from a remote source" — an adapter's job.

- **Cloud:** `Agent::Adapters.for(conversation)` returns
  `Adapters::Bridge` — it relays UiEvents off the wire and exposes the
  same post-turn reads `ChatJob` already calls. Zero new cloud-side
  translation.
- **Laptop:** the `metis-bridge` daemon owns the real Runtime+Adapter
  (pi via the existing logic; Claude Code / Codex via ACP→UiEvent). The
  wire is uniform across all of them.

## Architecture

```
Metis (cloud)
  WorkflowAdvanceJob → ChatJob → Adapters.for(conv) → Adapters::Bridge
        (step = a turn, unchanged)                         │
                                       Metis Bridge Protocol (Action Cable / WS)
                                                           │
                ───────────────── NAT boundary (laptop dials out) ─────────────────
                                                           │
  Laptop: `metis-bridge` daemon
     ├─ holds durable WS to Metis + presence heartbeat
     ├─ on dispatch{prompt, conv_id, settings}: drive the local agent
     │     ├─ pi:        `pi --mode rpc`     ← reuse pi-agent-rb framing   (v1)
     │     └─ others:    ACP over stdio      ← claude-code, codex, gemini  (Phase 3)
     ├─ translate the agent stream → Agent::UiEvent → stream back up
     ├─ working dir = the user's REAL repo (per-project binding)
     └─ session continuity: per-conversation, the agent's native resume
```

The streaming stack (`ChatJob`, `ChatBroadcaster`, `UiEvent`, the run UI)
and the workflow engine are **untouched**. A bridge turn is just another
producer of `UiEvent`s, and a bridge-backed step is still a turn, still
one `ChatJob`, still gated at its boundary.

## Wire protocol

### Envelope

Every frame, both directions:

```jsonc
{
  "v": 1,
  "conversation_id": 4821,     // correlation + continuity key
  "turn_token": "trn_9f3a…",   // one dispatch = one turn; idempotency + reconnect key
  "seq": 17,                   // monotonic per (turn_token, direction); gap detection
  "kind": "dispatch | event | turn_finished | permission_request | permission_response | control | heartbeat",
  "payload": { … }
}
```

`turn_token` makes dispatch idempotent (a re-delivered dispatch is a
no-op if that turn already ran). `seq` lets a reconnecting daemon resume
"after seq N", so a dropped socket mid-turn loses or duplicates nothing.

### Cloud → local: `dispatch`

Carries everything `Runtime::Base#run(pi_args:)` would have assembled
locally — prompt, continuity, settings, the per-turn projected inputs
Metis renders, and the credential env:

```jsonc
{
  "kind": "dispatch",
  "payload": {
    "assistant_message_id": 90211,        // correlate the stream; idempotency
    "prompt": "Implement the retry-budget cap described above…",
    "images": [{ "media_type": "image/png", "data": "<base64>" }],
    "files":  [{ "name": "spec.pdf", "url": "https://…signed…", "sha256": "…" }],

    "settings": { "provider": "anthropic", "model": "claude-opus-4-8" },
    //  or  { "provider": "local" }  → daemon uses the user's own pi/Claude login

    "continuity": {
      "backend_session_id": "pi_sess_77c…",  // nil on first turn; daemon resumes this
      "working_dir_binding": "metis/api"      // which local repo this run is bound to
    },

    // Metis renders these cloud-side today (identity_content, mcp_config).
    // Daemon stages them into a Metis-managed --session-dir, NOT over the user's files.
    "projected": {
      "agents_md": "<rendered AGENTS.md>",
      "mcp_json":  "<rendered .mcp.json>",
      "skills":    [{ "slug": "gws-gmail", "files": { "SKILL.md": "…" } }]
    },

    // sandbox_env(), projected from the operator's OauthGrants. Optional —
    // omit entirely to let the local agent use the user's own creds (the
    // Claude-subscription win). When present, short-lived per-turn bearers.
    "env": { "GH_TOKEN": "ghu_…", "GIT_AUTHOR_NAME": "chagel", "GIT_AUTHOR_EMAIL": "…" },

    "permission_policy": "auto"  // auto | forward  (ACP request_permission handling)
  }
}
```

The prompt, projected inputs, and env are **data the daemon applies** to
its local session — staged into a Metis-owned `--session-dir` so they
never clobber the user's repo. `working_dir_binding` is the user's real
checkout; the projected inputs live beside it, not on top of it.

### Local → cloud: the event stream

One frame per event — literally `UiEvent#to_h` on the wire, in order:

```jsonc
{ "kind": "event", "seq": 4,  "payload": { "type": "message_started",   "data": { "id": "msg_1", "role": "assistant" } } }
{ "kind": "event", "seq": 5,  "payload": { "type": "text_delta",        "data": { "id": "msg_1", "text": "Looking at the retry…" } } }
{ "kind": "event", "seq": 8,  "payload": { "type": "tool_call_started",  "data": { "tool_call_id": "tc_2", "name": "edit", "args": {…} } } }
{ "kind": "event", "seq": 12, "payload": { "type": "tool_call_finished", "data": { "tool_call_id": "tc_2", "output": "…", "is_error": false } } }
{ "kind": "event", "seq": 20, "payload": { "type": "message_finished",   "data": { "id": "msg_1", "content": "Done — capped at 5 retries." } } }
```

Cloud-side `Adapters::Bridge#stream` rehydrates each into a real
`Agent::UiEvent` and yields it to `ChatJob`, which broadcasts and buffers
exactly as for pi today. `native_ref` rides along untouched.

### Local → cloud: the terminal `turn_finished` frame

The frame with teeth — it carries everything `ChatJob` reads off the
adapter *after* the stream to persist usage onto the assistant `Message`:

```jsonc
{
  "kind": "turn_finished",
  "seq": 21,
  "payload": {
    "stop_reason": "end_turn",                      // ACP stop reason / pi agent_end
    "native_session_id": "pi_sess_77c…",            // → Conversation#backend_session_id
    "token_totals":  { "input": 18044, "output": 962, "cache_read": 15001 },
    "context_usage": { "used": 34000, "window": 200000 },
    "cost_total": 0.214,                            // USD; null when the agent omits it
    "model_info": { "provider": "anthropic", "model_key": "claude-opus-4-8" },
    "runtime_info": { "runtime": "bridge", "device": "macbook-pro", "agent": "claude-code" }
  }
}
```

`Adapters::Bridge` stashes this and exposes it via the **same method
names** the `Pi` adapter does (`#native_session_id`, `#token_totals`,
`#cost_total`, `#model_info`, `#runtime_info`) — so `ChatJob`'s
persistence and the Langfuse export path don't change a line. `#artifacts`
returns `[]` for bridge: the files live in the user's real repo, uncollected.

### Control & resilience frames

- **`permission_request` (local→cloud):** ACP `session/request_permission`
  surfaced up. Under `policy: auto` the daemon answers locally and never
  sends this; under `forward` it becomes a transient gate in the run UI
  and the cloud replies with a `permission_response` frame.
- **`heartbeat`:** daemon → cloud ~every 15s; drives `BridgeChannel`
  presence (the `awaiting_local` parking check).
- **Reconnect:** daemon sends `{kind:"control", op:"resume", turn_token,
  last_seq}`; cloud continues from `last_seq+1`. If the daemon died
  mid-turn and can't resume, the turn reaps like a stalled pi turn and
  re-dispatches on the next advance, resuming via `backend_session_id`.
- **Backpressure:** `text_delta` is the hot path; the daemon coalesces
  sub-frame deltas (as pi already batches) so the channel isn't flooded
  token-by-token.

### What crosses the boundary — and what doesn't

| Crosses cloud→local | Crosses local→cloud | Never crosses |
|---|---|---|
| prompt, settings, continuity id | UiEvent stream (canonical) | the user's source files (stay on laptop) |
| rendered AGENTS.md / .mcp.json / skills | usage: tokens, cost, model | the user's local provider login (when `provider:"local"`) |
| optional short-lived per-turn bearers | stop reason + native_session_id | raw pi rpc frames (translated at the edge) |

The wire is **the `UiEvent` vocabulary plus a dispatch frame and a
terminal stats frame** — nothing pi-specific, which is exactly what lets
the same channel carry Claude Code and Codex turns in Phase 3.

## Cloud-side shape

`Adapters::Bridge#stream` blocks the worker reading frames off the
channel — structurally identical to how `Adapters::Pi#stream` blocks
reading the subprocess today:

```ruby
def stream(input, images: [], files:, &block)
  dispatch!(input, images:, files:)              # send the dispatch frame
  BridgeChannel.events_for(turn_token).each do |frame|
    case frame.kind
    when :event              then block.call(UiEvent.new(frame[:type], data: frame[:data], native_ref: frame[:native_ref]))
    when :permission_request then handle_permission(frame)   # auto-ack, or forward as a transient gate
    when :turn_finished      then capture_terminal(frame); break
    when :error              then block.call(UiEvent.new(:error, data: { message: frame[:message] }))
    end
  end
ensure
  @session_terminal ||= :disconnected   # daemon dropped → reap path, resume next turn
end
```

Holding a worker thread blocked on the channel for the whole turn is the
**same shape** Metis already runs for every pi turn (the worker blocks on
the pi subprocess stream). Give bridge turns a dedicated Solid Queue queue
so they can't starve chat.

## Transport: Action Cable

Use **Action Cable** — Metis already runs it on Solid Cable, it's
bidirectional, and the laptop dialing out solves NAT for free.

- `BridgeChannel`, scoped to `team + enrolled device`. Presence via the
  subscription lifecycle drives the "is a local agent available?" check.
- **Down:** `dispatch`, `cancel`, `permission_response`.
- **Up:** `event`, `turn_finished`, `permission_request`, `heartbeat`,
  `control` (resume).

If per-token Action Cable chatter proves heavy, split the high-rate event
path to a streaming HTTP ingest endpoint and keep only control on the
cable. Start simple; measure first.

## Auth & enrollment

Borrow agentrq's token model, bootstrap with OAuth:

- `metis bridge login` on the laptop → device-code / browser flow →
  laptop receives a long-lived, **revocable per-user+team bridge token**
  stored in the OS keychain.
- Token scopes: open the channel, receive dispatches for that team's
  runs, post events. Revocable from `/settings/bridge`.
- **Provider keys:** the local agent uses the **user's own** credentials
  by default — Claude Code uses their Claude subscription, local pi uses
  their configured keys. Metis sends no provider key unless `env` is
  populated (configurable to pass a scoped one). Delegation moves spend
  off Metis's budget onto the user's plan.

## Workflow-engine integration

One genuinely new state. The laptop can be **offline** when a step is
ready — neither a failure nor an approval gate, but *waiting on
connectivity*:

- Add `awaiting_local` to `WorkflowRun#status` (sibling of
  `awaiting_approval`).
- `WorkflowAdvanceJob`, before a bridge-backed turn, checks
  `BridgeChannel` presence. Absent → park in `awaiting_local`, notify
  ("Your laptop is offline — connect `metis-bridge` to continue"). A
  `BridgeConnected` event re-triggers `WorkflowAdvanceJob`. Mirrors the
  existing gate mechanics.
- Present → dispatch and run the turn as a normal blocking `ChatJob`.

**Permissions — two layers, kept distinct:**

- *Workflow gate* (coarse, turn boundary): the human checkpoint Metis
  already has — review the diff before the next step or before push.
- *In-turn permission* (fine, per tool call): ACP
  `session/request_permission`. v1 bridge **auto-approves within a
  declared policy** (autonomy is the point of delegation); forwarding each
  tool call up to remote Metis would be slow and chatty. Configurable later.

## Session continuity & the real working copy

For the implementation step, the daemon runs the agent in the user's
**actual repo directory** (a per-device binding: Metis `Project` /
workflow-run → local path), not a fresh scope. The agent edits the real
working tree with the real toolchain; the workflow gate then lets the
human review the diff *in their own checkout* before it proceeds or
pushes. That is why local delegation beats the remote sandbox — and why
the bridge resembles `Runtime::Local` (laptop filesystem is durable)
rather than the sandbox runtimes. Continuity is the agent's native resume
(pi `--continue`, Claude Code session id) keyed off the conversation, in
that bound directory.

## VISION tension — flag it, don't bury it

[`VISION.md`](../VISION.md) holds **no second agent backend**, and
`Agent::Adapters` is "not a multi-backend seam." Driving the user's Claude
Code / Codex brushes against that. The argument it holds, to make on the PR:

1. These are the **user's tools on the user's machine** — a delegation /
   connector boundary, not a backend Metis hosts, ships, or operates.
2. **ACP keeps Metis at one normalized seam** — `Adapters::Bridge` relays
   one canonical vocabulary; the agent zoo lives *on the laptop* behind
   one protocol, not as N Metis backends.
3. **v1 is pi-only**, so the guardrail stays literally intact while the
   transport proves out; ACP multi-agent is an explicit, argued Phase 3.

## Build phases

Each phase is independently shippable and testable.

### Phase 0 — Enrollment + presence
- `Device` (or `Bridge`) model: team + user, hashed token, `last_seen_at`,
  `agent_kind`, working-dir bindings (jsonb).
- `BridgeChannel` with presence; `/settings/bridge` UI (enroll, list
  devices, revoke); `metis bridge login` device-code flow.
- **Test:** enrollment token issue/revoke; channel auth; presence
  transitions. No turns yet.

### Phase 1 — `Adapters::Bridge` (pi-only)
- `Adapters::Bridge#stream` + the dispatch / event / terminal frames; the
  `metis-bridge` daemon driving `pi --mode rpc` and emitting UiEvents.
- `Agent::Adapters.for` returns it when the conversation's runtime is
  `bridge`.
- **Test:** a one-shot bridge turn end-to-end through `ChatJob`; events
  render identically to a pi turn; usage persists from the terminal frame.

### Phase 2 — Workflow integration
- `awaiting_local` status + presence pre-check + reconnect re-trigger; a
  `runtime: bridge` step; the diff-review gate.
- **Test:** a gated bridge workflow parks when offline, resumes on
  connect, finishes; mid-turn disconnect reaps and re-dispatches.

### Phase 3 — ACP normalization
- ACP→`UiEvent` in the daemon; drive `claude-code-acp` / codex / gemini
  over stdio. Delivers "Claude Code, Codex, pi etc."
- **Test:** the same workflow runs unchanged against a non-pi agent.

### Phase 4 — Permission policy + notifications
- Configurable in-turn permission forwarding (`policy: forward`);
  offline / needs-you notifications (in-app, email, Slack).

## Alternative considered — agentrq-exact "pull" mode

Metis exposes a per-run MCP server; the user launches their own Claude
Code pointed at a Metis-rendered `.mcp.json` (Metis already renders one
per turn via `Agent::McpConfig`); the agent calls `getNextTask` /
`updateTaskStatus` / `reply`. **Cheap to add, rejected as the primary**
because it inverts control to the agent — breaking "engine sequences turns
/ Rails governs", losing uniform cost/token/transcript capture, and
forcing the user to manually launch + point the agent each time. A fine
*Mode B* for terminal-resident power users; not the spine.

## Open questions

- **Working-dir staging.** Metis's `AGENTS.md` next to the user's repo vs.
  a separate `--session-dir`: how aggressively to project Metis identity
  over a real checkout without surprising the user. Leaning separate
  session-dir, repo as cwd.
- **Multi-device.** One user, two laptops both enrolled — which receives
  the dispatch? Bind a run to the device that started it; fall back to
  any-present with a notice.
- **Event-path transport.** Action Cable for everything vs. HTTP ingest
  for the hot stream. Start all-cable; measure token-rate chatter.
- **Daemon distribution.** Ruby (reuse pi-agent-rb framing) vs. a
  cross-platform binary (Go/Rust, like agentrq). Ruby first for v1's
  pi-only path; revisit for Phase 3.
