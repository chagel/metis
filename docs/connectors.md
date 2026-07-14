# Connectors

## Context

metis connects the agent to external systems — business data through
something like Metabase, plus GitHub, Slack, Notion, and the rest. pi
itself ships **no MCP support**: a deliberate upstream omission, with the
standing recommendation to wrap CLI tools as *skills* instead.

So there is a fork. metis chooses **MCP, through a bridge extension** —
not the skill + CLI path pi recommends. This doc records why.

## Decision

A connector is an MCP server. metis reaches it through
**[`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter)** — a
mature, MIT-licensed pi extension that connects pi to MCP servers and
exposes their tools to the agent. metis adopts it rather than building a
bridge of its own; forking is the fallback if its programmatic-config gap
stalls upstream. CLIs are not used as the connector mechanism.

pi-mcp-adapter is a pi *package*, installed with `pi install` into each
pi environment at setup or image-build time — `bin/setup` for local dev,
the Docker image, the E2B template. pi auto-discovers it; metis neither
vendors it nor loads it explicitly.

The adapter reads its server list from an on-disk `.mcp.json`, so metis
**stages a `.mcp.json` per run** into the pi workspace — non-secret
server definitions and inline credentials, both rendered from the
`Connector` model. That file is a per-turn projected input, re-rendered each turn from
the durable `Connector` records, so the secrets never become durable
on disk. A fresh sandbox carries no other MCP config, so the staged
file is the only source.

## Why not skill + CLI

A CLI is an end-to-end application built for a human at a terminal on
their own machine. That shows up in three places that matter here.

**Authentication.** A CLI authenticates the way a desktop app does — a
browser device flow, an interactive login, a token cached in `~/.config`.
metis runs pi server-side, inside a sandboxed and disposable runtime, for
many users. There is no human, no browser, and no stable home directory
for that flow to land in. To make a CLI work, metis would have to obtain
the credential out-of-band and inject it — and every CLI invents its own
scheme for being handed one (`GH_TOKEN`, `~/.aws/credentials`, a flag, a
config file). Each connector becomes bespoke credential plumbing.

**No host.** A CLI assumes it *is* the top-level program, run directly by
its operator; it has no notion of running as a component inside a larger
host. MCP is the opposite — a protocol with explicit host / client /
server roles, where metis is a first-class **host**. MCP also defines a
standard OAuth 2.0 authorization flow, so metis implements connector auth
*once*, uniformly, instead of one integration per tool.

**Structured surface.** MCP servers expose typed tool schemas and return
structured results. A CLI returns stdout meant for human eyes, which the
agent has to scrape.

## Governance

metis is multi-user. Business-data connectors need team-level governance:
whose credentials a connection uses, who may use it, an audit trail. MCP's
model — the host holds credentials and passes them per connection — maps
directly onto metis owning a `Connector` resource. A CLI has no such
concept; pi, single-user by nature, could never provide it. **pi executes;
metis governs.**

A connector is owned through metis's single tenancy unit, the `Team` — a
personal account being a team of one (see `tenancy.md`). The resource
splits in two:

- **`Connector`** — the definition: which MCP server and its non-secret
  config. Visible to every member of the owning team.
- **`ConnectorCredential`** — `belongs_to :connector`, `belongs_to :user`
  (nullable), encrypted secret.

That nullable `user_id` carries both credential shapes in one table. A row
with `user_id: nil` is a **shared** credential — a service account the
whole team uses, typical for a data source like Metabase. A row with a
`user_id` is that member's **own** credential — typical for an
identity-bearing service like GitHub or Slack, where the agent should act
as that member.

Staging `.mcp.json` for member X resolves each connector to X's own
credential if present, else the shared credential, else omits the
connector from X's `.mcp.json`. That resolution point is also the audit
anchor: which member used which connector under which credential.

## Why pi recommends CLIs — and why metis differs

pi's recommendation is sound *for pi*. pi is a single-user coding agent
run locally by a developer who already has `gh`, `aws`, and friends
installed and authenticated on their own machine. In that context a CLI
*is* the native integration, and MCP is avoidable overhead.

metis's context is the inverse: server-side, multi-user, sandboxed, no
pre-authenticated tools, no interactive operator. The same reasoning that
makes skill + CLI right for pi makes MCP right for metis. This is not a
disagreement with pi — it is the same logic applied to a different
deployment.

## What MCP does not solve

MCP standardizes the credential bridge; it does not remove it. metis is
still the OAuth broker — it runs the authorization flow, stores per-user
and per-team tokens encrypted, and hands them to the bridge. The win is
*one* uniform implementation of the right shape, not zero work.

## OAuth, incremental — sign-in and connector are different acts

Metis splits the OAuth flow into two distinct phases, on the same
underlying provider grant:

* **Sign in** asks for the minimum identity scopes only
  (`email,profile` for Google, `user:email` for GitHub). The user
  picks an account, we record a `User` + `Identity` + a per-(user,
  provider) `OauthGrant` carrying those scopes. No connectors are
  wired by sign-in.
* **Connect <connector>** sends the user *back* through OAuth via
  `connector_authorize_path_for(app)`, which builds an authorize URL
  with `scope = sign-in scopes + connector's oauth_scopes`,
  `prompt: consent`, and `include_granted_scopes: true`. The new
  grant unions with the prior one; the callback marks the connector
  as wired for this user (a `ConnectorCredential` row with no
  secret — just presence).

The win: when the deployment adds a *new* connector later (Drive on
top of Gmail), the user sees consent only for the new scope — Google
shows the new permission and asks for it explicitly. The
all-or-nothing consent at sign-in is gone, and adding scopes after
the fact actually does prompt the user.

### Where the tokens live

* **`OauthGrant`** — one per `(user, provider)`. Holds the encrypted
  access + refresh tokens, the expiry, and the union of every scope
  ever granted. Single source of truth.
* **`ConnectorCredential`** — for OAuth-shaped connectors, this is a
  *marker*: its existence says "this member has wired this connector"
  and McpConfig will stage it. The actual bearer comes from the
  user's `OauthGrant`. For token-shaped connectors, this row holds
  the secret directly (no change).

`OauthBroker.access_token_for(grant)` mints/refreshes the access
token when staging `.mcp.json`, dispatching to the per-provider
client (`OauthBroker::Clients::Github`, `::Google`) based on the
grant's `provider`. McpConfig checks that the grant covers the
connector's `oauth_scopes` before staging; if not, the connector is
dropped from the file (the member needs to Connect through the
marketplace to add the missing scopes).

### Disconnect, prune, revoke

When a member disconnects an OAuth-shaped connector from the
marketplace, the `ConnectorCredential` is destroyed and the grant's
scope set is pruned to what the member's *remaining* connectors
still need. When no OAuth-shaped connectors are left for that
provider, `OauthBroker.revoke(grant)` severs the grant on the
provider's side (Google: `https://oauth2.googleapis.com/revoke`;
GitHub: `DELETE /applications/{client_id}/grant`) and the local
`OauthGrant` is destroyed too. That's the "fully sever" semantics —
the next Connect lands as a fresh consent screen because nothing is
on file anywhere.

### Per-provider notes

* **GitHub**: metis is wired for a **GitHub App** (not a classic OAuth
  App), and exposes **both** of its token paths as **two MCP servers
  the agent reaches at once** — it picks by purpose, not by config:
  - **`github`** — user-to-server (`ghu_`). The agent acts as the
    operator: commits carry their handle, PRs and comments are signed by
    them. Bearer is the member's live OAuth access token, projected from
    their `OauthGrant`. This is the everyday GitHub surface.
  - **`github_bot`** — installation (`ghs_`), acting as `<slug>[bot]`.
    Minted server-to-server from the App's id + private key by
    `GithubApp::InstallationToken` (JWT → `POST /app/installations/
    :id/access_tokens`), cached ~50 min. Which installation it acts
    through resolves in order: the connector's own choice
    (`Connector#bot_installation_id`, picked per team on the manage
    page when the App has several installs), else the deployment's
    `GITHUB_APP_INSTALLATION_ID`, else **auto-resolved** from the
    App's sole installation (`GET /app/installations`, cached). With
    several installs and no choice anywhere, resolution raises and
    the bot is skipped — pick one on the manage page.
    No bearer is stored. `McpConfig` stages this **second** server
    whenever the deployment is App-auth configured (`GITHUB_APP_ID` +
    `GITHUB_APP_PRIVATE_KEY`), the team has a `github` connector, **and an
    admin has turned the bot on** for it (`Connector#bot_enabled?` —
    `settings.bot_enabled`, off by default, set from the connector's
    manage page). A mint failure just omits it; it never crashes the turn.
    - **Authority scope**: the bearer is **installation-wide** — it can
      reach every repo the App is installed on for that account/org,
      independent of the operator's own access. That's broader than the
      user-scoped `github` token, and it is **team-wide**: once enabled,
      every member of the team gets `github_bot` in their turns and can
      act, via the bot, on repos their own grant can't touch. That's why
      it's an explicit admin opt-in, not an ambient default — the admin
      who owns the App installation accepts the sharing, and scopes it by
      limiting where the App is installed on GitHub.

  The split exists because some work wants bot attribution, not
  impersonation — chiefly **agent-authored PR reviews**: GitHub forbids
  approving your own PR, so a review posted through `github` can only
  comment, while `github_bot` can approve / request changes. The
  reviewing-code skill routes review posting to `github_bot` and leaves
  everything else on `github` — two identities a member can act through,
  the bot one being the admin-gated team-wide grant above.

  User-to-server has GitHub-App semantics — it preserves user identity
  (commits author as the operator), but it can only access resources
  where the App is **installed**. A subtle consequence: the OAuth
  response from a GitHub App **does not carry OAuth scopes** (the
  `scope` field is empty/omitted) — App permissions configured on the
  App's settings page are the real gate, not OAuth scopes on the wire.
  metis therefore can't gate "Connected" / staging / `GH_TOKEN`
  injection on `grant.covers?(catalog_scopes)` the way it does for
  Google or Linear — that check would always fail for GitHub.
  `OauthBroker.scope_check_meaningful?(provider)` is the central
  rule (false for `github`, true elsewhere); the four sites that
  used to gate on coverage (`ConnectorCredential#oauth_ready?`,
  `Agent::McpConfig`, `Agent::Identity`, `Runtime::Base#sandbox_env`)
  all respect it and fall back to "token present" for GitHub. *Signing in alone is not enough*: a token whose App
  isn't installed on any repo returns a 404 for every private repo,
  including the user's own. The "Connect GitHub" flow therefore
  redirects to `https://github.com/apps/<slug>/installations/new`
  after the OAuth callback, prompting the user to install the App on
  the repos they want metis to act on; when they return to the
  marketplace, the connector tile shows Connected and the agent's
  per-turn `GH_TOKEN` (see *Credential pass-through to the sandbox*)
  can finally reach private content.
  - Env: `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_CLIENT_SECRET`,
    `GITHUB_APP_SLUG` (the part after `apps/` in the install URL;
    without it metis skips the install redirect and the connect flow
    ends at the marketplace, leaving the user to find the install
    page themselves). For the installation (`ghs_`) path also set
    `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY` — the App's RSA key,
    base64-encoded to one line (`base64 < key.pem | tr -d '\n'`) so a
    multiline PEM can't break dotenv. `GithubApp::Config.private_key`
    base64-decodes it, and still accepts a raw or `\n`-escaped PEM as a
    fallback (anything carrying the `-----` banner is used verbatim).
    Absent these two, `app_auth_configured?` is false and the
    `github_bot` server simply isn't staged (the `github` user-to-server
    path is unaffected). `GITHUB_APP_INSTALLATION_ID` is optional — a
    deployment-wide default for multi-install Apps; each team's manage
    page can pick its own installation, which takes precedence.
    - Loaded by **foreman from `.env` at startup**, so adding these
      requires a `bin/dev` restart — a standalone `bin/rails runner`
      won't see them (no `dotenv-rails`).
  - App settings: enable **"User-to-server token expiration"**
    (Settings → Optional features); without it GitHub issues no
    refresh token and renewals fail when the 8-hour access token
    lapses.
  - Callback URL: `/users/auth/github/callback`. Connector scopes
    requested by the catalog: `repo`, `read:user`. (For a GitHub
    App these translate into App **permissions**, not classic OAuth
    scopes — `x-oauth-scopes:` on App tokens is always empty; don't
    diagnose access issues from that header.)
* **Google**: Devise sign-in passes `access_type: offline` for a
  refresh token, `prompt: select_account` so returning users can
  pick the right account without re-consent, and
  `include_granted_scopes: true` so per-connector grants union with
  the sign-in grant. Per-connector authorize URLs override with
  `prompt: consent`. Refresh responses omit `refresh_token`;
  `OauthGrant#absorb!` preserves the prior one.

### Linear — MCP connector, inbound webhooks, and the project picker

Linear involves **two independent token paths**, deliberately kept apart,
plus the OAuth app's own webhook:

1. **MCP-OAuth** (the connector itself) — the per-member token the agent
   uses to reach Linear's MCP server (`mcp.linear.app/mcp`), obtained via
   Dynamic Client Registration and stored on the member's
   `ConnectorCredential` (`mcp_oauth`). It authenticates **only** the MCP
   gateway — it is **not** accepted by `api.linear.app/graphql`.
2. **Direct Linear OAuth** (`linear.app/oauth`) — a deployment-registered
   OAuth app whose `read`-scoped token *does* work against the GraphQL
   API. One "Authorize Linear access" on the connector page
   (`Connectors::LinearOauthController`) does three things: stores the API
   token on the member's `ConnectorCredential` (`linear_api`), captures the
   authorizing workspace's **organizationId** onto the team's connector
   (for webhook routing), and — because authorizing the app subscribes the
   workspace — turns on its webhook deliveries. The token backs the
   project-binding **picker**: `Linear::Api` lists the member's projects so
   a `Project` binds **by name** (storing the UUID in
   `external_refs.linear_project`) instead of a pasted UUID.
   - Env: `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET`. Register the app at
     `linear.app/settings/api/applications` with callback URL
     `/settings/connectors/linear/callback`. Absent these, the connector page hides
     the "Authorize Linear access" button and the picker stays manual.

**Inbound webhooks** ride the same OAuth app (the GitHub-App shape, *not*
per-workspace manual setup). The app defines **one** webhook URL
(`/webhooks/linear`) and signing secret (`LINEAR_WEBHOOK_SECRET`, the
`lin_wh_…` from the app's settings page) and fires for every workspace that
authorized it. `Webhooks::LinearController` verifies the `Linear-Signature`
HMAC against that env secret, rejects a stale `webhookTimestamp` (>60s),
and records a `WebhookEvent` deduped on the `Linear-Delivery` id, resolving
the team by the payload's `organizationId` against the connector's stored
org id. Unmatched organizations are dropped (200, like GitHub).

### Google connectors — `gws` CLI, no MCP server

The Google connectors (Gmail, Google Calendar, Google Drive) do
**not** stage an MCP server. They are `transport: cli` catalog
entries: the agent reaches Google through
[`gws`](https://github.com/googleworkspace/cli), the Google
Workspace CLI, which is baked into the runtime images alongside pi.

The per-turn token flow:

1. The user connects Gmail / Calendar / Drive through the standard
   Google OAuth consent screen. The token + granted scopes union
   into the user's single `OauthGrant` for `google`, exactly as
   they would for a hosted-MCP connector. A `ConnectorCredential`
   marker is recorded against a `Connector` row whose `transport`
   is `cli` and whose `definition` is empty.
2. At the start of each turn, `Runtime::Base#sandbox_env` resolves
   the user's `google` grant through `OauthBroker.bearer_for` and
   exports the access token as `GOOGLE_WORKSPACE_CLI_TOKEN` (plus
   `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` so `gws` doesn't
   reach for a desktop keyring in the headless sandbox). This is
   the same pattern as `GH_TOKEN` for GitHub.
3. `Agent::McpConfig` skips `cli`-transport connectors so they
   never land in `.mcp.json`. The shipped `gws-*` skills in
   `.pi/skills/` tell the agent how to drive `gws gmail`,
   `gws calendar`, `gws drive`, etc. The bearer's scopes decide
   what calls succeed.

Why CLI instead of an MCP server: the previous setup ran a
self-hosted `google_workspace_mcp` in `MCP_ENABLE_OAUTH21=true` /
`EXTERNAL_OAUTH21_PROVIDER=true` mode, which depends on Google's
MCP Developer Preview program. That program only accepts verified
Workspace business accounts — personal `@gmail.com` developers are
rejected — and approval is per GCP project. Switching to the
CLI+skills pattern removes that distribution blocker; the OAuth
side is plain sensitive-scope verification, available from any
project. See `FLA-19` for the full rationale and the VISION.md
tradeoff it forces.

The runtime images install `gws` via `npm install -g
@googleworkspace/cli`, which downloads the matching pre-built
binary from the project's GitHub Releases. Shipped skills live
under `.pi/skills/gws-*` and were pulled from
`https://github.com/googleworkspace/cli/tree/main/skills` — a
curated subset: `gws-shared`, plus the Gmail, Calendar, and Drive
skill families.

Expand a connector's `oauth_scopes` to unlock more `gws` surface
on that service — e.g. add `gmail.send` if you want the agent to
send mail without going through a draft.

### X — hosted MCP, brokered bearer

The X connector reaches X's **hosted MCP server** (`api.x.com/mcp`)
directly: a plain streamable-HTTP entry whose `Authorization: Bearer`
header carries the member's current access token — the same shape as
the GitHub connector. X offers no Dynamic Client Registration, so this
is a **brokered OAuth** connector like GitHub/Google — but X is not a
sign-in provider, so the flow runs through a dedicated controller
(`Connectors::XOauthController`, authorization-code + PKCE `S256`,
one-time 10-minute state in the initiator's session) instead of
omniauth.

- **Deployment config** — resolved per key, ENV first, then Rails
  credentials: `X_CLIENT_ID`/`x.client_id`,
  `X_CLIENT_SECRET`/`x.client_secret`, `X_REDIRECT_URI`/`x.redirect_uri`.
  The redirect URI is configured, not derived, because X rejects any
  callback that doesn't **exactly** match the app's registered URI —
  register `https://<your-host>/settings/connectors/x/callback` in the X
  Developer Portal and set `X_REDIRECT_URI` to the same string. All
  three present ⇢ the marketplace tile connects; any missing ⇢ the tile
  shows "X is not configured on this Metis deployment" (and
  `metis:doctor` reports which key). X's API plan gates apply: the
  hosted MCP tools need an enrolled developer account.
- **Scopes** (asked once, on the first consent): `tweet.read
  tweet.write users.read bookmark.read bookmark.write offline.access`.
  Broad write consent up front is a deliberate v1 choice — there is no
  incremental-consent flow yet.
- **Tokens** live in the member's `(user, "x")` `OauthGrant`
  (encrypted); the `ConnectorCredential` row is only the presence
  marker. `OauthBroker::Clients::X` refreshes near-expiry tokens
  (`XApp::Oauth`, HTTP Basic client auth); X **rotates the refresh
  token on every refresh**, and `OauthGrant#absorb!` persists both
  tokens in one save. `invalid_grant` clears the grant so the next
  Connect re-consents; the turn still runs, just without X.
- **Per-turn staging** — `Agent::McpConfig` stages the `x` server only
  when the member has a usable grant, through the generic catalog
  `credential` block: the entry's headers carry the current access
  token as a bearer, refreshed before staging. Only the short-lived
  access token reaches the sandbox — never the client secret or
  refresh token. If the access token expires during a turn, the MCP
  call fails and the broker refreshes it before the next turn. Nothing
  is installed in the runtimes for this connector.

## Identities, not a single provider per user

A user has many `Identity` rows — one per provider they've signed in
through or whose connector they've authorized. Sign-in looks up the
user by `(provider, uid)` first and falls back to email match, so a
GitHub user can additionally connect Google (and vice versa) without
forking a second account.

## Credential pass-through to the sandbox

Not every operator-as-agent action is an MCP call. Coding — `git clone`,
edit, commit, `gh pr create` — happens in the agent's shell, against a
working tree pi manages itself. That path needs the same identity-bearing
credential the MCP connector uses, but delivered as a process env var the
shell tools understand.

So the runtimes do exactly that: at turn start, the sandbox runtimes
(`Docker`, `E2b`) read the operator's `OauthGrant`s and project the
relevant bearers as **per-turn process env** into the agent's process —
not into a file, not into a Rails record. For GitHub: when the operator
has a grant covering the `repo` scope, the sandbox process gets
`GH_TOKEN` (consumed by `git` and `gh`) plus `GIT_AUTHOR_*` /
`GIT_COMMITTER_*` set to the operator's identity so commits carry their
handle. `Runtime::Base#sandbox_env` is the single point of composition.

The bearer reaches the container without sitting in `docker run` argv:
`--env GH_TOKEN` (no value) tells docker to forward the var from the
spawned client's environment, and `PiAgent.session(env: …)` sets it
there. `E2b` passes the same hash through `commands.run(envs: …)`. The
token has the lifetime of one `docker run` (or one E2B command), and is
gone with the container.

The threat model worth being explicit about: this credential isolation
is about **scope and lifetime, not about hiding bytes from the agent**.
The agent has to use the credential to push, so hiding it from a process
authorised to spend it would be theatre. What we actually defend is
duration (one turn) and breadth (whatever scopes the operator granted)
— and the audit trail is GitHub's own log, attributed to the operator,
not a Metis-side per-repo state plane.

`Runtime::Local` deliberately opts out: a dev's host already has their
own `gh`/`git` config, and injecting `GH_TOKEN` there would clash with
it. The sandbox runtimes are the ones with no operator at the terminal,
so they're the ones that need the projection.

## Accepted tradeoff

A service that ships only a CLI, with no MCP server, is not connectable
until an MCP server exists for it. This is an acceptable bet: MCP adoption
is fast and increasingly first-party — GitHub and Metabase both ship
official MCP servers today.

Skills are not abandoned. They remain pi's mechanism for *non-connector*
capability — a code-review skill, a commit-message helper. What is ruled
out is using CLIs as the way to reach authenticated external services.
