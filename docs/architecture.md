# Architecture

One turn flows from the browser down to pi and streams back up, live:

```
   Browser · Hotwire chat UI
      │  new message                  ▲  Turbo Stream
      ▼                               │  (live text, tool calls)
   MessagesController                 ChatBroadcaster
      │  persist + enqueue            ▲  UiEvent
      ▼                               │
   ChatJob · Solid Queue ─────────────┘
      │  one turn — stream UiEvents, persist the final message
      ▼
   Agent service layer  (app/services/agent/)
      ├─ Adapters::Pi   the agent — drives pi, native events → UiEvent
      └─ Runtime        where pi runs — Local · Docker (gVisor) · E2b · Daytona
      │
      ▼  pi-agent-rb · JSONL over stdio
   pi --mode rpc · the agent harness — LLM loop, tools, extensions

   Persistence
      ├─ PostgreSQL       conversations & messages
      └─ Workspace fs     Docker bind mount · E2b/Daytona pause/resume · Local host
```

The core is the **Agent service layer** (`app/services/agent/`): an
*adapter* drives pi and translates its native event stream into a
canonical `UiEvent` vocabulary, and a *runtime* decides where pi runs.
[`CLAUDE.md`](../CLAUDE.md) is the fuller tour.

Per-area docs:

- [`tenancy.md`](tenancy.md) — `Team`-only ownership.
- [`connectors.md`](connectors.md) — MCP connectors and OAuth.
- [`session-persistence.md`](session-persistence.md) — how a conversation's
  scope survives between turns, per runtime.
- [`coding-runtime.md`](coding-runtime.md) — the `local` / `docker` / `e2b` / `daytona` runtimes (prod: `docker` under gVisor).
- [`agent-identity.md`](agent-identity.md) — the per-turn `AGENTS.md`.
- [`skills.md`](skills.md) — team-authored skills.
- [`configuration.md`](configuration.md) — runtimes, providers, environment.
