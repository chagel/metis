# Metis Plan

The evolving status and roadmap. Identity, rules, and what we won't
build live in [`VISION.md`](VISION.md); architecture in
[`docs/`](docs/).

## Where we are

- **Open source.** Public on GitHub; `pi-agent-rb` released as a gem.
- **Chat** — live streaming over `pi --mode rpc`, Turbo-broadcast and
  persisted.
- **Runtimes** — `Local` (subprocess), `Docker` (container), `E2b`
  (microVM), all on the same `Agent::Runtime::Base` contract.
  Per-conversation sandbox lifetime: Docker via persistent host
  workspace, E2b via pause/resume. See
  [`docs/coding-runtime.md`](docs/coding-runtime.md).
- **Extensions** — `pi --extension` wiring shipped; `web-tools`
  (keyless web search / fetch) is the first bundled extension.
- **Auth & tenancy** — Devise email/password, GitHub OAuth (doubles
  as connector authorization), team-of-one tenancy.
- **Connectors** — `Connector` + `ConnectorCredential` shipped;
  marketplace UI; `.mcp.json` staged per turn through
  `pi-mcp-adapter`. Catalogue today: **GitHub** and **Linear** over
  OAuth + MCP, **Gmail / Google Calendar / Google Drive** over the
  `gws` CLI + skills fallback (Google's MCP path excludes personal
  accounts — see [`docs/connectors.md`](docs/connectors.md)).
- **Skills** — pi auto-discovers them from `workspace/.pi/skills/`.
  Two sources project into one tree: the repo's `.pi/skills/` and
  team-managed `Skill` rows authored from `/settings/skills`. The
  agent can create and edit team skills mid-conversation; Metis
  ingests them at turn end. Team skills can be **imported from
  GitHub** (e.g. `anthropics/skills`) from the Marketplace tab or
  by the agent itself via `.pi/skills/.imports`. See
  [`docs/skills.md`](docs/skills.md).
- **Projects** (v1) — `Project` belongs to a team, binds external
  refs (GitHub repo, Linear project) per connector, and composes
  into a conversation. The team's project catalogue is rendered
  into per-turn `AGENTS.md` for lookup-by-mention; on-demand
  resource pickers open the bound repo/project in one click.
- **Credential pass-through** — `GH_TOKEN` and
  `GOOGLE_WORKSPACE_CLI_TOKEN` projected per turn so `git`/`gh` and
  `gws` act as the operator inside the sandbox.
- **Profile** — avatars (OAuth or upload), personalization fields,
  user-menu popup with live theme switch.

## The loop we're building

The roadmap below is ordered by where value compounds, not by
engineering dependency. Skills, connectors, projects, and teams aren't
parallel tracks — they're one flywheel:

> A person builds a skill → it works → they pull in a teammate → the
> team's skills accumulate → switching cost rises → the *org* depends
> on the platform.

Two ends of that flywheel, kept distinct on purpose:

- **Impact** lives with [Themis](https://pipihosting.github.io/themis/) —
  the internal, daily-used, Claude-locked sibling where proven workflow
  value (and revenue) already sit.
- **Influence** lives with Metis — open, self-hostable,
  provider-agnostic. Its currency is adoption and attention, not ARR.

This is why we don't monetize lock-in here. Hosting tiers and
fine-tuning stickiness are a Themis / hosted-offering play; on open
Metis the only VISION-legal moat is a team's own accumulated tools —
lock-in to *your* skills, never to a vendor. See [`VISION.md`](VISION.md)
rules 4 and 8.

## Roadmap

Themes, in impact order:

| Theme | Goal |
|---|---|
| **Expansion trigger** | The flywheel's ignition: a power user finishes a skill mid-conversation, then invites a teammate into a team built around it — in one click. This is the growth lever; it ranks above the next three connectors. Builds on the team-of-one → real-teams path (invitations, memberships UI, shared connectors and conversations). |
| **Moat depth** | Make accumulated skills sticky and self-improving: skill versioning, team libraries, usage analytics, and a reject/edit learning signal captured at ingestion (Metis owns ingestion, so this stays "Rails governs, pi executes"). Beyond GitHub import — export, registry, or git-backed publishing. |
| **Neutrality, loud** | Turn our #1 differentiator from a buried implementation detail into positioning: a visible provider switch, and a day-zero ritual when a notable model drops ("Metis runs it now"). Influence is recurring attention. |
| **Workflows as depth axis** | Shipped: linear runs + human gates + local delegation (the time/depth axis — see [`docs/workflows.md`](docs/workflows.md)). Next is *topology*, each shape from Anthropic's [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) bent to fit `pi executes; Rails governs`: parallel fan-out over delegated steps (Phase 5), declared-label gates that let a skill’s `outcome: pass\|revise` auto-review a step (Phase 6), and declared-label routing/branching (Phase 7). The engine still never reads agent output — it branches only on a label pi declares. Programmatic tool calling / code-execution orchestration stays out: it’s a pi-harness capability, not a Rails one. |
| **Connectors as fuel** | Slack, Notion, Metabase next — each ranked by what shareable skills it unlocks across a team's stack, not by checklist order. Configuration on top of `pi-mcp-adapter`. GitHub and Linear shipped; Google via `gws` fallback. As the catalogue grows, plan **progressive tool disclosure** — stage only the connectors a run's `Project#external_refs` actually binds into per-turn `.mcp.json`, rather than the whole team catalogue (Anthropic's tool-search lesson; orthogonal to the engine, doesn't touch the "no Rails-side MCP runtime" line). Measure tool-definition token share via `context_usage` first. |
| **Projects as container** | Build on the v1 scaffold: a Project becomes the unit a team's skills/connectors attach to (the moat's storage shape) — richer external-ref types, project-scoped skills/connectors, project-level conversation defaults. |
| **Dual GitHub persona** | **Shipped**: two GitHub MCP servers staged at once — `github` (`ghu_`, acts as the operator) and `github_bot` (`ghs_`, acts as `<slug>[bot]`). `GithubApp::InstallationToken` mints the bot bearer with the install id auto-resolved from the App's sole install; `McpConfig` stages `github_bot` automatically when `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY` are set. The reviewing-code skill posts PR reviews via `github_bot` (GitHub forbids approving your own PR), everything else via `github`. No team/shared-credential concept. See [`docs/connectors.md`](docs/connectors.md). |
| **Web UI** | A design system in the Hotwire stack — consistent component set + design tokens. |

## Next

- [ ] **Invite-around-a-skill, end to end.** Finish a skill
  mid-conversation → one click to invite a teammate into a team built
  around it. Worth more than the next three connectors.
- [ ] **Skill usage analytics + reject/edit capture.** Even a crude
  "used N / edited M" surfaces load-bearing skills and seeds the
  learning loop. Cheapest moat-deepener we have.
- [ ] **A day-zero model ritual.** When a notable model drops, a
  same-day "Metis runs it now" note — architecture as recurring
  attention.
- [ ] **Workflow fan-out + declared-label gates.** The depth axis's
  next compounding step: parallel delegated steps (reuse the bridge's
  `max_workers` + `SKIP LOCKED` claim), then a skill-emitted
  `outcome: pass|revise` label that auto-reviews a step — turning the
  existing human `request_changes!` loop model-driven without the engine
  ever reading agent output. See [`docs/workflows.md`](docs/workflows.md)
  Phases 5–6.
