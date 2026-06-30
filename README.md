# Metis

[![CI](https://github.com/chagel/metis/actions/workflows/ci.yml/badge.svg)](https://github.com/chagel/metis/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/chagel/metis/pulls)

**Self-host a team of AI agents that don't just chat — they *work*: in a
sandbox, on your stack, with your own LLM provider.**

Metis is an open, self-hostable agent platform. A real agent with shell and
coding tools, reaching your systems through connectors — sandboxed,
multi-user, on the provider you choose. Coding is one capability, not the
boundary.

<table>
  <tr>
    <td><img src="docs/metis-2606.png" alt="Run board" height="340"></td>
    <td><img src="docs/metis-2605.png" alt="Chat UI" height="340"></td>
  </tr>
  <tr>
    <td align="center">Run board — every team's work in flight</td>
    <td align="center">Live streaming chat with the agent</td>
  </tr>
</table>

## Why Metis

- **Agents that act, not just answer.** Shell, file tools, and connectors
  (GitHub, Google, Linear, Metabase, …) — the agent reads, runs, edits, and
  hands back artifacts, sandboxed by default.
- **Multi-user from day one.** Every resource belongs to a team, and the
  agent acts as the *right person* against the right systems — credentials
  per team and per member. A personal account is just a team of one.
- **Your provider, your infrastructure.** Anthropic, OpenAI, Google, or
  whatever comes next, picked per conversation. No Metis-hosted inference,
  no per-user key vault.
- **Build your own tools, and share them.** Author skills in the UI (or have
  the agent write them) and share them across your devices and your team.

## What people do with it

Not hypothetical: Metis's sibling, **[Themis](https://pipihosting.github.io/themis/)**,
runs daily in three languages at a company managing 1,000+ properties — one
platform, every role:

- **Engineering** — review a PR for the landmines green tests sail past
  (a locking migration, a hardcoded credential, a fee missing from the
  total), then file it as a Linear ticket.
- **Operations** — run the rental operation across countries: OTA
  cancellations and calendar sync, pricing schedules, utilities and tax.
- **Customer service** — draft discount emails, chase a booking anomaly,
  check whether an inbound email is genuine.
- **Leadership** — audit dashboard metrics, pull KPI rankings, prep the
  team-meeting agenda.

Themis is Claude-only (Claude Agent SDK); Metis is the open,
provider-agnostic form of the same shape, built on **[pi](https://pi.dev)**,
a fast, open agent harness. The lessons come along; the lock-in does not.

> pi runs on your laptop. Metis runs pi for everyone you work with — in a
> sandbox, on your stack, with your provider.

- **[`VISION.md`](VISION.md)** — what Metis is, the rules we hold to, what we won't build.
- **[`docs/architecture.md`](docs/architecture.md)** — how a turn flows; the Agent service layer.
- **[`docs/configuration.md`](docs/configuration.md)** — runtimes, providers, and environment.

## Stack

- **Rails 8.1**, Ruby 4.0.5, PostgreSQL
- **pi** agent harness, driven via the [`pi-agent-rb`](https://github.com/chagel/pi-agent-rb) gem
- **Any LLM provider [pi supports](https://pi.dev/docs/latest/providers)**, chosen per conversation
- **Hotwire** (Turbo + Stimulus, importmap) and **Tailwind** for the live chat UI
- **Devise** for auth; **Solid Queue / Cache / Cable** for jobs, cache, and Action Cable

## Quickstart

First, copy the env template and set at least one provider key (e.g.
`ANTHROPIC_API_KEY`) so the agent can talk to a model:

```sh
cp .env.example .env   # then edit it: set ANTHROPIC_API_KEY (or another provider)
```

Then start it with Docker — nothing local to install but Docker.
`compose.yaml` bakes Ruby, pi, the MCP bridge, and the gws CLI into the dev
image, runs Postgres alongside, and serves the agent on the `local` runtime
inside the container at http://localhost:3000.

```sh
docker compose up --build   # first run, or after a Gemfile change
docker compose up           # subsequent runs
```

See [`docs/configuration.md`](docs/configuration.md) for runtimes,
providers, and every variable.

## Development

```sh
bin/rails test   # full Minitest suite
bin/rubocop      # lint (rubocop-rails-omakase)
bin/ci           # rubocop, security scans, and tests
```

See [`docs/architecture.md`](docs/architecture.md) and
[`CLAUDE.md`](CLAUDE.md) for architecture and conventions.
