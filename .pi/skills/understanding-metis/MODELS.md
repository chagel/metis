# Metis Model Details

The full domain is small on purpose — Metis is a chat UI in front of pi, not its own agent platform.

## User

Devise + OmniAuth. Identity-first lookup; email is fallback only when
the provider's address is verified (anchored noreply pattern check
prevents pseudo-emails from matching real ones).

```ruby
devise :database_authenticatable, :registerable, :recoverable,
       :rememberable, :validatable, :omniauthable,
       omniauth_providers: %i[github google_oauth2]

has_many :memberships, dependent: :destroy
has_many :teams, through: :memberships
has_many :conversations, dependent: :destroy
has_many :connector_credentials, dependent: :destroy
has_many :identities, dependent: :destroy        # (provider, uid) lookup keys
has_many :oauth_grants, dependent: :destroy      # token + scope set per provider
has_many :artifact_shares, foreign_key: :created_by_id  # public artifact links minted
has_one_attached :avatar

after_create :create_personal_team               # team-of-one at signup

def personal_team = teams.find_by(personal: true)

# Personalization columns rendered into AGENTS.md / used by the UI:
#   display_name, avatar_url, about_you, custom_instructions,
#   preferred_model, language, theme, timezone.
# superuser (boolean) gates catalog sync + admin surfaces.

# Local bridge (docs/local-bridge.md): one personal-access token per user.
#   bridge_token_digest — SHA-256 of the mbt_… token (unique index); the
#     plaintext is shown once, regenerating revokes.
#     User.authenticate_bridge_token(token) is the API lookup.
#   bridge_token_hint — last 4 chars of the token (not a secret), for the
#     "mbt_…abcd" label in account settings.
#   bridge_seen_at, bridge_client — presence heartbeat + self-reported
#     machine name, stamped by every authed bridge call (bridge_seen!);
#     the board's actor rail reads both (BoardPresence#machines).
#   auto_claim_tasks (default true) — when off, the daemon must claim
#     delegated tasks manually instead of FIFO auto-claim.
```

`User.from_omniauth(auth)`:
- Looks up `Identity.find_by(provider:, uid:)` first (durable handle).
- Falls back to `find_or_initialize_by(email:)` only when the address
  is verified per `email_verified_for?(auth)` (GitHub: always true on
  `user:email` scope; Google: explicit `email_verified == true`).
- Unverified → `noreply_email(auth)` synthesizes `<uid>+<handle>@<provider>.users.noreply.metis`.
- Wraps the create in a transaction with a one-shot retry: on
  `RecordNotUnique`, the loser re-reads `Identity` and finds the
  winner. Handles the concurrent-first-sign-in race.
- `backfill_real_email` promotes a placeholder to a real email when
  the provider later starts returning one (never the reverse).

## Team

The single tenancy unit (`docs/tenancy.md`). Every ownable resource
belongs to a team.

```ruby
has_many :memberships, dependent: :destroy
has_many :members, through: :memberships, source: :user
has_many :conversations, dependent: :destroy
has_many :connectors, dependent: :destroy
has_many :skills, dependent: :destroy
has_many :projects, dependent: :destroy
has_many :workflows, dependent: :destroy
has_many :workflow_runs, dependent: :destroy
has_many :routines, dependent: :destroy
has_many :webhook_events, dependent: :destroy
has_many :artifact_shares, dependent: :delete_all
has_many :invitations, dependent: :destroy

# A `personal` boolean marks the team-of-one created at signup.
```

## Membership

Joins user → team with a role. No polymorphic `owner`.

```ruby
belongs_to :user
belongs_to :team

enum :role, { member: 0, admin: 1, owner: 2 }
validates :user_id, uniqueness: { scope: :team_id }
```

## Identity

A `(provider, uid)` pair — the durable handle the OmniAuth callback
uses to recognize an existing user. **Not** the same as `OauthGrant`
(Identity stores the omniauth strategy name like `google_oauth2`;
OauthGrant stores the canonical provider like `google` —
`OauthBroker.normalize_provider` bridges them).

```ruby
belongs_to :user
validates :provider, presence: true
validates :uid, presence: true, uniqueness: { scope: :provider }
```

## OauthGrant

**The single source of truth for OAuth tokens.** One per
`(user, provider)`, holding access + refresh tokens and the union of
every scope ever granted across all connectors wired to that
provider. `ConnectorCredential` rows for OAuth-shaped connectors are
*presence markers* — the tokens live here.

```ruby
belongs_to :user

encrypts :access_token
encrypts :refresh_token

validates :provider, uniqueness: { scope: :user_id },
                     inclusion: { in: OauthBroker::PROVIDERS }

REFRESH_LEEWAY      = 60.seconds   # treat tokens this close to expiry as stale
DEFAULT_EXPIRES_IN  = 1.hour       # fallback when neither response nor prior grant has expiry

def fresh?  # expires_at present AND > REFRESH_LEEWAY in the future
def scope_set       # array of granted scopes (space- or comma-separated input)
def covers?(required)  # every scope in `required` is in scope_set
def absorb!(response, at: Time.current)
  # Replaces (not unions) scopes when the response carries them —
  # otherwise covers? returns true for a scope the user just revoked
  # on the consent screen. Preserves prior refresh_token when omitted
  # (Google omits on refresh). Falls back to DEFAULT_EXPIRES_IN if
  # neither response nor prior grant has expires_at — without this
  # legacy backfill rows refresh on every chat turn.
def remove_scopes!(scopes_to_remove)
  # Drops scopes locally when a connector is disconnected. Does NOT
  # touch the grant at the provider; revocation is handled separately
  # when the last OAuth connector for a provider is disconnected.
```

## Connector

One configured MCP server, owned by a team. Becomes a `mcpServers`
entry in the per-turn `.mcp.json` rendered by `Agent::McpConfig`.

```ruby
belongs_to :team
has_many :connector_credentials, dependent: :destroy

# stdio → `command` server entry; http → `url` server entry;
# cli → omitted from `.mcp.json`, authorized via Runtime#sandbox_env
# (used today by the gws Google Workspace fallback).
enum :transport, { stdio: 0, http: 1, cli: 2 }

# settings (jsonb) store_accessor:
#   bot_enabled         — admin opt-in for the github_bot installation
#     token (off by default; installation-wide, shared team-wide).
#   bot_installation_id — which App installation the bot acts through
#     when the App has several (nil → GITHUB_APP_INSTALLATION_ID).
#   McpConfig#bot_entry reads both to stage the `github_bot` server.
#   linear_organization_id — the authorizing Linear workspace's org id,
#     captured on OAuth; inbound app-webhook deliveries resolve to the
#     team via `for_linear_organization(org_id)`.

validates :name, format: { with: /\A[a-z0-9][a-z0-9_-]*\z/i },
                 uniqueness: { scope: :team_id }
validate :definition_matches_transport  # stdio needs "command", http needs "url"

def credential_for(user)
  # The member's own credential if set, else the team's shared one.
  connector_credentials.find_by(user: user) || connector_credentials.find_by(user: nil)
end

def catalog_app
  # The ConnectorCatalog::App this connector was created from, or
  # nil for a custom (off-catalog) connector.
  ConnectorCatalog.find(catalog_key)
end
```

## ConnectorCredential

A per-member presence marker on a team's Connector. For **token-auth**
connectors, the secret IS here (in the `headers` envelope on the
encrypted `credentials` column). For **OAuth-shaped** connectors, the
token lives in `OauthGrant` — this row just records "this member
wired this connector up".

A row with `user_id = nil` is the team's shared credential (a service
account, only meaningful for token-auth).

```ruby
belongs_to :connector
belongs_to :user, optional: true

encrypts :credentials
validates :user_id, uniqueness: { scope: :connector_id }

# external_login — the provider-side account handle captured at connect
# time (display only).

def credential_map
  # The header bag ("Authorization" => "Bearer xyz") to merge into
  # the connector's .mcp.json entry. Token-auth stores these
  # directly; OAuth returns {} — runtime projects the live token
  # through the catalog's credential format.
end

def oauth_grant
  # The user's grant for the connector's provider, or nil. Same
  # grant covers every connector wired to the same provider.
end

def oauth_ready?
  # OAuth-shaped + token present + scopes cover the catalog's
  # required scopes. For GitHub (scope_check_meaningful? == false),
  # token presence is the only gate — App install permissions are
  # the real authorization.
end
```

## Project

User-managed R&D context owned by a team — a `name`, a freeform `about`,
and bound external resources in `external_refs` (jsonb, default `{}`).
Conversations attach to a project; the team's project catalog is rendered
into per-turn `AGENTS.md` for lookup-by-mention. Inbound webhooks match a
delivery against the external refs to fill `WebhookEvent#project`.

```ruby
belongs_to :team
belongs_to :created_by, class_name: "User", optional: true
belongs_to :updated_by, class_name: "User", optional: true
has_many :conversations, dependent: :nullify

# github_repo — "owner/name" on GitHub; linear_project — the Linear
# project's UUID. Both normalized before validation (pasted URL /
# trailing .git forgiven, lowercased).
store_accessor :external_refs, :github_repo, :linear_project

validates :name, presence: true,
                  uniqueness: { scope: :team_id },
                  length: { maximum: NAME_MAX }
validates :github_repo,    format: { with: %r{\A[\w.-]+/[\w.-]+\z} }, allow_blank: true
validates :linear_project, format: { with: /\A[0-9a-f-]{8,}\z/i },   allow_blank: true

scope :recent, -> { order(updated_at: :desc) }
scope :named,  ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip) }
scope :for_github_repo,    ->(full_name) { … }  # webhook → project resolution
scope :for_linear_project, ->(id) { … }

# Binding a ref retroactively claims already-collected orphan events
# (WebhookEvent rows with project_id nil that match the new ref).
after_save :adopt_orphan_events, if: :saved_change_to_external_refs?
before_destroy :forbid_active_runs   # a project with active runs can't be deleted
```

## Conversation

```ruby
# In-app team visibility; the public share link (share_token) stays a
# separate, explicit owner action.
enum :visibility, { personal: 0, team: 1 }, prefix: :visibility

belongs_to :user
belongs_to :team
belongs_to :project, optional: true
belongs_to :forked_from_message, class_name: "Message", optional: true
belongs_to :routine, optional: true   # present when a Routine fired this conversation
has_many :messages, dependent: :destroy
has_one :workflow_run, dependent: :destroy   # nil for a normal chat
has_many :senders, -> { merge(Message.user).distinct.order(:id) }  # participants
has_one :inflight_message, -> { inflight }, class_name: "Message"

before_validation :default_team, on: :create  # defaults to user.personal_team
before_destroy :kill_paused_e2b_sandbox       # E2B doesn't auto-clean
before_destroy :kill_daytona_sandbox          # Daytona stop/start sandbox
after_destroy_commit :cleanup_persistent_workspace  # CleanupPersistentWorkspaceJob

scope :recent,   -> { order(updated_at: :desc) }
scope :active,   -> { where(archived_at: nil) }
scope :archived, -> { where.not(archived_at: nil) }
scope :starred,  -> { where.not(starred_at: nil) }
scope :shared,   -> { where.not(share_token: nil) }
# The three sidebar kinds, in the row's identity precedence: a workflow
# run, else a routine fire, else a plain chat.
scope :chats,     -> { where(routine_id: nil).where.missing(:workflow_run) }
scope :workflows, -> { where.associated(:workflow_run) }
scope :routines,  -> { where.not(routine_id: nil) }
scope :for_team, ->(team) { where(team: team) }
# The visibility rule, in one place: the launcher always, teammates only
# when team-visible. Every surface applies it through this scope or
# #accessible_to?.
scope :accessible_to, ->(user) { where(visibility: :team).or(where(user_id: user.id)) }
# Batches everything a sidebar row asks (run pill, running dot,
# participant avatars) for the whole page.
scope :preloaded_for_sidebar, -> { … }
# The conversation set every board view draws from — visible to the user
# (accessible_to), narrowed by scope (:mine → own only) and a project
# filter. Shared by Board (grid) and BoardPresence (actor rail) so they
# can't diverge; run-level facets (done window, needs_me) stay per-caller.
scope :board_visible, ->(user, board_scope, project_ids) { … }

# Persisted per-turn:
#   settings       — provider/model picked in the composer (jsonb)
#   backend_session_id — pi's --session-dir handle for --continue
#   agent_model    — {id, name, provider} pi actually resolved
#   runtime_state  — { "runtime" => "local|docker|e2b|daytona|microsandbox", … }
#   context_usage  — { tokens, contextWindow, percent } per latest turn
#   e2b_sandbox_id     — for Runtime::E2b resume across turns
#   daytona_sandbox_id — for Runtime::Daytona start across turns
#   cancel_requested_at — set by #request_cancel!, polled by ChatJob
# Sharing / inbox columns: title, share_token (public read link),
#   starred_at, archived_at.
# Forking: forked_from_message marks the fork point; fork_pending defers
#   copying the source session scope to the fork's first turn
#   (Agent::ForkPreparer, run at ChatJob start).

def model_label    # agent_model["name"] || settings["model"]
def runtime_label  # runtime_state["runtime"]
def turn_in_progress?
  # Returns true while an assistant message is :pending or :streaming;
  # MessagesController uses this to refuse a concurrent turn (also
  # backed by a partial unique index that catches the TOCTOU race).
def request_cancel!  # stamps cancel_requested_at; ChatJob polls every 15 events

def uploaded_files
  # Every file attached across the conversation — projected into
  # workspace/uploads/ each turn (durable input, not session state).
  messages.with_attached_files.flat_map { |m| m.files.attachments }
end

def replayable_history
  # Prior user/assistant turns (excludes the in-flight turn), replayed
  # into a fresh sandbox by Agent::Identity when the predecessor holding
  # pi's transcript was reaped. The working tree dies; history doesn't.
end
```

## Message

```ruby
enum :role,             { user: 0, assistant: 1, tool: 2, system: 3 }
enum :streaming_status, { pending: 0, streaming: 1, done: 2, errored: 3, canceled: 4 }
# kind renders workflow-engine messages as run markers instead of chat
# bubbles: step prompts, local-task reports, gate review feedback, and the
# handoff note when a chat starts a workflow run (Agent::WorkflowHandoff).
enum :kind,             { chat: 0, step_prompt: 1, local_report: 2, review: 3, handoff: 4 }

belongs_to :conversation, touch: true
belongs_to :sender, class_name: "User", optional: true  # who sent a user message
has_many_attached :images     # sent inline via pi's vision protocol
has_many_attached :files      # staged into workspace/uploads/
has_many_attached :artifacts  # agent-published files, populated by ChatJob

encrypts :content
encrypts :reasoning

ALLOWED_IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp]
ALLOWED_FILE_TYPES  = %w[application/pdf text/plain text/csv text/markdown
                         application/json application/xml text/xml]
MAX_UPLOAD_SIZE = 10.megabytes

# Per-turn usage columns (deltas vs prior turns, computed in ChatJob):
#   input_tokens, output_tokens, cache_read_tokens
#   cost      : decimal(12,6) USD for the turn, straight from pi
#   model_key : the model that served the turn (pi's resolved id)
#   started_at, finished_at : turn timing
# tool_calls : jsonb array — one entry per tool call, accumulated across
#              started/progress/finished events.
# native_ref (jsonb) — the raw pi payload behind the message, for native
#              view helpers; tool_call_id (string) — pi's id for a tool row.

def duration  # finished_at - started_at, or nil
```

`ChatJob` scrubs `\x00` from every persisted string/array/hash —
PostgreSQL refuses U+0000 in text/jsonb, and pi occasionally emits one
inside a tool call payload (binary leak, malformed file read).

## Workflow

A team's reusable multi-step recipe (`docs/workflows.md`). `steps` is a
jsonb array — each step a `{ name, prompt, gate, run }` hash; `run:
"local"` marks the step delegated to the user's machine.

```ruby
belongs_to :team
belongs_to :default_project, class_name: "Project", optional: true
has_many :workflow_runs, dependent: :nullify

enum :trigger_source, { manual: 0, webhook: 1, schedule: 2, api: 3 }, default: :manual
# name, description, steps (jsonb), trigger_config (jsonb), enabled,
# default_project_id (nullable — pre-selects the launch project,
# overridable per run; validated in-team).
```

## WorkflowRun

One execution of a workflow (or an ad-hoc step list — `workflow` is
optional). Backed 1:1 by a `Conversation` the engine drives; one `Task`
per step.

```ruby
belongs_to :team
belongs_to :workflow, optional: true   # nil = ad-hoc run
belongs_to :conversation               # unique index — one run per conversation
has_many :tasks, -> { order(:position) }, dependent: :destroy

enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                completed: 3, failed: 4, cancelled: 5, awaiting_local: 6,
                queued: 7 }, default: :pending

scope :active,   -> { where(status: %i[queued pending running awaiting_approval awaiting_local]) }
scope :awaiting, -> { where(status: %i[queued awaiting_approval awaiting_local]) }  # "Needs you"

# Run.start(team:, user:, project:, workflow:, steps:, input:, visibility:, …)
#   creates conversation + run + tasks in one txn, enqueues
#   WorkflowAdvanceJob. `project:` is REQUIRED — raises ArgumentError on nil
#   (daemons claim delegated steps per project); a project with active runs
#   can't be destroyed. `input` is restated into every step's prompt (not
#   just the first); `visibility` is the launcher's choice (team-visible
#   runs are openable and actionable by any member).
# Run.signal_turn_finished(conversation) — called by ChatJob when a turn
#   settles; re-enqueues the advance job if this conversation's run is active.
```

## Task

One step of a run (`docs/workflows.md`); a **delegated** task
(`docs/local-bridge.md`) runs on the user's own machine via the bridge
pull API instead of as a cloud turn.

```ruby
belongs_to :workflow_run
belongs_to :assistant_message, class_name: "Message", optional: true  # the step's cloud turn
belongs_to :approved_by, class_name: "User", optional: true
belongs_to :claimed_by_user, class_name: "User", optional: true       # claim identity

enum :status, { pending: 0, running: 1, awaiting_approval: 2,
                completed: 3, rejected: 4, failed: 5, skipped: 6 }
enum :gate,   { auto: 0, approval: 1 }   # "none" would clash with Model.none

scope :dispatched,   -> { running.where(delegated: true) }   # waiting for a local pull
scope :claimable_by, ->(user) { delegated_for(user).running.unclaimed }

# claim_next_for(user, client:, id:, project:) — FIFO claim across the
#   user's teams (optionally narrowed to one project),
#   FOR UPDATE SKIP LOCKED so concurrent pollers get distinct tasks.
#   `client` is the self-reported machine name (X-Bridge-Client header).
# ref — Sentry-style short reference ("CHEESE-1G"), derived from the id
#   (base-36), no column; dereference accepts either form.
# progress (jsonb array) — log_progress! appends bridge progress notes.
# result (jsonb { status, summary, artifacts }) — read via result_failed?,
#   result_summary, result_artifact_urls.
```

## Routine

A team's saved prompt that fires on its own — on a cron `schedule` or a
`webhook` event (`docs/routines.md`). Each fire is a normal chat turn via
`ConversationTurn.start` in a fresh conversation tagged
`Conversation#routine_id`; no engine of its own, not bound to a workflow.

```ruby
belongs_to :team
belongs_to :user                       # fired conversations are owned by this user
belongs_to :project, optional: true    # validated in-team
has_many :conversations, dependent: :nullify

enum :trigger_source, { schedule: 0, webhook: 1 }, default: :schedule
enum :visibility,     { personal: 0, team: 1 }, prefix: :visibility, default: :personal

store_accessor :trigger_config, :variables   # prompt {{variable}} substitutions

# name, prompt (null: false), cron, timezone (default "UTC"), event_type,
# enabled (default true), last_run_at, next_run_at, trigger_config (jsonb).
# cron required on schedule, event_type on webhook; cron must be exactly
# 5 fields (the IANA zone is appended as fugit's 6th field).

scope :active, -> { where(enabled: true) }
scope :due,    -> { active.schedule.where("next_run_at <= ?", Time.current) }
scope :named,  ->(name) { where("LOWER(name) = LOWER(?)", name.to_s.strip).order(:id) }

def fire!(event: nil)
  # Starts one turn in a fresh conversation (routine's user/team/project,
  # trigger_config settings, routine's visibility, title = name), stamps
  # last_run_at. `event` (a WebhookEvent) feeds the prompt's event_* variables.
def fire_scheduled!
  # Scheduler path: row-locked so overlapping ticks can't double-fire,
  # advances next_run_at past now so it won't reselect.
def matches_event?(event)
  # Exact event_type match, or a "pull_request.*" prefix wildcard.
```

## WebhookEvent

A raw inbound provider event, collected and then fanned out to the team's
matching event routines — the collect half of the collect-then-trigger
webhook split.

```ruby
belongs_to :team
belongs_to :project, optional: true   # nil for account-level events or an unbound repo

enum :provider, { github: 0, linear: 1 }

validates :event_type, presence: true
# external_id (unique per provider when present — delivery dedup),
# payload (jsonb), source_installation_id.

scope :recent,      -> { order(created_at: :desc) }
scope :for_project, ->(project) { where(project: project) }

after_create_commit :dispatch_routines   # the trigger half (RoutineDispatchJob)

def present
  # WebhookEvent::Presenter (or Presenter::Linear) — table-less
  # activity-line presenters in app/models/webhook_event/.
```

## LlmProvider & LlmModel

The deployment's LLM catalog — what the composer offers and the cost basis
for usage. Curated by a superuser, refreshed from pi by
`Agent::ModelCatalogSync` (pi's `get_available_models` is the source of
truth for *what exists*; rows add operator curation). Deployment-level, like
provider API keys — no per-user catalog.

```ruby
# LlmProvider
has_many :llm_models, dependent: :destroy
# key (e.g. "anthropic"), label, position. Unique on key.

# LlmModel
belongs_to :llm_provider
# key, label, context_window, max_tokens, reasoning (bool),
# input_modalities (jsonb), cost (jsonb), enabled, position, last_seen_at.
# Curation (enabled/label/position) is sticky across syncs; models pi
# stops reporting are kept and flagged stale by last_seen_at, never deleted.
```

## Skill

A team's DB-authored pi skill, layered into `workspace/.pi/skills/<slug>/`
each turn alongside the repo's versioned skills. Imported from GitHub via
`Agent::SkillImporter` / `Agent::SkillMarketplace`.

```ruby
belongs_to :team
belongs_to :created_by, class_name: "User", optional: true
belongs_to :updated_by, class_name: "User", optional: true
# slug (unique per team), description, content_cache, metadata (jsonb),
# enabled.
```

## Invitation

Invite-only registration: a pending membership offer to an email.

```ruby
belongs_to :team
belongs_to :invited_by, class_name: "User"
enum :role, { member: 0, admin: 1, owner: 2 }
# email, token (unique), expires_at, accepted_at. Unique on
# (team, email) while unaccepted.
```

## ArtifactShare

A public link for one artifact blob. The share unit is the **blob** (its
content), so it stores no message/conversation reference — `team_id` is
denormalized at create time and carries ownership from then on.

```ruby
belongs_to :team
belongs_to :blob, class_name: "ActiveStorage::Blob"   # unique index on blob_id
belongs_to :created_by, class_name: "User"

# token — the public URL handle, generated before_create.

scope :minted_by,     ->(user) { where(created_by: user) }
scope :accessible_to, ->(user) { … }  # only shares whose blob is an artifact
                                      # of a conversation the viewer can open

# share_blob!(blob:, message:, user:) — idempotent and race-safe:
#   create_or_find_by! on the unique blob_id index.
```

## McpOauthClient

Dynamic Client Registration record per MCP issuer (the DCR spike, #36) —
one row per `issuer`, holding the registered `client_id` / `client_secret`
and the raw `registration` response. Distinct from `OauthGrant` (per-user
tokens) and provider apps (static OAuth app config).

## Read models (no table)

`Board`, `BoardPresence`, and `Sharing` live in `app/models/` but back
**no table** — pure per-request projections that never write state.
`Board` and `BoardPresence` project `WorkflowRun` / `Task` state for the
cross-project run board (`BoardController`); both take
`(team:, user:, scope:, project_ids:)` and read from
`Conversation.board_visible`, so the grid and the actor rail share one
visibility definition.

### Board

```ruby
COLUMNS         = %i[queued running awaiting_approval awaiting_local done]
SCOPES          = %i[all mine needs_me]
DONE_WINDOWS    = { "24h" => 24.hours, "7d" => 7.days, "2w" => 2.weeks,
                    "1m" => 1.month, "all" => nil }   # nil lifts the age bound
# COLUMN_FOR_STATUS maps the 8 WorkflowRun statuses onto the 5 columns
# (pending+running → running; completed/failed/cancelled → done).

Board.for(team:, user:, scope: :all, project_ids: [], window: 24.hours)
def lanes            # [Lane(project:, columns:)], ordered by each
                     #   project's most-recent run; "no project" lane last
def column_totals    # run count per column, summed across lanes
def needs_you_count  # visible runs awaiting_approval / awaiting_local
```

Active-status runs always show; terminal runs are bounded by `window`
(except `scope: :needs_me`, which lists only awaiting runs).

### BoardPresence

```ruby
ONLINE_WINDOW = 2.minutes   # bridge_seen_at newer than this → online

Person  = Struct(:member, :gate_ref, :gate_count) { def idle? = gate_count.zero? }
Machine = Struct(:owner, :client, :online, :seen_at, :task_ref) { def online? = online }

def people     # all team members, those with an open gate first
def machines   # members who minted a bridge token, online first
def online_count
```

Presence is deliberately **coarse** — one heartbeat per bridge session,
so a machine is only online vs stale, never per-worker. The roster
(people + machines) stays team-wide; only what each is shown *doing*
(open gates, the delegated `Task#ref` they hold) narrows to the filters,
and a private run's ref never leaks to a viewer who can't see it.

### Sharing

The Sharing page's read model: a team's public shares, scoped like the
chats sidebar.

```ruby
Sharing.for(team:, user:, scope: :mine, kind: :all)
# scope — :mine (what the viewer created; every card revocable) or
#         :team (what teammates expose from conversations the viewer may open)
# kind  — :all / :chats / :artifacts
def items  # one stream, newest first — shared Conversations and
           # ArtifactShares interleaved in the order they were shared
```
