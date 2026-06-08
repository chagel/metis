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
| `METIS_AGENT_RUNTIME` | default runtime: `local` (default), `docker`, `e2b`, or `daytona` |
| `METIS_ENABLED_RUNTIMES` | comma-separated runtimes offered in the per-chat picker (e.g. `docker,e2b`). Unset = only the default, no picker. See [Per-conversation runtime](#per-conversation-runtime) |
| `METIS_ALLOW_LOCAL_RUNTIME` | `1` to allow the non-isolated `local` runtime on the picker in production |
| `METIS_AGENT_PROVIDER` / `METIS_AGENT_MODEL` | default LLM provider/model for pi |
| Provider API keys — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, … | see [Providers](#providers) |
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
| `METIS_LANGFUSE_ENABLED` | export per-turn token/cost traces to Langfuse — see [Observability](observability.md) |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST` | Langfuse credentials + endpoint (host defaults to `https://cloud.langfuse.com`) |
| `METIS_LANGFUSE_INCLUDE_CONTENT` | also export prompt/completion text (off by default — `Message#content` is encrypted) |

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

### Per-conversation runtime

`METIS_AGENT_RUNTIME` is the deployment **default**. To let users choose
*where* a chat runs, list the runtimes a deployment offers in
`METIS_ENABLED_RUNTIMES` (comma-separated):

```sh
METIS_AGENT_RUNTIME=docker          # the default
METIS_ENABLED_RUNTIMES=docker,e2b   # the menu the picker shows
```

- The picker appears in the new-chat composer only when more than one
  runtime is enabled; a single-runtime deployment shows no picker and
  behaves exactly as before.
- A runtime listed here must be fully provisioned (image/template/key).
  The default is always usable whether or not it is listed.
- Runtime credentials stay **deployment-level** — the user picks a
  configured runtime, never brings their own.
- The choice is **fixed for the conversation's life**: each runtime
  persists the working tree in its own store, so switching mid-chat
  would strand it. The picker is new-chat only for that reason.
- `local` is **not** an isolation boundary, so it is dropped from the
  picker in production unless `METIS_ALLOW_LOCAL_RUNTIME=1`.
- Users can set a personal default runtime in their profile
  (`preferred_runtime`), still overridable per chat.

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
