# Configuration

pi's runtime and credentials are configured through the environment
(`.env` in development; both `bin/dev` via foreman and Docker Compose load
it). Copy the template to start, then fill in what you need:

```sh
cp .env.example .env
```

## Environment variables

| Variable | Purpose |
|---|---|
| `METIS_AGENT_RUNTIME` | `local` (default), `docker`, `e2b`, or `daytona` |
| `METIS_AGENT_PROVIDER` / `METIS_AGENT_MODEL` | default LLM provider/model for pi |
| Provider API keys — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, … | see [Providers](#providers) |
| `SERPER_API_KEY` / `BRAVE_SEARCH_API_KEY` | web-search backend for the agent's `web_search` tool — recommended (DuckDuckGo rate-limits sandbox IPs); see [Web search](#web-search) |
| `SEARXNG_URL` | keyless web-search alternative — base URL of a self-hosted SearXNG with the JSON format enabled; see [Web search](#web-search) |
| `METIS_DOCKER_IMAGE` | image for the `docker` runtime (default `metis-pi`) |
| `METIS_DOCKER_RUNTIME` | OCI runtime for `docker`-runtime containers — unset = daemon default (`runc`); `runsc` for gVisor (see [coding runtime](coding-runtime.md)) |
| `E2B_API_KEY` / `METIS_E2B_TEMPLATE` | required by the `e2b` runtime |
| `DAYTONA_API_KEY` / `METIS_DAYTONA_SNAPSHOT` | required by the `daytona` runtime |
| `DAYTONA_API_URL` / `DAYTONA_TARGET` | optional Daytona API endpoint / region |
| `METIS_DAYTONA_AUTO_STOP_MINUTES` / `_AUTO_ARCHIVE_MINUTES` / `_AUTO_DELETE_MINUTES` | Daytona idle-lifecycle intervals, minutes (default 120 / 60 / 1440). Stop is a crash-only safety net — keep it above the longest turn. |
| `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_EMAIL_API_TOKEN` | outbound email — see [Email & access](#email--account-access) |
| `METIS_MAIL_FROM` | sender for all email (on the Cloudflare-verified domain) |
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

Every runtime carries the **MCP connector bridge**
([`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter)):
`bin/setup` installs it into your local pi, and the `docker` image,
`e2b` template, and `daytona` snapshot bake it in at build time. See
`connectors.md`.

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
   fails inside the `docker`/`e2b`/`daytona` sandbox runtimes — configure
   Serper or Brave for reliable search there.

The keys are shared, deployment-level resources (no per-user keys), plumbed
into the sandbox by `Agent::Runtime::Base#sandbox_env`.

## Email & account access

Transactional email — team invitations and Devise's password reset — is
sent through **Cloudflare Email Service**'s REST API (`Delivery::Cloudflare`),
not SMTP. Set `CLOUDFLARE_ACCOUNT_ID` and a send-scoped
`CLOUDFLARE_EMAIL_API_TOKEN`, and point `METIS_MAIL_FROM` at an address on
a **domain you've verified** in that Cloudflare account. `METIS_APP_HOST`
is the host links in those emails resolve to (production; a shared dev
host uses `METIS_DEV_HOST`). With the token unset, development falls back
to ActionMailer's `:test` delivery (no real send).

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
