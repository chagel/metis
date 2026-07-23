---
name: understanding-metis
description: Architectural knowledge of the Metis codebase (chagel/metis) — a Rails 8.1 chat UI in front of the pi agent harness. Use ONLY when working on the Metis repository.
version: 10
---

# Metis Architecture

Rails 8.1 web app (Ruby 4.0.5, PostgreSQL) that puts a streaming chat
UI in front of an agent harness. v1 ships the **pi** backend, driven
via the `pi-agent-rb` gem. Hotwire (Turbo + Stimulus, importmap,
Tailwind) renders the live chat; Devise + OmniAuth handles auth.

## Read first

[`VISION.md`](../../../VISION.md) lists the project's load-bearing
guardrails — the things Metis explicitly **won't build** (no second
agent backend, no CLI-as-connector, no Rails-side MCP runtime, no
polymorphic owner, no SPA, no per-user provider keys). Honor them or
argue them on a PR.

## Two axes of composition

Everything in the agent service layer (`app/services/agent/`) sits on
two orthogonal axes:

1. **`Agent::Adapters`** — *the agent*. `Adapters.for(conversation)`
   builds the `Pi` adapter, which drives pi via `pi-agent-rb` and
   translates its native event stream. Decouples the chat UI from
   pi's wire protocol — **not** a multi-backend seam.
2. **`Agent::Runtime`** — *where* the agent runs. `Runtime::Local`
   runs pi as a host subprocess; `Runtime::Docker` runs it in a
   `--rm` container with a bind-mounted workspace (in production under
   **gVisor** / `runsc`, Docker-in-Docker from the `job` worker);
   `Runtime::E2b` runs it in an E2B microVM that pauses + resumes by
   sandbox id; `Runtime::Daytona` runs it in a Daytona elastic sandbox
   that stops + starts by sandbox id; `Runtime::Microsandbox` runs it
   in a self-hosted libkrun microVM (in-process via the optional
   `microsandbox-rb` gem — no daemon). `Runtime::Local` is **not** a
   security boundary — pi has shell access to the host.

Pi's native events translate into `Agent::UiEvent` — a canonical
vocabulary (`text_delta`, `tool_call_started`, `turn_finished`, …)
that keeps the UI decoupled from pi's protocol. `UiEvent#native_ref`
preserves the raw payload for backend-aware view helpers.

## Request → response flow

```
ConversationTurn.start          ← the single place a turn is born
  (callers: composer via Composing concern, workflow engine)
  → creates user Message (kind: chat | step_prompt | …) + pending assistant Message
  → enqueues ChatJob
ChatJob#perform
  → Agent::Adapters.for(conversation).stream(input) { |UiEvent| ... }
    each event → ChatBroadcaster.handle(event)  [live DOM]
    text/reasoning/tool_calls also buffered locally
  → on turn end, writes final Message (content, tool_calls, status, tokens)
  → persists session id, agent_model, runtime_info, context_usage
  → cancellation: polled every 15 events vs Conversation#cancel_requested_at
  → WorkflowRun.signal_turn_finished — no-op for a normal chat, re-enqueues
    WorkflowAdvanceJob when a workflow run drives the conversation
```

**Division of labor**: `ChatJob` owns *persistence* (writing the final
message content + `streaming_status`); `ChatBroadcaster` owns the *live
DOM*. Keep these separate.

## Observability

Each finished turn persists its usage onto the assistant `Message`:
`input_tokens`, `output_tokens`, `cache_read_tokens`, `cost` (USD), and
`model_key` (the model that served it). Cost and model come straight from
pi's `get_session_stats` RPC — Metis prices nothing itself. Optionally each
turn is also exported as an OpenTelemetry span to Langfuse (or any OTLP
backend) via `Observability::LangfuseTrace`, recorded from `ChatJob` after
the turn. The two layers are independent; OTLP export is off unless
configured.

## Session continuity & storage

Pi keeps a conversation's state in a scope directory
(`Agent::Workspace`): `sessions/` (its transcript), `workspace/`
(its working files), and `workspace/uploads/` (staged user uploads).
How that scope survives between turns is a **per-runtime concern** —
see [`session-persistence.md`](../../../docs/session-persistence.md):

- `Runtime::Local` keeps the scope under `storage/agent/` and relies
  on pi's own `--continue`.
- `Runtime::Docker` bind-mounts the host scope into a disposable
  `--rm` container; the host filesystem is the durable source. That
  host root is a reclaimable hot cache: `EvictDockerWorkspacesJob`
  warm-evicts idle scopes' `workspace/` (keeping `sessions/`, so pi
  still `--continue`s), and destroying a conversation removes the
  whole scope via `CleanupPersistentWorkspaceJob`.
- `Runtime::E2b` uses E2B's native `pause`/`resume` by sandbox id —
  first turn creates and pauses, later turns resume the same microVM.
  `EvictPausedSandboxesJob` reaps long-idle sandboxes (E2B does not
  auto-clean paused ones).
- `Runtime::Daytona` uses Daytona's `stop`/`start` by sandbox id (the
  pause/resume analog). Idle sandboxes are reaped by Daytona's own
  auto-stop/archive/delete intervals set at create — no metis cron. The
  community SDK is a fork (`chagel/daytona-sdk`) adding session stdin +
  follow-logs streaming; `DaytonaTransport` drives `pi --mode rpc`.
- `Runtime::Microsandbox` bind-mounts the persistent host scope into a
  disposable libkrun microVM (fresh each turn, `ephemeral`) — the
  Docker persistence shape at VM-grade isolation, self-hosted and
  in-process; `MicrosandboxTransport` drives `pi --mode rpc` over
  `exec_stream`. Nothing to pause, resume, or evict.

There is **no archive**. `Agent::SessionArchive` was removed; don't
reintroduce a tar-to-Active-Storage path.

When a sandbox is reaped, the working tree and pi's transcript are gone but
the `Message` history is not. The next turn rehydrates context: if pi has no
session to `--continue`, `Agent::Identity` renders
`Conversation#replayable_history` into `AGENTS.md` so the agent regains the
prior conversation.

### Projected inputs (re-staged each turn)

| Path | Source |
|---|---|
| `workspace/uploads/*` | `Message` attachments (Active Storage) |
| `workspace/.mcp.json` | `Connector` + `ConnectorCredential` (`Agent::McpConfig`) |
| `workspace/AGENTS.md` | `Conversation` + `Team` + runtime (`Agent::Identity`) |
| `workspace/.pi/skills/*` | Repo's `.pi/skills/` tree + team's enabled `Skill` rows, layered into one tree by `Workspace#stage_skills` |

Each is read straight from its durable source at the start of every
turn and **overwritten in place** — pause/restage failures are
logged, never raised; a storage hiccup must not crash a turn the user
already saw stream.

## Tenancy

`Team`-only (`docs/tenancy.md`). Every ownable resource
(`Conversation`, `Connector`, `Skill`, `Project`) has `belongs_to :team`.
A user's personal account is a team of one, auto-created at signup.
Authorization is always `resource.team.members.include?(user)` — no
`User`-vs-`Team` branch, no polymorphic `owner`.

## Projects

A `Project` is a user-managed R&D context owned by a team — a `name`, a
freeform `about`, and an `external_refs` jsonb binding it to external
systems (`store_accessor :github_repo, :linear_project`; inbound webhook
events route to a project through these). A `Conversation` optionally
attaches to one, and the team's project catalog is rendered into per-turn
`AGENTS.md` so the agent can look one up by name. A project with active
runs can't be deleted (`forbid_active_runs`).

## Workflows & the local bridge

A `Workflow` (team-owned, jsonb `steps`) launches a `WorkflowRun` — one
backing `Conversation`, one `Task` per step (`WorkflowRun.start`, also
usable ad-hoc with `workflow: nil`). A run **requires a project**:
`WorkflowRun.start` takes `project:` and raises without one, and a project
with active runs can't be deleted (daemons claim delegated steps per
project — a project-less run could never be auto-claimed). The run `input`
is restated into every step's prompt, not just the first, and a multi-step
run also prepends a self-orientation header to each step prompt
(`WorkflowAdvanceJob#workflow_header`, omitted for a single-step run) so a
turn knows which step it is and what came before. A run can also be
launched **from inside a chat** — the agent calls the `metis_start_workflow`
extension tool (routed over pi's Extension UI channel via
`Agent::HostBridge`), and `Agent::WorkflowHandoff` turns the call into a
`WorkflowRun.start` (folding the chat transcript + a note + attachment
links into the run `input`), queued for a human `launch!`.
`WorkflowAdvanceJob` is the engine: it starts each step as a normal turn
via `ConversationTurn.start` (the step prompt becomes a `kind: step_prompt`
user message), and parks the run when human input is needed:

- `awaiting_approval` — the step's `gate` is `approval`; a member
  approves, requests changes (folds feedback into a revision turn), or
  rejects in the run UI.
- `awaiting_local` — the step is **delegated** (`Task#delegated`):
  dispatched to the user's own machine instead of running as a cloud
  turn.

Run visibility is the launcher's choice (`Conversation#visibility`,
personal / team): a team-visible run is openable by any member, who can
act on its gates and claim its local steps. `WorkflowBroadcaster` owns
the run's live DOM (timeline, gate panel, sidebar "Needs you" pin).

The **local bridge** is the delegation transport — a pull API under
`app/controllers/api/bridge/`, bearer-authed by a per-user token
(`User#bridge_token_digest`, generated in account settings; every
authed call stamps `bridge_seen_at` as a presence heartbeat). Three
surfaces, same API: REST (`/api/bridge/tasks`, claim / progress /
result), a hosted streamable-HTTP MCP server (`/api/bridge/mcp` —
`list_tasks`, `get_next_task`, `report_progress`, `submit_result`), and
a self-documenting skill endpoint (`/api/bridge/skill`). A local agent
claims a dispatched task (`Task.claim_next_for` — FIFO,
`FOR UPDATE SKIP LOCKED`; tasks quote Sentry-style refs like
`CHEESE-1G` derived from the id), works it in the user's own checkout
with the user's own credentials, and reports a result; the run resumes.
Metis never drives the user's machine — the local agent pulls. The
unattended client is a stdlib-only **Go daemon** (`clients/metis/`,
its own `go test` suite + CI) that polls one or more deployments and
runs Claude Code / pi / Codex headless in per-task git worktrees, up to
`max_workers` concurrently.

A conversation can also be **forked** from any assistant turn
(`Agent::ConversationForker`; `Conversation#forked_from_message`).

### Run board

The cross-project run board (`BoardController` → `board#index`,
`board#actors`) is a **read-only projection** — it never writes run or
task state. Two table-less read models back it, both drawing from the
same `Conversation.board_visible(user, scope, project_ids)` scope so the
grid and the actor rail can't diverge:

- **`Board`** — visible `WorkflowRun`s grouped into five status columns
  (`queued` / `running` / `awaiting_approval` / `awaiting_local` / `done`,
  mapping the eight run statuses) within per-project swimlanes. Filters: `scope`
  (`all` / `mine` / `needs_me`), a project-id set (intersected against
  the team's own projects so a forged id can't widen it), and a Done
  recency window (`24h` / `7d` / `2w` / `1m` / `all`). Active-status runs
  always show; terminal runs are bounded by the window.
- **`BoardPresence`** — the actor rail: team `Person`s (those with an
  open gate first) and `Machine`s (members who minted a bridge token,
  online ones first). Presence is deliberately coarse — one heartbeat
  per bridge session (`User#bridge_seen_at`, 2-minute online window), so
  it shows only online vs stale, never worker counts. The roster stays
  team-wide; only what each actor is *shown doing* (gates, claimed-task
  refs) narrows to the active filters. `board#actors` is polled (~20s) so
  a machine ages online→stale without a page reload.

## Routines

A `Routine` (team-owned) is a saved prompt that fires on its own — on a
cron `schedule` (parsed with **fugit**, IANA zone embedded as the
trailing field) or a `webhook` event — each fire running as a normal
turn via `ConversationTurn.start` (tagged `Conversation#routine_id`). It
has no engine of its own and is **not** bound to a workflow: the prompt
is generic and may itself call `metis_start_workflow`. Three firing
paths — `RoutineSchedulerJob` (every minute, over `Routine.due`),
`Routine::EventDispatcher` (off `WebhookEvent#after_create_commit`, the
trigger half of the collect-then-trigger webhook split), and manual
`run`. Managed from the `/settings/routines` UI and from chat
(`Agent::RoutineManager` over `Agent::HostBridge`; agent-created
routines start disabled).

## Credentials & connectors

Two distinct surfaces, separately governed:

1. **LLM provider keys** — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
   `GEMINI_API_KEY` (pi's name for Google — not `GOOGLE_API_KEY`),
   `DEEPSEEK_API_KEY`, `XAI_API_KEY`, … Shared, deployment-level
   (loaded from `config.x.agent.api_keys`). **No per-user provider
   keys.** `Pi#credential_args` resolves the conversation's
   provider/model (per-conversation `settings` overriding
   `config.x.agent` defaults) and matches the env-loaded key.
2. **Connector OAuth + tokens** — per-user, per-provider. One
   `OauthGrant` per `(user, provider)` holds tokens + scope union;
   `ConnectorCredential` rows are presence markers, **not** the
   token source. `Agent::McpConfig` resolves a bearer per connector
   per turn via `OauthBroker.access_token_for(grant)`.
3. **GitHub App installation token** (`github_bot`) — team-wide, not
   per-user. When the deployment is App-auth configured and an admin
   enables it on the team's github connector (`Connector#bot_enabled`,
   `bot_installation_id` — a per-team installation picker), `McpConfig`
   stages a second `github_bot` server bearing a minted installation
   token so the agent can act as `<slug>[bot]`. Off by default; the
   token is installation-wide.

Connectors (`Connector` + `ConnectorCredential` + `OauthGrant`) hold
the team's + members' authorization state. The agent reaches external
systems through one of two transports:

- **MCP** (default) — `Connector#transport` is `stdio` or `http`, and
  the connector is rendered into per-turn `.mcp.json` by
  `Agent::McpConfig`. pi reads it via the `pi-mcp-adapter` extension,
  installed at setup/image-build time, not loaded by Rails. Shipped:
  **GitHub**, **Linear**.
- **CLI + skill** (documented fallback) — `Connector#transport` is
  `cli`; the connector is *omitted* from `.mcp.json` and instead
  authorizes a CLI on PATH via `Runtime::Base#sandbox_env`. Shipped:
  **Google Workspace** (Gmail / Calendar / Drive) over the `gws` CLI,
  used because Google's MCP path excludes personal accounts. The CLI
  fallback has real cost (vendored skill files drift, catalog
  branches on transport) — bar is "MCP unavailable or gated", not
  "CLI feels easier".

The bridge-via-extension choice (vs. pi's recommended skill+CLI path
for *everything*) is a load-bearing decision in `VISION.md`. Don't
collapse the MCP path into CLI wrappers.

The user's GitHub bearer is also injected as `GH_TOKEN` and the
Google Workspace token as `GOOGLE_WORKSPACE_CLI_TOKEN` into the
sandbox environment (sandboxed runtimes only — see
`Runtime::Base#sandbox_env`), together with git author/committer
identity, so the agent's commits carry the operator's handle.

## Email

Transactional email (invitations, password reset) goes out through the
transport `METIS_MAIL_DELIVERY` names — production defaults to `smtp`
(`Delivery::SmtpSettings.from_env` builds `smtp_settings` from `SMTP_*`
env vars; `SMTP_HOST` accepted as an alias for `SMTP_ADDRESS`),
development to `test`; `cloudflare` selects `Delivery::Cloudflare`,
Cloudflare Email Service's REST client (`CLOUDFLARE_ACCOUNT_ID` +
`CLOUDFLARE_EMAIL_API_TOKEN`). `METIS_MAIL_FROM` is the sender. Sends
run through `MailDeliveryJob`, which retries transient failures. Mail
credentials are deployment-level ENV — never per-user.

## Conventions

- Models use integer enums: `Conversation#visibility`, `Message#role`,
  `Message#streaming_status`, `Message#kind`, `Connector#transport`
  (stdio / http / cli), `Membership#role`, `Invitation#role`,
  `Workflow#trigger_source`, `WorkflowRun#status`, `Task#status`,
  `Task#gate`, `WebhookEvent#provider`, `Routine#trigger_source`,
  `Routine#visibility`.
- `Message#content` and `Message#reasoning` use Active Record
  encryption — credentials must be present in every environment that
  touches the model (including tests).
- User-facing copy lives in `config/locales/*.en.yml` (split by surface:
  `views_*`, `flash`, `mailers`, `models`, …), reached via `t(...)` /
  `I18n.t` — not inline strings. English is the baseline.
- Test parallelization is gated behind a high threshold
  (`threshold: 5000` in `test/test_helper.rb`) on purpose — parallel
  workers race on per-conversation scratch paths in `tmp/agent/` and
  `storage/agent/`.
- Background jobs run on Solid Queue (production); Solid Cache/Cable
  back Rails cache and Action Cable.

## Critical dependency

`Gemfile` pulls `pi-agent-rb` from rubygems (currently 0.2.0). This
gem drives `pi --mode rpc` and is the only way Metis talks to pi. No
sibling checkout required. Since 0.2.0 a turn ends at pi's
`agent_settled` event — `agent_end` is not terminal (pi may continue
after it).

## Commands

- `bin/dev` — run the app (Puma + Tailwind watch via foreman, port 3000)
- `bin/setup` — install deps, prepare the database
- `bin/rails test` — full test suite (Minitest)
- `bin/rubocop` — lint (rubocop-rails-omakase house style)
- `bin/ci` — full pipeline: rubocop, bundler-audit, importmap audit,
  brakeman, tests, seed replant
- `bin/rails metis:doctor` — configuration checklist: each subsystem
  reported as configured / missing / defaulted, exit 1 on missing
  required config

Run `bin/rubocop` and the relevant tests before committing.

## For detailed reference

- **Model details and relationships**: see [MODELS.md](MODELS.md)
- **Service layer patterns**: see [SERVICES.md](SERVICES.md)
- **Architecture docs**: `docs/` —
  [`session-persistence.md`](../../../docs/session-persistence.md),
  [`coding-runtime.md`](../../../docs/coding-runtime.md),
  [`observability.md`](../../../docs/observability.md),
  [`connectors.md`](../../../docs/connectors.md),
  [`tenancy.md`](../../../docs/tenancy.md),
  [`teams.md`](../../../docs/teams.md),
  [`agent-identity.md`](../../../docs/agent-identity.md),
  [`workflows.md`](../../../docs/workflows.md),
  [`local-bridge.md`](../../../docs/local-bridge.md)
