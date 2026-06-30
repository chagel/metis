# Metis Vision

**pi runs on your laptop. Metis runs pi for everyone you work with —
in a sandbox, on your stack, with your provider.**

This is the soul of the project: what Metis is, what it isn't, and the
rules that keep it that way. Architecture lives in [`docs/`](docs/).

## What this is

Metis is an open, self-hostable agent platform. It puts a live,
streaming web chat in front of **pi** — a fast, open agent harness
that ships coding tools but isn't bounded by them. The agent runs in a
sandbox by default. The LLM provider is yours. The connector model
holds credentials per team and per member, so the agent acts as the
right person against the right systems.

Personal productivity is the floor, not the ceiling. The point is a
platform where people **build their own tools and share them** —
across their devices and with their teams.

## How we got here

Metis didn't start from a blank page. Earlier this year we built
**[Themis](https://pipihosting.github.io/themis/)**, a sibling
system: a chat UI in front of an agent harness, used daily across
engineering, operations, customer service, and leadership at a
company managing 1,000+ properties. Themis is the kind of internal
platform people stop noticing because it has folded into how they
work. It runs on the Claude Agent SDK, which means it works only
against Claude. Inside that company the tradeoff fits — they picked
a provider and wanted the best harness for it. For a public, open
project the tradeoff is wrong.

Metis is the public form of the same shape, built on a different
foundation. The harness underneath is **pi** — open,
provider-agnostic, easy to sandbox — so the product can run against
Anthropic, OpenAI, Google, or whatever comes next. The lessons from
Themis come along; the lock-in does not.

The rest of the design follows from pi being the harness. pi is
single-user, terminal-first, local. Metis is the opposite
environment: server-side, multi-user, sandboxed, no human at the
terminal to tap through an auth prompt. Most of Metis's decisions
read as inversions of pi's — *for the same reasons pi made them the
other way*.

## Rules we hold to

1. **One harness — pi.** Not a generic shell over swappable backends.
   An opinionated product.
2. **Multi-user from day one.** Every durable resource belongs to a
   `Team`; a personal account is a team of one
   ([`docs/tenancy.md`](docs/tenancy.md)).
3. **Sandboxed by default.** `Docker` and `E2b` run pi in isolation.
   `Local` is dev-only and is **not** a security boundary. Don't ship
   it as one.
4. **Your provider.** Anthropic / OpenAI / Google, picked per
   conversation. Provider keys are the deployment's — Metis is not a
   per-user key vault.
5. **Server-rendered.** Hotwire + Stimulus. No SPA on top.
6. **pi executes; Rails governs.** Skills, extensions, MCP — all pi.
   Rails holds the credentials and decides who sees what. It does not
   re-implement.
7. **MCP is the default connector transport.** Connectors speak MCP
   through one pi extension
   ([`pi-mcp-adapter`](https://github.com/nicobailon/pi-mcp-adapter)) —
   see [`docs/connectors.md`](docs/connectors.md). CLI + skill is the
   documented fallback when no MCP server exists or its distribution
   is gated (today: Google Workspace through `gws`, because the
   self-hosted `google_workspace_mcp` path depends on Google's MCP
   Developer Preview, which excludes personal accounts). The fallback
   has real cost — vendored skill files drift when the CLI changes,
   and the catalog branches on transport — so the bar is "MCP
   unavailable or gated," not "CLI feels easier."
8. **Built to share.** A tool you make is a tool your team can use.
   Skills are the first shape of this — authored in the UI or by the
   agent itself, projected per turn ([`docs/skills.md`](docs/skills.md)).

## What we won't build

Each one of these is a temptation already present in the code or the
backlog. Recording them keeps the project from drifting into shapes we
have considered and rejected.

- **A second agent backend.** `Agent::Adapters` translates pi's wire
  into a canonical UI vocabulary (`Agent::UiEvent`), and that seam *is*
  agent-neutral — `text_delta`, `tool_call_*`, `turn_finished` map onto
  Claude Code, Codex, or OpenCode just as well as pi. The lock-in is
  below it. `Runtime#run` takes `pi_args` and opens a `PiAgent::Session`;
  MCP (`.mcp.json` via the pi-mcp-adapter extension), skills
  (`.pi/skills/` + path-regex detection), identity (`AGENTS.md`
  auto-load), and credentials (`--provider/--model/--api-key`) are all
  pi-protocol projections; and `pi-agent-rb` is the only driver gem we
  have. A second agent is not a new adapter — it's a second set of those
  subsystems plus a driver gem per agent. That's a different product, and
  the focus is making pi excellent, not making the harness swappable.
- **A Rails-side MCP client.** Metis is the **host** — it holds
  credentials and stages `.mcp.json` per turn; pi speaks the protocol.
  Rails never *consumes* an MCP server (re-implementing that client side
  duplicates pi). *Serving* Metis's own task API over MCP is different
  and allowed: `/api/bridge/mcp` is a thin facade over the bridge REST
  surface so external coding agents can pull delegated steps
  (docs/local-bridge.md) — it speaks for Metis, it never reaches out.
- **Per-user provider API keys.** Provider keys live in
  `config.x.agent.api_keys` and are paid for by the deployment. Users
  pick provider + model; they do not bring their own keys.
- **Polymorphic `owner` on resources.** One tenancy unit, `Team`, with
  a personal team-of-one default. Polymorphic `owner` (User-or-Team)
  bifurcates every scope and policy, permanently, for the gain of one
  row at signup ([`docs/tenancy.md`](docs/tenancy.md)).
- **A JavaScript framework.** Hotwire is the rendering model; Stimulus
  is the ceiling. No React, no Vue, no Svelte.
- **Defensive code over edge cases.** Follow the happy path. Sentry
  catches what slips through.
