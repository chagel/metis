# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. `AGENTS.md` at the repo root is a symlink to this file, so pi / codex sessions on this repo see the same context (loaded once — context-file loaders dedupe by resolved path).

## Read first

Before changing code, read [`VISION.md`](VISION.md) — what Metis is, the
rules we hold to, and what we explicitly **won't build**. Most of the
guardrails (no second agent backend, no CLI-as-connector, no Rails-side
MCP runtime, no polymorphic owner, no SPA, no per-user provider keys)
are inverses of temptations already present in this codebase. Honour
them, or argue them on a PR — don't drift into them.

## Overview

Metis is a Rails 8.1 web app (Ruby 4.0.5, PostgreSQL) that puts a chat UI in
front of an agent harness. v1 ships the **pi** backend, driven via the
`pi-agent-rb` gem. Hotwire (Turbo + Stimulus, importmap, Tailwind) renders the
live streaming chat; Devise handles auth.

## Commands

- `bin/dev` — run the app (Puma + Tailwind watch via foreman, port 3000)
- `bin/setup` — install deps, prepare the database
- `bin/rails test` — full test suite (Minitest)
- `bin/rails test test/services/agent/adapters/pi_test.rb:42` — single test by file:line
- `bin/rubocop` — lint (rubocop-rails-omakase house style)
- `bin/ci` — full CI pipeline: rubocop, bundler-audit, importmap audit, brakeman, tests, seed replant
- `bin/brakeman` / `bin/bundler-audit` — security scans

Run `bin/rubocop` and the relevant tests before committing.

## Critical dependency

The [`pi-agent-rb`](https://github.com/chagel/pi-agent-rb) gem drives
`pi --mode rpc` and is the only way the app talks to the pi agent.
It comes from rubygems via the `Gemfile` — no sibling checkout needed.

Active Record encryption is used for `Message#content` and `Message#reasoning`,
so encryption keys must be present in Rails credentials for any environment
that touches that model (including tests).

## Architecture

### The Agent service layer (`app/services/agent/`)

This is the core of the app. Metis runs on a single agent harness —
pi. The Agent layer separates two concerns:

1. **`Agent::Adapters`** — *the agent*. `Adapters.for(conversation)` builds
   the `Pi` adapter, which drives pi and translates its native event
   stream. `#stream(input)` yields events. This layer decouples the chat
   UI from pi's wire protocol; it is not a multi-backend seam.
2. **`Agent::Runtime`** — *where* the agent runs. `Runtime::Local` runs pi
   as a local subprocess, `Runtime::Docker` in a container, `Runtime::E2b`
   in an isolated microVM, `Runtime::Daytona` in a Daytona elastic sandbox.
   **`Runtime::Local` is not a security boundary** — pi has shell access.
   In production the `docker` runtime runs under **gVisor** (`runsc`, set by
   `METIS_DOCKER_RUNTIME`) as Docker-in-Docker from the containerized `job`
   worker on a single host; see `docs/coding-runtime.md`.

pi's native events are translated into **`Agent::UiEvent`**, a canonical
vocabulary (`text_delta`, `tool_call_started`, `turn_finished`, …) that
keeps the chat UI decoupled from pi's protocol. `UiEvent#native_ref`
keeps the raw payload for native view helpers.

### Request → response flow

(For the full turn-flow diagram, see `docs/architecture.md`.)

1. `MessagesController#create` creates a `user` message and a `pending`
   `assistant` message, then enqueues `ChatJob`.
2. `ChatJob#perform` runs one turn: it gets the adapter, calls `#stream`, and
   for each `UiEvent` hands it to `ChatBroadcaster` while buffering text.
3. `ChatBroadcaster` maps each `UiEvent` to a Turbo Stream broadcast on the
   conversation's stream.

**Division of labor:** `ChatJob` owns *persistence* (writing the final message
content + `streaming_status`); `ChatBroadcaster` owns the *live DOM*. Keep
these separate.

### Observability

Every finished turn persists its usage onto the assistant `Message`
(`input_tokens`, `output_tokens`, `cache_read_tokens`, `cost` USD,
`model_key`) — cost and model come straight from pi's `get_session_stats`
RPC, so Metis prices nothing itself. Optionally each turn is also exported as
an OpenTelemetry span to Langfuse (or any OTLP backend) via
`Observability::LangfuseTrace`, recorded from `ChatJob` after the turn. The
two layers are independent; OTLP export is off unless configured. See
`docs/observability.md`.

### Session continuity & storage

pi keeps a conversation's state in a scope directory (`Agent::Workspace`):
`sessions/` (its transcript), `workspace/` (its working files), and
`workspace/uploads/` (staged user uploads). How that scope survives between
turns is a **per-runtime concern** — see `docs/session-persistence.md`:

- `Runtime::Local` keeps the scope in a persistent host directory and
  relies on pi's own `--continue`.
- `Runtime::Docker` bind-mounts a persistent host directory into a
  disposable `--rm` container; the host filesystem is the durable source.
- `Runtime::E2b` uses E2B's native `pause`/`resume` by sandbox id —
  first turn creates and pauses, later turns resume the same microVM.
  `EvictPausedSandboxesJob` reaps long-idle sandboxes.
- `Runtime::Daytona` uses Daytona's `stop`/`start` by sandbox id (the
  pause/resume analog). Idle sandboxes are reaped by Daytona's native
  auto-stop/archive/delete intervals, set at create — no metis cron. The
  community SDK is a fork (`chagel/daytona-sdk`) that adds session stdin +
  follow-logs streaming; `DaytonaTransport` drives `pi --mode rpc` over a
  Daytona session.

There is **no archive**. `Agent::SessionArchive` was removed (commits
`349a0cb`, `c08eb79`); don't reintroduce a tar-to-Active-Storage path.

When a sandbox is reaped its working tree and pi transcript are gone, but the
`Message` history is not: if pi has no session to `--continue`, `Agent::Identity`
replays `Conversation#replayable_history` into `AGENTS.md` so the next turn
recovers prior context.

Per-turn projected inputs — `workspace/uploads/` (from `Message`
attachments), the rendered `workspace/.mcp.json`, the rendered
`workspace/AGENTS.md` (per-turn boot identity, see `docs/agent-identity.md`),
and the repo's `.pi/skills/` tree copied into `workspace/.pi/skills/` (pi
auto-discovers skills there) — are re-staged each turn even on a resumed
sandbox, so they never become durable state. Pause/restage failures are logged, never raised — a
storage failure must not crash a turn the user already saw stream.

### Credentials

pi's `--provider` / `--model` come from the conversation's `settings` (jsonb,
set by the new-chat composer) or fall back to `config.x.agent` deployment
defaults (`METIS_AGENT_PROVIDER` / `METIS_AGENT_MODEL`). The `--api-key` is the
per-provider deployment key in `config.x.agent.api_keys` — env var names mirror
pi's own conventions (https://pi.dev/docs/latest/providers): `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GEMINI_API_KEY` (note: not `GOOGLE_API_KEY` — pi's name),
`DEEPSEEK_API_KEY`, `XAI_API_KEY`, `GROQ_API_KEY`, etc. Provider API keys are a
shared, deployment-level resource — there are no per-user keys. All unset → pi
uses its own config. Full env-var table in `docs/configuration.md`.

### Connectors (MCP)

The agent reaches external systems (GitHub, Google, Linear, …) through
**MCP servers**, bridged into pi by the `pi-mcp-adapter` extension —
installed into each pi environment at setup/image-build time, not loaded
by Rails. See `docs/connectors.md` (and `docs/mcp-oauth-connectors.md` for
the OAuth/DCR flow).

- `Connector` + `ConnectorCredential` + `OauthGrant` model the
  per-team-and-user authorization state; `ConnectorsController` is the
  install/auth UI.
- `Agent::McpConfig` renders a `.mcp.json` per turn into the workspace
  from the team's enabled connectors. It is a projected input, never
  durable.
- OAuth flows live under `app/services/oauth_broker/`,
  `omniauth_connector.rb`, and the per-provider apps
  (`{github,google,linear}_app/`). Provider API keys for the LLM are
  separate from connector OAuth tokens — don't conflate them.

pi ships no MCP support of its own; the bridge-via-extension choice (vs.
pi's recommended skill+CLI path) is a load-bearing decision documented in
`docs/connectors.md` and `VISION.md`. Don't replace it with CLI wrappers.

### Skills

Skills are pi's native unit of recallable know-how (a `SKILL.md` + files,
auto-discovered from cwd). Metis layers two sources into
`workspace/.pi/skills/` per turn — the repo's versioned `.pi/skills/`
(`Agent::RepoSkills`) and the team's DB-authored `Skill` rows
(`belongs_to :team`), the latter installable from GitHub via
`Agent::SkillImporter` / `Agent::SkillMarketplace` and the
`/settings/skills` UI. Like uploads and `.mcp.json`, this tree is a
projected input — rewritten each turn, never durable. See `docs/skills.md`.

## Conventions

- **Tenancy is `Team`-only.** Every ownable resource (`Conversation`,
  `Connector`, future projects/skills) has `belongs_to :team`. A user's
  personal account is a team of one. Authorization is always
  `resource.team.members.include?(user)` — no `User`-vs-`Team` branch,
  no polymorphic `owner`. See `docs/tenancy.md` and `docs/teams.md`.
- Models use integer enums: `Conversation#backend`, `Message#role`,
  `Message#streaming_status`.
- Test parallelization is gated behind a high threshold (`threshold: 5000`
  in `test/test_helper.rb`) on purpose — parallel workers share the
  filesystem and race on per-conversation scratch paths.
- Background jobs run on Solid Queue (in production); Solid Cache/Cable back
  Rails cache and Action Cable.

## Code style

- **Comments — default to none.** Write one only when the *why* isn't
  obvious from the code: a hidden constraint, an external-API quirk, a
  public-API contract another file consumes, a magic constant, or a
  ticketed `TODO(FLA-123)`. Don't restate the code, justify the design,
  narrate sibling files, or label sections (`# === helpers ===`).
  Sentence case, single `#`, ≤2 lines. **Earn-its-place test:** delete
  the comment, re-read the code — if no information is lost, it was
  noise.
- **Models**: ordering is validations → associations → scopes → methods.
  Use `store_accessor` for jsonb-backed flexible fields. Scopes for
  every common query — no inline `where` chains in controllers or jobs.
- **Controllers**: strong params for every create/update; delegate
  business logic to services or model methods; `respond_to` with both
  `turbo_stream` and `html` for dual-format actions.
- **Jobs**: rescue, mark the tracking record `failed`, and broadcast —
  don't let the UI hang on a silent error. (`ChatJob` is the canonical
  example.)
