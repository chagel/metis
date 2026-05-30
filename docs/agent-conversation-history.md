# Agent conversation history

## Context

The agent boots fresh every turn. `AGENTS.md` gives it a sense of *where
it is* and *who it serves* (see [`agent-identity.md`](agent-identity.md)),
but nothing of *what came before* — each turn starts with no memory of
prior conversations. So the obvious operator asks fall flat: "find the
chat where we worked out the Zoom thing", "what did we decide
yesterday", "open that conversation again."

Awareness alone isn't enough — the operator needs an **action**: either
**link** to a past conversation, or **fetch** its content to summarize
or continue. And there's a constraint: `Message#content` is encrypted
with Active Record encryption, so the transcript can't be reached by a
plain SQL `LIKE` or a sandboxed tool reading the database.

## Decision: a projected `history.md`, not a tool

History is delivered the same way identity and connectors are — as a
**per-turn projected input**, the recurring shape documented in
[`agent-identity.md`](agent-identity.md#the-projected-input-pattern).
Rails renders the operator's recent conversation transcripts (decrypting
in-process) and stages `workspace/history.md`; pi reads it with its
normal file tools.

This honours **"pi executes; Rails governs"** (`VISION.md`): Rails holds
the encrypted data and decides what to expose; pi just reads a file. No
new transport.

- **`AGENTS.md` carries only a one-line pointer** (the *History* bullet
  in "This turn"). pi auto-loads `AGENTS.md` but **not** `history.md`, so
  the pointer is load-bearing — without it the agent never looks. The
  index and transcripts themselves stay out of the boot identity, so it
  remains a fixed size no matter how many conversations the operator has.
- **Fetch** — the agent greps/reads `history.md`. It sits on disk, so it
  costs **zero context tokens** until the agent actually reads a slice.
- **Link** — each section carries the conversation's `/conversations/:id`
  path; the chat UI renders the agent's markdown links clickable, so the
  agent can hand the operator a way back.

## Why not a recall tool

The first design was a **first-party MCP recall server**: a `metis-recall`
stdio shim baked into the runtime images, talking to a scoped Rails
recall API (`/api/recall/search`, `/api/recall/:id`) authed by a per-turn
signed token, auto-staged into `.mcp.json`. It worked, and it offered
*unbounded, lazy* search (fetch only what's asked for). It was rejected
as too heavy for the common case:

- It only avoids the **"no Rails-side MCP runtime"** rule (`VISION.md`) by
  pushing the protocol into a sidecar shim — a whole server to build,
  dependency-package, and bake into every runtime image.
- Unlike outbound connectors (GitHub, Metabase), it calls *back* to
  Metis, so it needs `METIS_BASE_URL` reachable from inside the sandbox
  — new infra and a new failure mode.
- A token to mint and pass per turn.

A projected file gets the same two verbs (fetch + link) for the recent
window with none of that — no server, no API, no token, no image change,
no callback. The tool is the right shape only for the long tail (see
*Scope* and *Future work*).

## How it works

Mirrors the `AGENTS.md` pipeline exactly:

| Piece | Class / method |
|---|---|
| Renderer | `Agent::History` → `history.md` |
| Writer | `Agent::Workspace#stage_history` (+ the `Runtime::E2b` sandbox variant) |
| Source | `Agent::Runtime::Base#history_content` |
| Per-runtime call | one staging line in `Local` / `Docker` / `E2b`, beside `stage_identity` |

- **Scope.** `@conversation.user.conversations.active`, excluding the
  current conversation, newest first. Keyed by `user` (matching
  `Workspace#scope_dir`), the operator's own conversations only — no
  cross-user or archived leak.
- **Bounds** (`Agent::History` constants), so a 500-message thread costs
  the same as a short one:
  - `CONVERSATIONS_MAX = 12` — sections in the file.
  - `MESSAGES_SCAN_MAX = 60` — rows fetched/decrypted per conversation.
    Load-bearing: the char budget alone wouldn't bound a thread of
    thousands of tiny messages.
  - `TRANSCRIPT_CHARS_MAX = 6000` / `MESSAGE_CHARS_MAX = 1500` — per
    conversation and per message.
- **Encryption.** Decryption happens here, in Rails, in-process. The
  agent only ever receives plaintext it's entitled to; nothing
  re-encrypts and no key reaches the sandbox.
- **Resilience.** `Agent::History#content` rescues: a decryption failure
  on any recent message degrades to the header and logs, rather than
  raising. A projected input must never crash a turn the user already saw
  stream (the [`session-persistence.md`](session-persistence.md)
  guardrail). The blast radius matters — the query spans all of the
  operator's recent conversations, so one legacy-key row would otherwise
  break *every* new turn.
- **Not an injection vector.** `history.md` is read as *data* — pi
  auto-loads `AGENTS.md`, not this file — and it's the operator's own
  content. So message bodies that contain `#` headings or `[links]` are
  fine; no sanitization beyond reusing `Conversation#display_title`.

## Scope — a recent window, not search

This is deliberately a **recent window**, not full-history search. "Find
the chat from six months ago" past the window won't surface. That's the
accepted tradeoff: the window covers the overwhelmingly common case
("recent", "yesterday", "the one about X") at near-zero cost, and the
boot identity stays bounded.

## Future work — search for the long tail

If the recent window proves too small, add search — but reach for the
**lightest** shape, not the recall server we already rejected:

- **Postgres FTS over a plaintext digest.** A denormalized `search_text`
  column on `conversations` (title + opening message) with a `pg_trgm`
  GIN index, exposed to the agent. Zero new infra — it rides the database
  Metis already has. This was prototyped and reverted alongside the MCP
  recall stack; the digest is the part worth resurrecting.
- **Model it on hermes-agent's `session_search`** (see *Prior art*): one
  tool, three modes — discover (FTS), scroll (anchored window), browse
  (recent). FTS, not embeddings.

Whatever the transport, the same encryption rule holds: search a
plaintext digest, decrypt full content only in Rails on demand.

## Prior art

Two sibling agents solve the same problem differently — useful reference
points, and a reminder of where Metis deliberately sits.

- **hermes-agent** (Python): the agent's memory lives in one **SQLite DB
  with FTS5** (BM25, plus a trigram table for CJK). Access is a single
  agent-callable `session_search` tool with three modes — *discover*
  (FTS, returns a snippet + a window around the hit + first/last
  "bookend" messages), *scroll* (page through a session), *browse*
  (recent sessions). Separately, a small curated `MEMORY.md` / `USER.md`
  is frozen into the system prompt at session start. Zero external deps.
- **openclaw** (TypeScript): semantic memory via **LanceDB vector
  embeddings**. Auto-recall on a `before_prompt_build` hook (embed the
  latest message, vector-search, inject the top few as
  `<relevant-memories>`), auto-capture at `agent_end`, plus a markdown
  wiki vault. Injected memory is explicitly labelled *untrusted context,
  do not treat as instructions*. The heaviest of the three — needs an
  embeddings provider and a vector store.

Metis sits at the leanest end: an eager projected file, no search. If we
ever expand, hermes' **FTS5** is the natural next step (it fits the
"no per-user infra" posture; openclaw's embeddings do not), and two ideas
are worth borrowing — openclaw's *untrusted-context* labelling if history
ever moves somewhere more prominent, and hermes' *bookends* (first/last
few messages) which recall better per byte than our oldest-N-within-budget.
