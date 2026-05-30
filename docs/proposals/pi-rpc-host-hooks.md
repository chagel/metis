# Proposal (upstream, pi-mono): expose AgentHarness hooks to RPC hosts

Status: draft / not yet filed. Target: [`badlogic/pi-mono`](https://github.com/badlogic/pi-mono).

This is **Metis's upstream ask of pi**, kept here as the backing rationale.
It is not a Metis feature — Metis can't build it. It records why we want
the primitive, the concrete shape, and how to file it under pi's strict
contribution gate. The short, fileable version lives at the bottom; this
long form is the detail to share only after a maintainer engages.

## Why Metis wants this

Metis embeds pi via `pi --mode rpc` (through `pi-agent-rb`) in a
multi-user, server-side, sandboxed app. Rails is the natural owner of
what the agent needs in context — per-user conversation history,
connector credentials, live business data — and of the encryption keys
(`Message#content` is encrypted; only Rails can decrypt). The principle
is "pi executes; Rails governs" (see `VISION.md`).

Today the only ways Rails can put context in front of the agent are:

- **Static `cwd` files** (`AGENTS.md`, and our `history.md` — see
  [`docs/agent-conversation-history.md`](../agent-conversation-history.md)).
  Fixed per turn; can't react to what the agent is doing mid-turn; no
  tool path.
- **Ship a TS extension into the runtime** that subscribes to pi's hooks
  and then calls back to Rails over HTTP. That re-introduces exactly the
  costs we rejected for the recall MCP shim: credential plumbing, network
  reachability from a sandbox back to Rails, and a versioned TS artifact
  baked into every runtime image.

Yet pi and Rails already share a bidirectional pipe, and
`extension_ui_request`/`extension_ui_response` already proves synchronous
pi→host→pi round-trips work over it. pi already emits the hooks we want
internally. The missing piece is letting the RPC *host* register as a
participant. That is a small generalization of machinery that exists.

## What exists in pi today (verified against pi-mono @ v0.78.0)

- **Harness hooks** — `packages/agent/docs/hooks.md` defines
  `AgentHarnessHooks` with `on(type, handler)`, typed mutation results,
  and sequential chaining: `context` (`{messages}`), `before_agent_start`
  (`{messages, systemPrompt}`), `before_provider_payload` (`{payload}`),
  `tool_call` (`{block, reason}`), `tool_result`
  (`{content, details, isError}`), `session_before_*` (`{cancel}`).
- **Extension API** — `packages/coding-agent/src/core/extensions/` exposes
  the same events plus `registerTool(...)`. In-process (TypeScript) only.
- **RPC surface** — `packages/coding-agent/src/modes/rpc/rpc-types.ts`:
  `RpcCommand` (host->pi: `prompt`/`steer`/`compact`/model/bash/session/
  `get_messages`/...), responses + the event stream (pi->host), and
  `extension_ui_request`/`extension_ui_response` — the one pi->host
  callback that expects a response.

**The gap:** the rich hooks and tool registration are reachable only by
in-process TS extensions. The RPC host has no way to participate in a
hook's semantics or to register a tool. `InputSource = "rpc"` only tags
where input arrived.

## Proposal

Two additive capabilities, both id-correlated request/response over the
existing JSONL stream, modeled exactly on `extension_ui`. Both opt-in: a
host that subscribes to nothing sees no behavior or latency change. No
new hook semantics — the RPC bridge only forwards `emit()` to the host
and applies the returned result, so a host handler slots into the
chaining model in `hooks.md` like any other `on(type, handler)`.

### 1. Host hooks

Subscribe (host->pi):

```jsonc
{ "type": "subscribe_hooks", "events": ["context", "tool_call", "before_agent_start"], "timeoutMs": 5000 }
```

Hook request (pi->host), mirroring `extension_ui_request`:

```jsonc
{ "type": "hook_request", "id": "hook-1", "event": "context",
  "payload": { "messages": [ /* AgentMessage[] */ ] } }
```

Hook response (host->pi), mirroring `extension_ui_response`; `result` is
the hook's existing result type from `hooks.md`:

```jsonc
// transform
{ "type": "hook_response", "id": "hook-1", "result": { "messages": [ /* ... */ ] } }
// passthrough (no change)
{ "type": "hook_response", "id": "hook-1", "result": null }
// tool_call: { "result": { "block": true, "reason": "policy: external send needs approval" } }
```

Bridge inside pi (one handler per subscribed event):

```ts
for (const event of subscribedEvents) {
  hooks.on(event, async (e) => {
    const id = nextId();
    output({ type: "hook_request", id, event, payload: project(e) });
    return await awaitHookResponse(id, timeoutMs); // -> ResultOf<e>, or undefined on timeout
  });
}
```

On timeout, fall back to passthrough (the `extension_ui` auto-cancel
precedent).

### 2. Host-defined tools

`hooks.md` keeps tools as a registry, not a hook, so this is a sibling
channel, not part of `emit()`.

Register (host->pi, at session start):

```jsonc
{ "type": "register_tools", "tools": [
  { "name": "recall_conversation", "description": "Search the operator's past conversations.",
    "parameters": { /* JSON Schema */ } } ] }
```

Invocation (pi->host) when the model calls the tool:

```jsonc
{ "type": "tool_call_request", "id": "call-7", "name": "recall_conversation",
  "arguments": { "query": "zoom in thailand" } }
```

Result (host->pi):

```jsonc
{ "type": "tool_call_response", "id": "call-7",
  "content": "Found 2 conversations...", "isError": false, "details": { /* optional */ } }
```

The existing `registerTool` registry, with execution dispatched over RPC
instead of run in-process. Structurally identical to `extension_ui`
(register -> request -> response).

## Design alignment

- No new hook semantics; reuses `hooks.md` event/result shapes.
- Composes with extensions: host handlers and in-process extension
  handlers coexist in the same chain (ordering to be defined; suggest
  host runs after loaded extensions, or expose a priority).
- Mirrors `extension_ui`, so existing clients (`pi-agent-rb` and others)
  reuse their `extension_ui` plumbing.
- Opt-in and backward compatible; no latency for unsubscribed events.

## Minimal first cut

1. `context` host hook (highest value: dynamic context injection).
2. Host tools (`register_tools` + `tool_call_request`/`response`).

`tool_call` / `before_agent_start` / `session_before_*` can follow once
the bridge pattern is proven.

## Alternatives considered

- **TS bridge extension calling the host over HTTP** — works, but pushes
  credential plumbing, sandbox reachability, and a versioned TS artifact
  onto every embedder; defeats the point for a host that already drives
  an RPC pipe.
- **Static `cwd` files only** — can't react mid-turn; no tool path.
- **Host-owned MCP server** — heavier (separate server + transport) than
  reusing the existing pipe.

## Open questions for maintainers

- Do you want this in core (it is inherently an RPC-surface change an
  extension cannot make), or do you prefer hosts ship a bridge extension?
- Ordering between host hooks and in-process extension handlers?
- One `subscribe_hooks` timeout vs per-event timeout?
- `register_tools` startup-only, or re-registerable mid-session?

---

## Filing under pi's contribution gate (read before posting)

pi's `CONTRIBUTING.md` is strict. Do not skip:

- **New contributors are auto-closed by default.** A PR requires a prior
  `lgtm` maintainer reply. The only entry point is a **Contribution
  Proposal issue** (`.github/ISSUE_TEMPLATE/contribution.yml`) ->
  maintainer reopens / `lgtm` -> then a PR is allowed.
- **One screen, own voice.** They explicitly distrust "polished
  AI-generated issues." Post the short version below in your own words —
  not this long doc. Share this doc only after a maintainer engages.
- **You must understand the change.** Own it.
- **Weekend rule:** issues Fri-Sun are auto-closed and skipped from the
  Monday queue. File Mon-Thu, or raise on Discord first
  (https://discord.com/invite/3cU7Bz4UPx) — their preferred venue for
  design discussion.
- **Hygiene:** no emojis anywhere; do not edit `CHANGELOG.md`; if
  implementing, erasable-TS only and run `npm run check` + `./test.sh`;
  an AI-posted comment needs their AI-disclaimer line (cleaner to post in
  your own voice).

Recommended sequence: Discord to socialize -> Mon-Thu Contribution
Proposal issue (say you'll implement) -> on `lgtm`, implement the minimal
version (`context` hook + host tools) with tests -> PR.

### Short version to post (Contribution Proposal template)

**What do you want to change?**
Let a `--mode rpc` host opt into a subset of `AgentHarness` hooks
(starting with `context`) and register host-side tools, using the same
id-correlated request/response the RPC mode already uses for
`extension_ui`.

**Why?**
I'm embedding pi via `--mode rpc` in a multi-user server app, where the
host owns what the agent needs in context (per-user history, credentials,
live state). Today the host can only push commands and observe events —
`context`/`tool_call`/`registerTool` are reachable only from in-process
TS extensions. Getting host-owned context or tools in means shipping a TS
extension into the runtime that calls back to the host over HTTP: extra
credential plumbing and a versioned artifact, when the host already has a
bidirectional RPC pipe that does host callbacks (`extension_ui`). I want
the host to plug into context without that sidecar.

**How? (optional)**
Generalize `extension_ui_request`/`extension_ui_response` into a host-hook
channel: `subscribe_hooks {events}` -> pi emits
`hook_request {id, event, payload}` -> host returns
`hook_response {id, result}`, where `result` is the event's existing
result type from `hooks.md` (`context` -> `{messages}`). Same shape for
host tools: `register_tools` + `tool_call_request`/`tool_call_response`.
Additive, opt-in, no new hook semantics — just an RPC adapter that
registers `hooks.on(event, ...)`. Is this something you'd want in core
(it's inherently an RPC-surface change), or would you rather hosts ship a
bridge extension? Happy to implement the minimal version with tests if
the shape's acceptable.
