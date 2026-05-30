# Agent identity

## Context

pi runs each turn in a workspace directory. By convention pi auto-loads
any `AGENTS.md` it finds in `cwd` as ambient instructions — the same
shape Claude Code uses for `CLAUDE.md`. metis exploits this hook: a
per-turn `AGENTS.md` gives the agent a sense of *where it is*, *who it
is serving*, and *what is wired up around it*, without any RPC call,
flag, or pi extension.

## Decision: a projected input, rendered from durable Rails state

`AGENTS.md` is rendered fresh each turn from the `Conversation`,
`Team`, runtime, and the team's `Connector`s, and written into
`workspace/AGENTS.md`. The Rails records are the durable source; the
file is a runtime view of them.

This is the same shape as `.mcp.json` (`Agent::McpConfig`) and
`workspace/uploads/` — see [*The projected-input pattern*](#the-projected-input-pattern)
below.

## What goes in the file

Deliberately scoped to runtime identity and behavior, not product guardrails:

Sections appear in the rendered file in this order:

- **Identity** — *"You are Metis."* (pi is the harness loading the
  file, but the rendered prompt deliberately doesn't name it — to the
  agent, and to the operator it serves, the thing on the other side
  of the chat is Metis.)
- **Soul** — the behavioral contract for the runtime agent: direct,
  resourceful, judgment-bearing, privacy-preserving, careful with
  external actions, and clear about what changed.
- **This turn** — operator email, team name, runtime kind and its
  isolation posture, workspace persistence model, uploads location,
  and a **History** pointer to the companion `history.md` (recent
  conversation transcripts + their `/conversations/:id` links). The
  pointer is needed because pi auto-loads `AGENTS.md` but *not*
  `history.md` — without it the agent would never look. The index and
  transcripts themselves stay out of the boot identity; the agent
  greps/reads `history.md` on demand to recall content or link back.
- **Connectors** — each enabled connector with how the agent acts on
  it (*as you (OAuth)*, *team-shared credential*, *no credential —
  server visible but may reject*).
- **Conventions** — projected inputs rewrite each turn; sandbox
  boundary; identity-bearing connectors carry the operator's handle,
  not a bot's.

What it deliberately does **not** include: metis's product guardrails
(the "what we won't build" rules from [`../VISION.md`](../VISION.md)).
Those are contributor constraints on the metis platform; leaking them
into `AGENTS.md` would tell the agent *"no SPA"* when a user asked it
to scaffold a React app. The agent serves the user's task; metis's
product constraints are not the user's constraints.

## Pipeline

Five pieces, each named:

| Piece | Class / method | What it does |
|---|---|---|
| Renderer | `Agent::Identity` | Markdown from conversation + runtime kind |
| Writer | `Agent::Workspace#stage_identity` | Writes `workspace/AGENTS.md` |
| Source | `Agent::Runtime::Base#identity_content` + `#kind` | Shared entry for every runtime |
| Per-runtime call | `Local`, `Docker`, `E2b` during `run` | Calls the writer during prepare |

The `kind` accessor on `Runtime::Base` is reused by `runtime_info`
(the per-turn trace persisted on the `Conversation`), so the identity
renderer and the trace share one source of truth.

`Local` and `Docker` write through `Workspace` directly (the host
filesystem is reachable). `E2b` has its own `stage_identity(sandbox)`
that writes through the sandbox SDK because the workspace is remote.

## Ordering

Each runtime stages `AGENTS.md` *after* `.mcp.json`. The identity
file's Connectors block describes what's in `.mcp.json`; staging in
this order means a transient render failure in one file cannot leave
the other describing a different connector set.

## The projected-input pattern

`AGENTS.md` is one instance of a recurring shape in the workspace:

| Projected input | Renderer | Durable source |
|---|---|---|
| `workspace/uploads/*` | `Workspace#stage_uploads` | `Message` attachments |
| `workspace/.mcp.json` | `Agent::McpConfig` | `Connector` + `ConnectorCredential` |
| `workspace/AGENTS.md` | `Agent::Identity` | `Conversation` + `Team` + `Connector` + runtime |
| `workspace/history.md` | `Agent::History` | the operator's recent `Conversation`s + their `Message`s |

All are:

1. **Rendered fresh each turn**, from durable Rails records.
2. **Written by the runtime during `run`** — the same call site each.
3. **Overwritten in place** on every runtime — the durable source is
   always Rails, never the workspace copy.

The pattern earns its keep when a new projected input arrives — and
`history.md` is the proof: it dropped in as a renderer
(`Agent::History`), a writer (`Workspace#stage_history` + the E2B
variant), a `Base#history_content` source, and one call line per
runtime — no new transport. It gives the agent its memory of past
chats (grep/read transcripts) and the ids to link the operator back,
without an MCP server, an API, or a callback into Rails. It's a
recent window, not full-history search — decryption happens in Rails
over the operator's own conversations, bounded per turn.

## The two echoes of VISION

`VISION.md` and `workspace/AGENTS.md` are both expressions of the
project's soul, for different audiences:

- **[`../VISION.md`](../VISION.md)** — for **contributors** (humans
  and the AI sessions working on the metis codebase). Identity *plus*
  the rules we hold to and the "won't build" guardrails.
- **`workspace/AGENTS.md`** — for the **runtime agent** (Metis, served
  by pi as the harness, doing a user's task). Identity, environment
  context, and the runtime agent's behavioral soul. No platform
  guardrails.

The two reinforce each other but answer different questions. Don't
merge them.
