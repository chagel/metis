# Metis

[![CI](https://github.com/chagel/metis/actions/workflows/ci.yml/badge.svg)](https://github.com/chagel/metis/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/chagel/metis/pulls)

**Self-host a team of AI agents that don't just chat — they *work*: in a
sandbox, on your stack, with your own LLM provider.**

Metis is an open, self-hostable agent platform. It puts a live, streaming
web chat in front of a real agent that ships shell and coding tools and
reaches your systems through connectors — running sandboxed, multi-user,
on the provider you choose. Coding is one capability, not the boundary.

![Metis chat UI](docs/metis-2605.png)
<!-- TODO: replace with a short GIF of one turn — streaming, a tool call, an artifact dropped into the reply. -->

## Why Metis

- **Agents that act, not just answer.** The agent has a shell, file tools,
  and connectors (GitHub, Google, Linear, Metabase, …). It reads, runs,
  edits, and hands back artifacts — sandboxed by default. Not a chat box
  bolted to an API.
- **Multi-user from day one.** Every resource belongs to a team, and the
  agent acts as the *right person* against the right systems — credentials
  held per team and per member. A personal account is just a team of one.
- **Your provider, your infrastructure.** Anthropic, OpenAI, Google, or
  whatever comes next, picked per conversation. No Metis-hosted inference,
  no per-user key vault — you self-host the whole thing.
- **Build your own tools, and share them.** Personal productivity is the
  floor, not the ceiling: author skills in the UI (or have the agent write
  them) and share them across your devices and your team.

## What people do with it

Real work from its daily deployment — one platform, every role
(see [Proven shape](#proven-shape)):

- **Engineering** — review a PR and surface the landmines green tests sail
  past: a migration that locks existing users out, a hardcoded SMTP
  credential, a guest fee that never made it into the order total. Judged
  against the design intent, then filed as a Linear ticket.
- **Operations** — run the rental operation across countries:
  ota cancellations and calendar sync, pricing schedules, listing
  titles, utilities and tax entry.
- **Customer service** — draft returning-customer discount emails, chase a
  booking price anomaly, check whether an inbound email is genuine.
- **Leadership** — audit dashboard metric, pull kpi rankings, set up goals,
  prep the team-meeting agenda.
- **Anyone** — drop in multi-medias via multiple channels and get it back
  analyzed with operational insights and suggestions; share the conversation
  with a teammate.

## Proven shape

Metis didn't start from a blank page. Its sibling, **[Themis](https://pipihosting.github.io/themis/)**,
runs daily across engineering, operations, customer service, and
leadership at a company managing 1,000+ properties — reviewing PRs, filing
tickets, auditing dashboards, and running the rental operation in three
languages. The kind of internal platform people stop noticing because it
has folded into how they work.
Themis is Claude-only (built on the Claude Agent SDK); Metis is the open,
provider-agnostic form of the same shape, built on **[pi](https://pi.dev)**,
a fast, open agent harness. The lessons come along; the lock-in does not.

> pi runs on your laptop. Metis runs pi for everyone you work with — in a
> sandbox, on your stack, with your provider.

- **[`VISION.md`](VISION.md)** — what Metis is, the rules we hold to, what we won't build.
- **[`PLAN.md`](PLAN.md)** — current status, roadmap, and open questions.
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
`ANTHROPIC_API_KEY`) so the agent can talk to a model — both setups below
load `.env`:

```sh
cp .env.example .env   # then edit it: set ANTHROPIC_API_KEY (or another provider)
```

Then pick **native** or **Docker**; either serves the app at
http://localhost:3000.

### Native

Run the app directly on your machine. Prerequisites: **Ruby 4.0.5** (see
`.ruby-version`; `mise` recommended), **PostgreSQL**, and **pi** on your
`PATH` for the default `local` runtime
(`npm install -g @earendil-works/pi-coding-agent`).

```sh
bin/setup        # install deps, prepare the database, install the MCP bridge into pi
bin/dev          # Puma + Tailwind via foreman → http://localhost:3000
```

### Docker

Nothing local to install but Docker — `compose.yaml` bakes Ruby, pi, the
MCP bridge, and the gws CLI into the dev image, runs Postgres alongside,
and serves the agent on the `local` runtime inside the container.

```sh
docker compose up --build   # first run, or after a Gemfile change
docker compose up           # subsequent runs
```

Either way, see [`docs/configuration.md`](docs/configuration.md) for
runtimes, providers, and every variable.

> Metis encrypts `Message#content` and `Message#reasoning` with Active
> Record Encryption; the keys must be present in Rails credentials for
> every environment, tests included.

## Development

```sh
bin/rails test   # full Minitest suite
bin/rubocop      # lint (rubocop-rails-omakase)
bin/ci           # rubocop, security scans, and tests
```

See [`docs/architecture.md`](docs/architecture.md) and
[`CLAUDE.md`](CLAUDE.md) for architecture and conventions.
