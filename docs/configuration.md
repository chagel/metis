# Configuration

pi's runtime and credentials are configured through the environment
(`.env` in development; both `bin/dev` via foreman and Docker Compose load
it). Copy the template to start, then fill in what you need:

```sh
cp .env.example .env
```

`.env` only feeds local runs. A **Kamal deployment** takes its
environment from `config/deploy.yml` instead: plain values under
`env.clear` (ERB-interpolated from `.env.deploy` at deploy time),
secret **names** under `env.secret`, resolved at deploy through
`.kamal/secrets` (this repo's pulls them from Rails production
credentials). Every variable below applies the same way in both worlds —
`.env` for development, `deploy.yml` + `.kamal/secrets` for production.
Step-by-step deploy guide: [`deployment.md`](deployment.md).

**`bin/rails metis:doctor`** prints this whole checklist against the
current environment — each subsystem as configured, missing, or
defaulted, with the exact variable names (exit code 1 when something
required is missing). In a deployment:
`kamal app exec "bin/rails metis:doctor"`.

## Environment variables

| Variable | Purpose |
|---|---|
| `METIS_AGENT_RUNTIME` | `local` (default), `docker`, `e2b`, `daytona`, or `microsandbox` |
| `METIS_AGENT_PROVIDER` / `METIS_AGENT_MODEL` | default LLM provider/model for pi |
| Provider API keys — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, … | see [Providers](#providers) |
| `SERPER_API_KEY` / `BRAVE_SEARCH_API_KEY` | web-search backend for the agent's `web_search` tool — recommended (DuckDuckGo rate-limits sandbox IPs); see [Web search](#web-search) |
| `SEARXNG_URL` | keyless web-search alternative — base URL of a self-hosted SearXNG with the JSON format enabled; see [Web search](#web-search) |
| `METIS_DOCKER_IMAGE` | image for the `docker` runtime (default `metis-pi`) |
| `METIS_DOCKER_RUNTIME` | OCI runtime for `docker`-runtime containers — unset = daemon default (`runc`); `runsc` for gVisor (see [coding runtime](coding-runtime.md)) |
| `METIS_DOCKER_WORKSPACE_EVICTION_HOURS` | idle hours before a Docker conversation's persistent `workspace/` is warm-evicted (default 72, invalid fails boot) — see [session persistence](session-persistence.md) |
| `E2B_API_KEY` / `METIS_E2B_TEMPLATE` | required by the `e2b` runtime |
| `DAYTONA_API_KEY` / `METIS_DAYTONA_SNAPSHOT` | required by the `daytona` runtime |
| `DAYTONA_API_URL` / `DAYTONA_TARGET` | optional Daytona API endpoint / region |
| `METIS_DAYTONA_AUTO_STOP_MINUTES` / `_AUTO_ARCHIVE_MINUTES` / `_AUTO_DELETE_MINUTES` | Daytona idle-lifecycle intervals, minutes (default 120 / 60 / 1440). Stop is a crash-only safety net — keep it above the longest turn. |
| `METIS_MICROSANDBOX_IMAGE` | OCI image for the `microsandbox` runtime (default `metis-pi`) — pulled from a registry, so push the `docker:image` build somewhere the worker can reach |
| `METIS_MICROSANDBOX_REGISTRY_USERNAME` / `_PASSWORD` | optional registry credentials for that pull (an existing `docker login` is honored without them) |
| `METIS_MICROSANDBOX_WORKSPACE_QUOTA_MIB` | optional guest-write budget on the bind-mounted conversation scope (unset = the runtime's 4 GiB default) |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, … | outbound email over SMTP — see [Email & access](#email--account-access) |
| `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_EMAIL_API_TOKEN` | outbound email via Cloudflare Email Service — see [Email & access](#email--account-access) |
| `METIS_MAIL_DELIVERY` | mail transport: `smtp` (production default), `cloudflare`, or `test` (development default — no real send) |
| `METIS_MAIL_FROM` | sender for all email (on a domain your transport may send for) |
| `METIS_APP_HOST` | host for links in emails (invites, password reset) |
| `METIS_REGISTRATION_MODE` | `invite_only` (default) or `open` |
| `METIS_ALLOWED_DOMAINS` | comma-separated email domains that may register without an invitation in invite-only mode (default empty — off) |
| `METIS_LANGFUSE_ENABLED` | export per-turn token/cost traces to Langfuse — see [Observability](observability.md) |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST` | Langfuse credentials + endpoint (host defaults to `https://cloud.langfuse.com`) |
| `METIS_LANGFUSE_INCLUDE_CONTENT` | also export prompt/completion text (off by default — `Message#content` is encrypted) |
| `METIS_BRIDGE_CLAIM_TTL_MINUTES` | minutes a claimed delegated task may stay silent before the sweeper reclaims it (default 15) — see [local bridge](local-bridge.md) |
| `METIS_BRIDGE_RECLAIM_CAP` | reclaims before a delegated task fails instead of re-queueing (default 3) |

## Runtimes

The runtime decides *where* pi runs. See `coding-runtime.md` and
`session-persistence.md` for the deep dive.

- **`local`** — pi runs as a local subprocess. Fast, but **not an
  isolation boundary**: pi has shell access to the host. For
  single-operator / development use.
- **`docker`** — pi runs in a Docker container: namespace isolation,
  dropped capabilities, and resource limits, on a shared kernel.
  Self-hosted, needs a Docker daemon. Build the image once:

  ```sh
  rake "docker:image[metis-pi]"
  ```
- **`e2b`** — pi runs inside an isolated [E2B](https://e2b.dev) microVM.
  Build the sandbox template once:

  ```sh
  rake "e2b:template[metis-pi]"
  ```
- **`daytona`** — pi runs inside an isolated
  [Daytona](https://www.daytona.io) elastic sandbox. The Daytona analog
  of `e2b`, but the economics differ: an E2B suspended sandbox is free,
  whereas Daytona still bills a *stopped* sandbox for disk storage and an
  *archived* one (cheaper, slower to resume) less. So metis stops the
  sandbox each turn to end compute billing, and Daytona's native
  auto-archive/auto-delete intervals manage the residual storage cost of
  idle conversations (no metis eviction cron). Build the snapshot once:

  ```sh
  rake "daytona:snapshot[metis-pi]"
  ```
- **`microsandbox`** — pi runs inside a self-hosted
  [microsandbox](https://microsandbox.dev) libkrun microVM, driven
  in-process by the [`microsandbox-rb`](https://rubygems.org/gems/microsandbox-rb)
  gem — no daemon, no cloud API. VM-grade isolation (its own guest
  kernel) on the worker's own hardware; requires Linux with KVM or macOS
  on Apple Silicon. The gem rides an optional bundler group (it compiles
  a Rust native extension), so opt in on the hosts that run it:

  ```sh
  bundle config set --local with microsandbox && bundle install
  ```

  The runtime boots the `docker:image` build as its guest — push it to a
  registry the worker can pull from and point `METIS_MICROSANDBOX_IMAGE`
  at it. Persistence follows the `docker` runtime: a disposable VM per
  turn over a persistent host bind mount (see
  [session-persistence](session-persistence.md)).

Every runtime carries the **MCP connector bridge**
([`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter)):
`bin/setup` installs it into your local pi, and the `docker` image,
`e2b` template, and `daytona` snapshot bake it in at build time. The
X connector needs only deployment OAuth config (`X_CLIENT_ID`,
`X_CLIENT_SECRET`, `X_REDIRECT_URI` — ENV first, then Rails
credentials `x.*`). See `connectors.md`.

## Providers

Metis runs on **your provider** — there is no Metis-hosted inference.
Anything [pi supports](https://pi.dev/docs/latest/providers) works here,
picked per conversation in the new-chat composer. Set whichever keys you
want available; conversations only see providers your deployment is
keyed for.

| Env var | Provider |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI (GPT) |
| `GEMINI_API_KEY` | Google (Gemini) |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `XAI_API_KEY` | xAI (Grok) |
| `GROQ_API_KEY` | Groq |
| `CEREBRAS_API_KEY` | Cerebras |
| `MISTRAL_API_KEY` | Mistral |
| `MOONSHOT_API_KEY` | Moonshot AI (Kimi) — both the international (`moonshotai`) and CN (`moonshotai-cn`) endpoints read this var; enable the provider matching where the key was issued |
| `OPENROUTER_API_KEY` | OpenRouter |
| `TOGETHER_API_KEY` | Together AI |
| `FIREWORKS_API_KEY` | Fireworks |
| `HF_TOKEN` | Hugging Face |

Variable names mirror pi's own conventions so the same env that runs pi
locally works here. The new-chat composer's model list is the deployment
LLM catalog — synced from pi and curated by a superuser at **Settings →
Models**. After setting a provider's key, click **Refresh** there to pull
that provider's models into the catalog, then enable the ones to offer.

## Web search

The agent's `web_search` tool comes from the bundled **web-tools** pi
extension (`.pi/extensions/web-tools/`). It picks a backend per turn from
the first configured provider, then falls through to the next only on error:

1. **Serper.dev** — set `SERPER_API_KEY`. Google results via a fast, cheap
   REST API that works from datacenter IPs. Get a key at
   [serper.dev](https://serper.dev).
2. **Brave Search API** — set `BRAVE_SEARCH_API_KEY`. An independent index,
   also datacenter-friendly. Get a key at
   [brave.com/search/api](https://brave.com/search/api/).
3. **SearXNG** — set `SEARXNG_URL` to a self-hosted instance with the `json`
   format enabled (`search.formats` in its `settings.yml`). Keyless, but you
   operate the instance.
4. **DuckDuckGo** — the keyless last resort, used when none is set. It
   rate-limits datacenter IPs (returns a 202 bot-challenge), so it routinely
   fails inside the `docker`/`e2b`/`daytona`/`microsandbox` sandbox
   runtimes — configure Serper or Brave for reliable search there.

The keys are shared, deployment-level resources (no per-user keys), plumbed
into the sandbox by `Agent::Runtime::Base#sandbox_env`.

## Email & account access

Transactional email — team invitations and Devise's password reset —
goes out through the transport `METIS_MAIL_DELIVERY` names: `smtp` (the
production default), `cloudflare`, or `test` (the development default —
mail accumulates in `ActionMailer::Base.deliveries`, nothing is sent).
Credentials are read from ENV in `config/initializers/mail.rb`.

- **`smtp`** — Rails' built-in transport; works with any provider. Only
  `SMTP_ADDRESS` is required:

  | Variable | Default | Purpose |
  |---|---|---|
  | `SMTP_ADDRESS` | — | server hostname |
  | `SMTP_PORT` | `587` | |
  | `SMTP_USERNAME` / `SMTP_PASSWORD` | — | blank → connect without AUTH |
  | `SMTP_AUTHENTICATION` | `plain` | `plain`, `login`, or `cram_md5` |
  | `SMTP_DOMAIN` | — | HELO domain, if your provider requires it |
  | `SMTP_ENABLE_STARTTLS` | `true` | upgrade to TLS after connect |
  | `SMTP_TLS` | `false` | implicit TLS (SMTPS, port 465) |

  `SMTP_ENABLE_STARTTLS` is *opportunistic*: if the server doesn't offer
  STARTTLS the mail still goes out, in plaintext. For a server that must
  never fall back to plaintext, use `SMTP_TLS=true` (implicit TLS).

  Hosted senders — all STARTTLS on the default port 587:

  | Provider | `SMTP_ADDRESS` | Credentials |
  |---|---|---|
  | Amazon SES | `email-smtp.<region>.amazonaws.com` | dedicated SES SMTP credentials — not your AWS access key |
  | Mailgun | `smtp.mailgun.org` | domain SMTP login |
  | Postmark | `smtp.postmarkapp.com` | server API token as username and password |
  | SendGrid | `smtp.sendgrid.net` | username `apikey`, API key as password |
  | Resend | `smtp.resend.com` | username `resend`, API key as password |

- **`cloudflare`** — Cloudflare Email Service's REST API
  (`Delivery::Cloudflare`). Set `CLOUDFLARE_ACCOUNT_ID` and a send-scoped
  `CLOUDFLARE_EMAIL_API_TOKEN`; the sender domain must be verified in
  that account.

- **Anything a gem registers** — the value passes straight to
  ActionMailer, so e.g. `aws-actionmailer-ses` (`sesv2`) or
  `postmark-rails` (`postmark`) works: add the gem, configure it per its
  README, set `METIS_MAIL_DELIVERY` to its name.

`METIS_MAIL_FROM` is the sender — an address on a domain your transport
may send for. `METIS_APP_HOST` is the host links in those emails resolve
to (production; a shared dev host uses `METIS_DEV_HOST`).

Account creation is the access boundary — every account runs the agent on
the deployment's shared provider keys — so `METIS_REGISTRATION_MODE`
defaults to **`invite_only`**: only invitees (and the first, bootstrap
account) may register. Set it to `open` to let anyone sign up. See
[`teams.md`](teams.md) for the invitation flow.

`METIS_ALLOWED_DOMAINS` opens a second door in invite-only mode: emails on
the listed domains (`acme.com,corp.example.com`) may register without an
invitation. Matching is case-insensitive and exact — no subdomains. Note
the trust model: the password form does **not** verify mailbox ownership
(Metis has no email confirmation step), so anyone *claiming* an allowed
address can register; OAuth sign-ups only match on provider-verified
emails. Use it on domains where that trade-off is acceptable.
