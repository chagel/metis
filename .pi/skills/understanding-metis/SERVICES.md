# Metis Service Layer

Most of the interesting code lives under `app/services/agent/` and
`app/services/oauth_broker/`. The rest is a thin Rails app.

## `Agent::Adapters` — *the agent*

```ruby
# app/services/agent/adapters.rb
Agent::Adapters.for(conversation, **opts)  # → Pi.new(conversation:, **opts)
```

This is **not** a multi-backend seam — pi is the only adapter.
`Adapters` exists to decouple `ChatJob`/`ChatBroadcaster` from pi's
wire protocol, so view code never imports `PiAgent::*`.

### `Agent::Adapters::Pi`

Drives one `PiAgent::Session` (obtained from a `Runtime`) and
translates pi's native event stream into `Agent::UiEvent`s.

```ruby
def stream(input, images: [], files: [], &block)
  @runtime.status_sink = ->(phase, message) {   # provisioning progress →
    block.call(UiEvent.new(:runtime_status, …)) # runtime_status events
  }
  @runtime.run(pi_args: pi_args, extension_ui: Agent::HostBridge.handler(conversation)) do |session|
    @session = session
    session.prompt(prompt_with_files(input, files), images: pi_images(images)) do |pi_event|
      ui_event = translate(pi_event)
      block.call(ui_event) if ui_event
    end
    @session_stats = capture_stats(session)   # tokens, contextUsage, sessionId, cost
    @model_info    = capture_model(session)   # {id, name, provider} — from get_state
  end
rescue PiAgent::TimeoutError => e
  raise boot_timeout?(e) ? BootTimeout.new(e.message) : e
ensure
  @session = nil
end
```

`#cost_total` comes from pi's `get_session_stats` RPC and `#model_info`
from `get_state`; `ChatJob` reads them to persist the turn's `cost` (USD)
and `model_key` onto the `Message` (see Observability below).
`Adapters::BootTimeout` distinguishes a pi that never booted (retryable)
from a mid-turn timeout.

`#translate` collapses pi's event vocabulary onto `Agent::UiEvent`'s
ten types and drops events the UI doesn't render (agent_start,
turn_start/end, compaction, queue updates). Tool events
(`tool_execution_start/update/end`) map to
`tool_call_started/progress/finished`; assistant `message_update` is
split by `assistantMessageEvent.type` into `text_delta` /
`reasoning_delta` / `error`. `#segmented_delta` inserts `\n\n` when
pi crosses into a new assistant message between tool calls — pi
strips leading whitespace per message and naive concatenation
fuses segments ("project.The"). The turn ends at pi's
`agent_settled` (→ `turn_finished`); `agent_end` is **not** terminal —
pi may retry, compact-and-retry, or run a queued continuation after it
(pi-agent-rb ≥ 0.2.0).

`#pi_args` composes:
- `--mode rpc --session-dir <runtime.session_dir>`
- `--continue` when `conversation.backend_session_id.present?`
- `#credential_args` — `--model`, `--provider`, `--api-key`
  (per-conversation `settings` overrides `config.x.agent` defaults;
  the api key is the env-loaded deployment key matched to provider)
- `#extension_args` — `--extension <path>` per
  `Agent::Runtime.extension_sources`

### `Agent::UiEvent`

Frozen canonical event with ten types:

```
runtime_status
message_started message_finished
text_delta reasoning_delta
tool_call_started tool_call_progress tool_call_finished
turn_finished error
```

`runtime_status` carries sandbox provisioning progress (phase +
message) — emitted by remote runtimes via `Runtime::Base#emit_status`
before pi is even up, so the UI can show "creating sandbox…" instead
of dead air.

`#native_ref` preserves the raw pi payload; backend-aware view
helpers can reach in, but default rendering ignores it.
`TERMINAL_TYPES = [:turn_finished]`.

## `Agent::Runtime` — *where the agent runs*

```ruby
Agent::Runtime.for(conversation)  # picks per config.x.agent.runtime
Agent::Runtime.extension_sources  # Dir.glob(.pi/extensions/*/index.ts).sort
```

### `Runtime::Base` contract

```ruby
def session_dir       # path for pi --session-dir
def extension_paths   # pi extensions reachable from this runtime
def run(pi_args:, extension_ui: nil) { |session| ... }  # provision → yield → finalize
def runtime_info      # { "runtime" => kind, … }
def sandbox_env       # per-turn env: GH_TOKEN + git author/committer (sandboxed only)
attr_accessor :status_sink  # set by the adapter; #emit_status(phase, message)
                            # reports provisioning progress (→ runtime_status)
```

`Base#mcp_config` renders `Agent::McpConfig.new(conversation).content`;
`Base#identity_content` renders `Agent::Identity.new(conversation, kind).content`.
Subclasses pull those at run time and stage them.

### `Runtime::Local`

Pi as a host subprocess — single-operator / dev runtime. Scope under
`storage/agent/u<id>/c<id>/`. Pi's own file-based session management
carries continuity; `--continue` resumes. **Not a security boundary.**

```ruby
def run(pi_args:, extension_ui: nil)
  workspace.ensure!
  workspace.stage_uploads(conversation.uploaded_files)
  workspace.stage_mcp_config(mcp_config)
  workspace.stage_identity(identity_content)
  workspace.stage_skills
  session = PiAgent.session(args: pi_args, cwd: workspace.workspace_dir.to_s,
                            extension_ui: extension_ui)
  yield session
ensure
  collect_host_artifacts(…)      # agent-published files → Message#artifacts
  ingest_team_skills(…)          # agent-edited DB skills sync back
  session.close
  workspace.discard_mcp_config   # secrets don't linger on disk
end
```

### `Runtime::Docker`

Same scope on host, bind-mounted into a `--rm` container. Container
ephemerality is the security boundary; persistence rides the bind
mount. Calls the same `Workspace#stage_*` methods, then runs `docker
run …` with the workspace dir mounted and the extensions dir
read-only-mounted.

In **production** this is the job runtime, run under **gVisor**
(`--runtime=runsc`, set by `METIS_DOCKER_RUNTIME`) as Docker-in-Docker
from the containerized `job` worker via a mounted socket — a user-space
kernel intercepts pi's syscalls. pi's `.pi/extensions` are baked into the
`metis-pi` image, auto-synced by a Kamal pre-deploy hook. See
`docs/coding-runtime.md`.

The persistent host root is a reclaimable hot cache:
`EvictDockerWorkspacesJob` (recurring) warm-evicts idle scopes'
`workspace/` while keeping `sessions/`, so pi still `--continue`s and
`Agent::Identity` warns the next turn its files are gone.

### `Runtime::E2b`

Pi inside an E2B microVM. The microVM lives across turns — first
turn creates and pauses, later turns connect+resume. Scope persists
*by being the same VM*. Eviction is metis's responsibility
(`EvictPausedSandboxesJob`); E2B keeps paused sandboxes indefinitely.

No bind mount — `stage_*` methods are reimplemented on the runtime
using `sandbox.files.write(remote_path, bytes)`. Extension files are
uploaded each turn so an extensions update reaches in-flight
conversations. `E2bTransport` drives `pi --mode rpc` over the sandbox's
command streaming.

```ruby
SCOPE_DIR      = "/home/user/metis"
WORKSPACE_DIR  = "#{SCOPE_DIR}/workspace"
EXTENSIONS_DIR = "/home/user/pi-extensions"  # outside SCOPE_DIR — restaged each turn

def run(pi_args:, &block)
  sandbox = acquire_sandbox    # resume_existing or create_fresh
  @sandbox_id = sandbox.sandbox_id
  execute(sandbox, pi_args: pi_args, &block)
ensure
  pause_sandbox(sandbox) if sandbox
end

# pause_sandbox: best-effort. A failure logs, force-kills the VM,
# clears e2b_sandbox_id — next turn provisions fresh. Must NEVER raise:
# the turn the user already saw stream cannot crash on end-of-run.
```

`self.kill_sandbox(id)` swallows `E2B::NotFoundError` — used by
`Conversation#before_destroy` and `EvictPausedSandboxesJob`, both of
which hold a stored id but no live `Sandbox` handle.

### `Runtime::Daytona`

Pi inside a Daytona elastic sandbox, resumed across turns by `stop`/`start`
on a stored `daytona_sandbox_id` (the pause/resume analog). Like E2b it has
no bind mount — `stage_*` is reimplemented over the SDK, staging in parallel.
`DaytonaTransport` drives `pi --mode rpc` over a Daytona session (streaming
stdin + follow-logs), using a community SDK fork (`chagel/daytona-sdk`).
Idle sandboxes are reaped by Daytona's **own** auto-stop/archive/delete
intervals set at create — there is **no metis cron** for Daytona (contrast
`EvictPausedSandboxesJob` for E2b). `self.kill_sandbox(id)` is best-effort,
called from `Conversation#before_destroy`.

### `Runtime::Microsandbox`

Pi inside a self-hosted **libkrun microVM**, driven in-process by the
optional `microsandbox-rb` gem (optional bundler group, lazily
required — it compiles a Rust native extension) — no daemon, no cloud
API. VM-grade isolation at self-hosted cost, on Linux with KVM or
macOS on Apple Silicon.

Persistence follows **Docker, not E2b/Daytona**: the VM is disposable
— created fresh each turn (`ephemeral: true`) — and the conversation
scope is a persistent host path bind-mounted into the guest at
`/metis`. Staging is host-side (`Workspace#stage_*`, projected through
the mount); the app's pi extensions ride a second read-only bind
mount. Nothing to pause, resume, or evict — a dead worker takes its
VMs with it, and `reap_stale_sandboxes` clears leftover state.
`MicrosandboxTransport` drives `pi --mode rpc` over `exec_stream`. pi
must be in the OCI image (`config.x.agent.microsandbox_image`, pulled
from a registry — microsandbox can't see a local Docker store).

All three remote transports (`E2bTransport`, `DaytonaTransport`,
`MicrosandboxTransport`) share the `TransportTiming` mixin for
boot/RPC timing instrumentation.

## `Agent::Workspace`

A thin wrapper around the host filesystem scope:

```
scope/
  sessions/                pi --session-dir : transcript
  workspace/               pi cwd : files the agent creates
    uploads/               staged user uploads
    .mcp.json              MCP connector config (per turn)
    AGENTS.md              boot identity + project catalog (per turn)
    .pi/skills/            repo + team skills, layered (per turn)
```

Two roots — `SCRATCH_ROOT = tmp/agent`, `PERSISTENT_ROOT = storage/agent` —
because persistence is a per-runtime concern. `Local` uses
`Workspace.persistent`; archive-shaped runtimes (none today) would
use `Workspace.scratch`.

`stage_uploads` basenames the filename so a crafted name can't
escape. `stage_skills` projects two sources into one tree — the
repo's `.pi/skills/` first, then each enabled `Skill` row extracted
under `workspace/.pi/skills/<slug>/` — and skips the whole re-stage
when a signature marker matches (repo fingerprint + team skill
signature unchanged).

## `Agent::McpConfig`

Renders the `.mcp.json` `pi-mcp-adapter` reads, from the
conversation team's `Connector`s. Each connector resolves to the
member's credential (own → team-shared → drop). An OAuth-shaped
connector whose grant is missing, missing required scopes, or fails
to refresh is dropped — `Identity#connectors_block` mirrors this gate
exactly so the AGENTS.md never advertises a connector McpConfig
silently omitted (the agent would burn turns trying tools it doesn't
have).

```ruby
def to_h
  # Per-connector member entries, plus an optional team-wide github_bot.
  entries = connectors.filter_map { |c| [c.name, server_entry(c)] if server_entry(c) }
  entries << bot_entry if bot_entry
  { "mcpServers" => entries.to_h }
end

# secrets_for:
#   nil               → drop the connector
#   {}                → keep (no-auth server)
#   {header => value} → merge into entry[stdio ? "env" : "headers"]
```

`bot_entry` stages a second `github_bot` server — team-wide, independent
of the conversation member — when the deployment is GitHub-App-auth
configured and an admin enabled it on the team's github connector
(`bot_enabled` + `bot_installation_id`). It bears a freshly minted
installation token (`GithubApp::InstallationToken.for`) so the agent can
act as `<slug>[bot]` (the reviewing-code skill posts PR reviews this way;
GitHub forbids approving your own PR, so the member `github` server
can't). A mint failure just omits it — never crashes the turn.

## `Agent::Identity`

Renders `AGENTS.md` — the boot file pi auto-loads from cwd each turn.
Shapes the agent's sense of place (operator, team, runtime,
connectors, uploads, the team's project catalog, soul).

Scope is **environment context** only — never Metis's product
guardrails (VISION.md). Telling pi "no SPA" would leak Metis-the-
product's contributor constraints into the user's work.

`coding_tools_block` only renders when `sandbox_env` actually injects
`GH_TOKEN` this turn — gate mirrors `Runtime::Base#sandbox_env`
exactly (sandboxed runtime + valid github grant + `repo` scope).
Naming `GH_TOKEN` when nothing is in env burns turns on tools the
agent doesn't have.

`conversation_history_block` renders `Conversation#replayable_history` into
AGENTS.md when pi has no session to `--continue` (a reaped sandbox) — the
working tree is gone but the message history isn't, so the agent regains
prior context. Wrapped with a token budget + blockquote framing so replayed
turns can't be mistaken for live instructions.

## `Agent::Catalog` & `Agent::ModelCatalogSync`

Provider/model options for the new-chat composer, sourced from the
deployment's **DB catalog** — `LlmProvider` / `LlmModel` rows a superuser
curates. `Agent::ModelCatalogSync` mirrors pi's `get_available_models` into
those rows: pi is the source of truth for *what exists*, the rows add
curation (enabled / label / position), which is sticky across refreshes.
Empty before the first sync → the composer renders no options and a turn
falls back to the `config.x.agent` deployment default. Chosen values land in
`Conversation#settings` and pass verbatim as pi's `--provider`/`--model`.

```ruby
Catalog.providers              # providers with ≥1 enabled model, grouped
Catalog.grouped_model_options  # for grouped_options_for_select
Catalog.provider_for(model_id) # which provider offers a model
Catalog.known_model?(model_id)
```

## `ChatJob` & `ChatBroadcaster`

`ChatJob` runs **one** turn:
1. `assistant_message.update!(streaming_status: :streaming)`
2. `adapter.stream(input) { |event| broadcaster.handle(event); buffer_text/reasoning/tools(event) }`
3. Every 15 events, poll `Conversation#cancel_requested_at` against
   `message.started_at` — stale stamps from prior turns don't count.
   On match: `adapter.abort`, mark canceled.
4. Persist final message (`content`, `reasoning`, `tool_calls`,
   `streaming_status`, `finished_at`, token deltas, `cost`, `model_key`) +
   persist session id, agent_model, runtime_info, context_usage on
   conversation. `cost` is a delta — `adapter.cost_total` minus the
   conversation's prior message costs, floored at 0.
5. `Observability::LangfuseTrace.record_turn(...)` — export the turn as an
   OTel span (no-op unless OTLP is configured).
6. `broadcaster.refresh_usage / collapse_activity / refresh_composer`.
7. `WorkflowRun.signal_turn_finished(conversation)` — no-op for a normal
   chat; re-enqueues `WorkflowAdvanceJob` when an active run drives this
   conversation.

Failure path: `fail_message` *reloads* the message first to drop dirty
in-memory attributes from a failed persist — otherwise the recovery
update flushes the same poisoned payload (e.g. a `tool_calls` bag with
a U+0000 byte) and rolls back too.

`ChatBroadcaster` maps each `UiEvent` to a Turbo Stream:
- `text_delta` → `broadcast_update` with the whole body re-rendered as
  Markdown (innerHTML replace, not append — keeps open code fences /
  half-built tables rendering correctly as more text arrives).
- `reasoning_delta` → append to the reasoning disclosure.
- `tool_call_started` → append a tool card, collapse the previous.
- `tool_call_progress/finished` → replace the card; only the latest
  stays open.
- `turn_finished` → remove the typing indicator.
- `error` → append into the message card (not the body — body's
  innerHTML is replaced on every text delta and would swallow it).

`#record_tool` accumulates `name`/`args`/`output`/`is_error` keyed by
`tool_call_id` — progress/finished events carry no name/args, so
replacing the card naively would blank them.

## `ConversationTurn` & the workflow engine

`ConversationTurn.start(conversation, content:, kind: :chat)` is the
single place a turn is born — user message + pending assistant message
in one txn, then `ChatJob.perform_later`. The composer (`Composing`
concern) and the workflow engine both go through it; `kind` renders the
engine's messages as run markers instead of chat bubbles
(`step_prompt`, `local_report`, `review`).

`WorkflowAdvanceJob` is the engine — a thin state machine that
sequences turns and gates, never deciding what the agent does inside a
turn. Each pass *settles* the running step (done + `approval` gate →
park on `awaiting_approval`; errored/canceled → fail the run; delegated
→ `:wait`, it settles via the bridge result instead), then *advances*:
next pending task → `ConversationTurn.start` with the step prompt, or
dispatch to the bridge when delegated (`run.awaiting_local!`), or
`run.completed!` when none remain. The step prompt is `step_prompt(run,
task)` — the task prompt with the run `input` restated and, for a
multi-step run, a self-orientation header (`#workflow_header`: which step,
what shipped before) prepended; single-step runs skip the header. Gate
decisions (approve / request changes / reject) and bridge result reports
both re-enqueue it. Request-changes folds the reviewer's feedback into a
revision turn; for a delegated step the feedback folds into the next
dispatch's prompt.

`WorkflowBroadcaster` owns the run's live DOM (timeline, gate panel,
sidebar "Needs you" pin) — same division of labor as `ChatBroadcaster`.

The bridge pull API (`app/controllers/api/bridge/` — REST + a hosted
streamable-HTTP MCP server + the self-documenting skill endpoint) is
the delegation transport; auth and claim semantics live on `User`
(bridge token) and `Task` (`claim_next_for`). See MODELS.md.

## `Agent::HostBridge`

Synchronous sandbox→host dispatch over pi's Extension UI sub-protocol —
the only sandbox→host channel pi exposes. The extension calls
`ctx.ui.input("metis:<op>", <json params>)`; pi forwards an
`extension_ui_request`; `Agent::Adapters::Pi` passes
`extension_ui: HostBridge.handler(conversation)` into the runtime's
`run`, and the handler services `"metis:"`-prefixed dialog requests as
host calls, cancelling everything else (a genuine user dialog has
nowhere to go in async web chat). Ops are an allowlist (`OPS`): reads
`get_workflow` / `get_project` answered inline; writes route to
`Agent::WorkflowHandoff` (`start_workflow`), `Agent::WorkflowAuthoring`
(`create/update_workflow`), `Agent::SkillManager`
(`list/create/update_skill`), `Agent::RoutineManager`
(`list/create/update_routine`). The sandbox never holds Metis
credentials — HostBridge authorizes server-side (team admin for
writes, membership for start), always within the conversation's team,
so a sandbox can't widen its own scope. Runs on the gem's per-request
thread (checks out its own AR connection) and never raises — a failed
call cancels the dialog, not the turn. Results are JSON strings the
extension parses into the tool result the model sees.

## `Agent::WorkflowHandoff`

Starts a workflow run **from inside a chat**. The agent's
`metis_start_workflow` tool call arrives over the Extension UI channel
and HostBridge routes it to
`WorkflowHandoff.from_tool_call(conversation, args)` — it is **not**
parsed out of the event stream by ChatJob. Refused inside a workflow
run (a run spawning runs would cascade). Resolves the named enabled
workflow, a project (named → chat's project → workflow default),
settings via `Agent::ModelSelection`, then
`WorkflowRun.start(..., autostart: false)` — the run parks `queued`
for a human to `launch!`. `#build_input` composes the run `input` from
the source chat — `Agent::TranscriptDigest` of the conversation, the
agent's optional `note` arg, and a `files_block` of the chat's
attachment download URLs (the spec/artifact links the next run
re-fetches; they don't live in the new run's workspace). Returns
`{ ok:, queued:, url:, … }` the agent relays in its own reply —
nothing is posted into the chat; failures are `{ ok: false, error: }`,
never a raise into the turn.

## `Agent::WorkflowAuthoring`

The `metis_create_workflow` / `metis_update_workflow` handlers —
agent-driven authoring of team workflow templates, same channel and
result shape as WorkflowHandoff. Admin-gated
(`team.managed_by?(user)`, mirroring the UI's `require_team_admin!`)
and refused inside a workflow run. Create demands ≥1 normalized step;
update is partial — only the keys the agent passed change, and a named
project that doesn't resolve is an error, not a silent skip.

## `Agent::ModelSelection`

Resolves an explicit model/provider choice against the DB LLM catalog,
layered over base settings — shared by `WorkflowHandoff` and
`RoutineManager`. Returns `[settings, error]`. No catalog synced →
values pass through (pi validates them itself); a synced catalog with
everything disabled still rejects, so chat can't bypass operator
curation. Matches by pi model key first, then label, optionally
provider-scoped — an unscoped match spanning providers is ambiguous
and errors. Provider without a model → its first enabled model. Both
`provider` and `model` are always set together so a provider switch
never keeps a model from the old provider.

## Routines — `Agent::RoutineManager` / `Routine::EventDispatcher` / `Routine::PromptRenderer`

`Agent::RoutineManager` is the agent-driven routine CRUD over
HostBridge: admin-gated writes, refused inside a workflow run, no
delete tool, and an agent-created routine **starts disabled** — a
self-firing rule the agent authored shouldn't go live without the
operator. Model/provider args resolve through `Agent::ModelSelection`
into `trigger_config["settings"]`.

Firing is three paths onto one turn. `RoutineSchedulerJob` (recurring,
every minute) sweeps `Routine.due` and calls `fire_scheduled!`,
best-effort per row. The webhook path is the collect-then-trigger
split: `Webhooks::GithubEventProcessor` /
`Webhooks::LinearEventProcessor` map one delivery to a `WebhookEvent`
— team resolved from the payload (GitHub installation id vs Linear
organizationId) against the matching connector, an event no team
claimed dropped, project bound when the payload names a bound
repo/Linear project, deduped on the delivery id — and the row's
`after_create_commit` enqueues `RoutineDispatchJob`, which hands the
event to `Routine::EventDispatcher`. The dispatcher matches the team's
active webhook routines (wildcard event_type allowed), gates on
per-routine cooldown and optional `trigger_config["conditions"]`
(dotted-path equality on the payload), then `fire!` — a normal turn
via `ConversationTurn.start`. `Routine::PromptRenderer` interpolates
`{{name}}` placeholders: builtins (date/time/team/user, plus `event_*`
on the webhook path) win over the routine's own
`trigger_config["variables"]`; unknown placeholders stay untouched.
The Linear processor also enqueues `Linear::ProjectBackfillJob` when a
fresh event references an issue but carries no project (Linear
serializes comments shallowly) — it resolves the project via the
Linear API, best-effort.

## Skills — `Agent::SkillManager` / `SkillImporter` / `RepoSkills` / `SkillMarketplace`

`SkillManager` is the agent-driven team-skill CRUD over HostBridge —
admin-gated writes, no delete, single-`SKILL.md` skills only
(multi-file skills go through the native file path); `list` covers
both sources the runtime merges: repo built-ins (always active,
read-only) and team rows (which may be disabled). `SkillImporter`
pulls a skill directory from GitHub's Contents API (the importer's own
OAuth bearer when present) into a team `Skill` row — async via
`ImportSkillJob`. `RepoSkills` is the read-only listing of the repo's
`.pi/skills/` tree (the Built-in tab); `SkillMarketplace` is a
hard-coded curated list of Anthropic-skills-repo entries the import
path consumes.

## Forking — `Agent::ConversationForker` / `ForkPlan` / `ForkPreparer` / `SessionTree`

Fork a conversation from any assistant turn. `ConversationForker`
copies the messages up to the fork point in one txn; the expensive pi
session copy is deferred — `fork_pending` marks it, and
`Agent::ForkPreparer` runs at the fork's first `ChatJob` to copy the
source scope and truncate the transcript at the fork point
(`Agent::SessionTree.truncate_before_user` — pi sessions are JSONL,
file order is the active path). When the source scope is gone, the fork
falls back to history replay like any reaped sandbox.

## `Agent::TitleGenerator` & `ArtifactPreviewer`

`TitleGenerator` names a conversation from its first turn with one
direct, cheap LLM call (no pi subprocess); nil on any failure — the
caller falls back. It calls a title-capable provider (`TITLE_MODELS`:
anthropic / openai / google) with a configured key — preferring the
conversation's own provider, then the deployment default, else any
usable one — so a conversation on an unsupported provider (e.g. minimax)
still gets a real title instead of the truncation fallback. Runs in
`GenerateConversationTitleJob`; workflow runs get distinct names per run
this way. The caller's fallback (`Conversation#apply_generated_title!`)
uses the run's `input` for a workflow conversation, not the step prompt.

`ArtifactPreviewer.for(blob)` picks the first matching renderer
(`Previewers::Image/Pdf/Csv/Text/Fallback`, order matters) for files
the agent hands back.

## `Mcp::Oauth`

OAuth client for remote MCP servers per the MCP authorization spec —
protected-resource + auth-server metadata discovery, Dynamic Client
Registration (stored in `McpOauthClient`), OAuth 2.1 auth-code + PKCE,
RFC 8707 resource indicators. Connects any DCR-capable MCP server with
no pre-registered provider app. Distinct from `OauthBroker` (the
sign-in/connector providers with static apps).

## `Observability::LangfuseTrace`

Exports one finished turn as an OpenTelemetry span to Langfuse (or any OTLP
backend). `record_turn` builds a `gen_ai.*`-attributed span (model, token
counts, cost, user/team) from the persisted `Message` + conversation and
ships it over OTLP. Off unless configured — a missing endpoint makes
`record_turn` a no-op, never an error, so telemetry can't crash a turn the
user already saw. Native usage capture (cost/model on the `Message`) is
independent and always on. See `docs/observability.md`.

## `Doctor`

Configuration checklist behind `bin/rails metis:doctor`
(`lib/tasks/metis.rake`). Reports each subsystem — core (DB,
migrations, AR encryption), email, agent (runtime, provider keys,
default model, web search), storage, access, connectors,
observability — as configured / missing / defaulted from ENV, with the
exact env var names, so a deployer doesn't have to read initializers.
Never prints secret values, only presence; the rake task exits 1 when
any check fails.

## `OauthBroker` + `OauthBroker::Clients::{Github,Google}`

Provider-agnostic token broker. `access_token_for(grant)` returns the
current bearer, refreshing through the provider's token endpoint when
stale (within `REFRESH_LEEWAY`) or when stored token is blank (legacy
backfill row). `bearer_for(user:, provider:, required_scopes:)` is
the entry point for `Runtime::Base#sandbox_env`. `CLIENTS` maps
`github`/`google`/`x` — Linear is not brokered here; `LinearApp::Oauth`
owns its token dance (see Provider apps).

Also the **single source of truth for the strategy/provider name
split**: Identity stores the omniauth strategy name
(`google_oauth2`), OauthGrant + catalog use the canonical name
(`google`). All translation goes through `normalize_provider` /
`omniauth_strategy`.

`scope_check_meaningful?(provider)` returns false for `github` —
GitHub Apps' OAuth response carries no scopes (App permissions on
the App's settings page are the real gate), so `grant.scopes` ends
up empty/incomplete regardless. Callers fall back to "grant + token
present" instead of `covers?(...)`.

`revoke(grant)` revokes server-side and is best-effort — a network
failure logs and returns rather than blocking; the local destroy
still happens.

## `OmniauthConnector`

Translates an OmniAuth callback into Metis's durable state. Called
in sequence by the OmniAuth callback:

1. **Always**: `record_grant(user, auth, provider:)` — find-or-init
   the `OauthGrant`, absorb the token bundle. Sign-in goes through
   this and only this; the grant ends up holding just the sign-in
   scopes (per `OauthBroker::SIGN_IN_SCOPES`).
2. **When the authorize URL carried `connect=<key>`**:
   `activate_connector(user, app, auth, team:)` — find-or-init the
   `Connector` and the per-member `ConnectorCredential` marker
   (capturing `external_login` from the auth nickname). The token
   already lives in the grant from step 1; this row is just the
   presence signal `McpConfig` keys off.

## `ConnectorCatalog`

Curated MCP-server "apps", loaded from `config/connector_catalog.yml`
(ERB processed before YAML so entries can interpolate env vars).
Each app is a template — connecting one resolves it into a team's
`Connector`. `App#resolved_definition(inputs)` fills `%{key}`
placeholders from user input; `App#credential_map_for(secret)` shapes
the user's secret into the header map a `ConnectorCredential` holds.

## Provider apps (`github_app/`, `google_app/`, `linear_app/`, `x_app/`)

Tiny per-provider config holders:
- `*App::Config` — client_id, client_secret, redirect URI, allowed
  scopes, callback URL.
- `GithubApp::OauthClient` — GitHub-specific OAuth token refresh;
  `OauthBroker::Clients::Github` delegates to it.
- `LinearApp::Oauth` — hand-rolled net/http auth-code exchange +
  refresh (connector-only, no sign-in, outside `OauthBroker`). Linear
  access tokens expire in 24h, so `ConnectorCredential` refreshes
  before use. Only Google rides stock OAuth2 — omniauth-google-oauth2
  for the flow, the broker's `Clients::Google` for refresh.
- `XApp::Oauth` — hand-rolled auth-code + PKCE with HTTP Basic client
  auth and a rotating refresh token. Connector-only like Linear (no
  sign-in strategy; connects via `Connectors::XOauthController`), but
  refresh IS brokered — `OauthBroker::Clients::X`.

These exist because the providers diverge in non-trivial ways
(GitHub App vs. OAuth App, Google's offline-access dance, Linear's and
X's connector-only models). Keep per-provider quirks here rather than
leaking into `OauthBroker` core.

## `EvictPausedSandboxesJob`

Recurring job (wired in `config/recurring.yml`). Finds conversations
with an `e2b_sandbox_id` and `updated_at < cutoff`
(`config.x.agent.e2b_eviction_window`), kills the sandbox, clears
the id. Best-effort per row — a per-conversation failure logs and
the loop continues; one bad row mustn't stall the whole eviction.

The next turn against an evicted conversation provisions fresh — the
working tree is gone, the message history is not (Agent::Identity replays
`replayable_history` into AGENTS.md). Daytona needs no equivalent job — its
sandboxes self-reap on native auto-stop/archive/delete intervals.

## `ReapStalledTurnsJob`

Recurring (every 5 min, `config/recurring.yml`). Marks assistant messages
stuck `pending`/`streaming` past a cutoff as `errored` and broadcasts — so a
worker that died mid-turn doesn't leave the UI hanging or the partial unique
index blocking the next turn forever.

## Mail delivery

`METIS_MAIL_DELIVERY` picks the transport per environment (production
defaults `smtp`, development `test`). `Delivery::SmtpSettings.from_env`
builds ActionMailer's `smtp_settings` from `SMTP_*` env — `SMTP_HOST`
accepted as an `SMTP_ADDRESS` alias, present-but-empty vars treated as
unset (.env templates ship blank lines), TLS vs STARTTLS mutually
exclusive, AUTH only when a username is set. `Delivery::Cloudflare` is
the REST alternative (Cloudflare Email Service, registered as
`:cloudflare`); it raises on failure — `TransientError` for
429/5xx/network blips — the same contract as `:smtp`, so
`MailDeliveryJob` can retry.

## Other jobs

- `EvictDockerWorkspacesJob` — recurring; warm-evicts idle Docker /
  Microsandbox scopes' `workspace/` (keeping `sessions/`) to bound
  host disk (see Runtime::Docker above).
- `CleanupPersistentWorkspaceJob` — removes a destroyed conversation's
  whole persistent scope, enqueued from
  `Conversation#after_destroy_commit` — never `rm_rf` inline.
- `DaytonaStopJob` — delayed stop after the keep-warm window, so ending
  compute billing never holds the ChatJob worker; no-op if a newer turn
  reused the box (freshness token). Daytona's autoStop is the backstop.
- `RefreshModelCatalogJob` — runs `Agent::ModelCatalogSync` off the web
  request; the sync spins up a pi control session, which 504s the proxy
  if done inline.
- `GenerateConversationTitleJob`, `ImportSkillJob` — async wrappers for
  `Agent::TitleGenerator` / `Agent::SkillImporter`.
- `MailDeliveryJob` — the `deliver_later` job; retries transient SMTP +
  `Delivery::Cloudflare::TransientError` failures with backoff,
  permanent failures surface.
- `ReclaimSilentBridgeTasksJob` — recurring sweeper: bridge claims
  silent past `config.x.bridge.claim_ttl` return to the unclaimed pool;
  at `reclaim_cap` the task fails and the run surfaces it instead of
  cycling.
- `RoutineSchedulerJob` / `RoutineDispatchJob` — the routine firing
  jobs (see Routines).
- `Linear::ProjectBackfillJob` — resolves a webhook event's missing
  project via the Linear API (see Routines).

## What's deliberately absent

Per `VISION.md`:
- No second agent backend (pi is *the* backend).
- No Rails-side MCP runtime — MCP servers are bridged into pi via
  `pi-mcp-adapter` extension, **not** loaded by Rails.
- No polymorphic `owner` — tenancy is `Team`-only.
- No SPA — Hotwire all the way down.
- No per-user provider keys — LLM keys are deployment-shared.
- No `Agent::SessionArchive` — runtimes own persistence; no
  tar-to-Active-Storage path.

If a temptation here pulls you toward one of those, push back or
argue it on a PR.
