# Deployment

Metis's reference deployment is [Kamal](https://kamal-deploy.org)
(bundled — run it as `bundle exec kamal`): it builds the Docker image,
pushes it to a registry, and runs it on your servers over SSH. One image,
two roles:

- **web** — the Rails app behind kamal-proxy
- **job** — the Solid Queue worker (`bin/jobs`), which also launches the
  agent sandbox containers when `METIS_AGENT_RUNTIME=docker`

The committed `config/deploy.yml` is a real deployment description, not a
neutral template — replace the hosts, registry, and any feature blocks
you don't use.

## What you need

- a local checkout that runs (`bin/setup`) — Kamal and the credentials
  editor run from it
- one or two Linux hosts with Docker and SSH access (web and job can
  share a host)
- PostgreSQL, reachable from the hosts (four databases: app, cache,
  queue, cable)
- an S3-compatible bucket (user uploads and agent artifacts)
- a container registry the hosts can pull from
- a domain pointing at the web host
- an LLM provider key, and an email transport — SMTP or Cloudflare
  ([configuration.md](configuration.md#email--account-access))

## How configuration flows

| File | Committed | Role |
|---|---|---|
| `config/deploy.yml` | yes | the deployment: hosts, roles, all app env |
| `.env.deploy` | no | non-secret deploy-time values (IPs, hostname, IDs) that ERB interpolates into `deploy.yml` |
| `.kamal/secrets` | yes | maps each `env.secret` name to a source — this repo fetches them from Rails production credentials |
| `config/credentials/production.yml.enc` | yes (encrypted) | the secret store, decrypted by `config/credentials/production.key` |

At `kamal deploy` time `.env.deploy` fills the plain values,
`.kamal/secrets` resolves the secret names, and the merged env lands in
the containers. **`.env` is never read in production** — it only feeds
local runs.

## 1. Secrets — production credentials

```sh
bin/rails credentials:edit -e production
```

The first run creates `config/credentials/production.key` — gitignored;
back it up somewhere safe, it decrypts everything. Inside, mirror the
keys `.kamal/secrets` fetches (that file is the full manifest — absent
keys resolve to empty, which is fine for features you don't use). The
minimum:

```yaml
active_record_encryption:   # paste the output of: bin/rails db:encryption:init
  primary_key: ...
  deterministic_key: ...
  key_derivation_salt: ...
kamal:
  database_url: postgres://metis:PASS@db-host/metis_production
  cache_database_url: postgres://metis:PASS@db-host/metis_production_cache
  queue_database_url: postgres://metis:PASS@db-host/metis_production_queue
  cable_database_url: postgres://metis:PASS@db-host/metis_production_cable
providers:
  anthropic_api_key: sk-ant-...
aws:
  access_key_id: ...
  secret_access_key: ...
cloudflare:                 # cloudflare email transport; SMTP users
  email_api_token: ...      # put SMTP_PASSWORD in .kamal/secrets instead
```

Secrets elsewhere (plain env vars, 1Password, …)? Rewrite the matching
lines in `.kamal/secrets` — Kamal supports several adapters.

## 2. Deploy-time values — `.env.deploy`

```sh
cp .env.deploy.example .env.deploy
```

Fill in the server IPs, `METIS_HOST` (your domain), the S3 bucket and
region, and — if you use them — the Cloudflare account id and GitHub App
identifiers.

## 3. Edit `config/deploy.yml`

- **registry** — point `server`/`username` at yours (Docker Hub, GHCR,
  …) and add `KAMAL_REGISTRY_PASSWORD` to `.kamal/secrets`.
- **builder.arch** — `arm64` or `amd64`, matching your hosts.
- **proxy** — the committed config sets `ssl: false` (TLS terminated
  upstream). Serving the internet directly: `ssl: true` and kamal-proxy
  gets Let's Encrypt certificates itself.
- **email** — the committed transport is `cloudflare`; the comment in
  the file shows the SMTP swap.
- **agent runtime** — the committed config runs sandboxes as Docker
  containers under gVisor on the job host (step 4). For the hosted
  `e2b`/`daytona` runtimes instead: set `METIS_AGENT_RUNTIME`, add the
  API key, and delete the job role's socket/volume `options`.
- Delete the blocks for features you don't use (GitHub App, Langfuse) —
  a bare `ENV.fetch` fails the render when its `.env.deploy` value is
  missing.

## 4. Provision the job host (docker runtime only)

```sh
sudo ./docker/provision-job-host.sh
```

Idempotent: installs gVisor (`runsc`), creates `/srv/metis/agent`, and
verifies a container runs under gVisor. Also build the sandbox image on
the host daemon (`rake "docker:image[metis-pi]"` from a checkout, or
pass `--build-image`), and check `getent group docker` matches the
`group-add` gid in `deploy.yml`. Deep dive:
[coding-runtime.md](coding-runtime.md).

## 5. Deploy

```sh
bundle exec kamal setup    # first time — installs the proxy, boots everything
bundle exec kamal deploy   # every time after
```

The schema is created and migrated automatically on web boot
(`bin/docker-entrypoint` runs `db:prepare`). Handy aliases from
`deploy.yml`: `kamal console`, `kamal shell`, `kamal logs`, `kamal dbc`.

## 6. First login

Registration is invite-only by default, with one exception: the very
first account may sign up freely — that's you. Then:

- **Settings → Models → Refresh** pulls your provider's model catalog;
  enable the ones to offer.
- Invite your team from **Settings → Team** — the invitation email is a
  good end-to-end test of your mail transport.
- Wire up connectors: [connectors.md](connectors.md).

## Day 2

- **Update**: `git pull && bundle exec kamal deploy`. **Roll back**:
  `kamal rollback <version>`.
- **Back up** Postgres and the S3 bucket — they are the durable state.
  `/srv/metis/agent` holds live conversation workspaces; losing it costs
  working files, not chat history (the next turn rebuilds context from
  the `Message` history).
