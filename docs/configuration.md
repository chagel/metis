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
| `METIS_AGENT_RUNTIME` | `local` (default), `docker`, or `e2b` |
| `METIS_AGENT_PROVIDER` / `METIS_AGENT_MODEL` | default LLM provider/model for pi |
| Provider API keys — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, … | see [Providers](#providers) |
| `METIS_DOCKER_IMAGE` | image for the `docker` runtime (default `metis-pi`) |
| `E2B_API_KEY` / `METIS_E2B_TEMPLATE` | required by the `e2b` runtime |
| `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_EMAIL_API_TOKEN` | outbound email — see [Email & access](#email--account-access) |
| `METIS_MAIL_FROM` | sender for all email (on the Cloudflare-verified domain) |
| `METIS_APP_HOST` | host for links in emails (invites, password reset) |
| `METIS_REGISTRATION_MODE` | `invite_only` (default) or `open` |

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

Every runtime carries the **MCP connector bridge**
([`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter)):
`bin/setup` installs it into your local pi, and the `docker` image and
`e2b` template bake it in at build time. See `connectors.md`.

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
