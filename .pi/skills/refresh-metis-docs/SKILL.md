---
name: refresh-metis-docs
description: Refresh Metis project knowledge — audit the codebase and bring CLAUDE.md, the understanding-metis skill (SKILL.md / MODELS.md / SERVICES.md), and the Go daemon client docs (clients/metis/README.md) back in sync with the current architecture. Use when CLAUDE.md or the understanding-metis skill may be stale, after merging architectural changes (new runtime, service, model, enum, env var, daemon flag, doc), or when asked to refresh/update the project docs or schema skill.
---

# Refresh Metis docs

Bring the two prose copies of Metis's architecture back in step with the code:

1. **`CLAUDE.md`** (and `AGENTS.md`, a symlink to it) — read by Claude Code / pi /
   codex **inside the repo**. May link to `docs/`, `VISION.md`, schema — they're present.
2. **`.pi/skills/understanding-metis/`** — `SKILL.md`, `MODELS.md`, `SERVICES.md`.
   Staged into pi's **isolated sandbox** each turn, where the rest of the repo is
   **not** copied. Its `../../../docs/...` links are dead in the sandbox (they resolve
   only for a human browsing the repo), so this skill must stay **self-contained** —
   never push load-bearing content into a doc it merely links to.

They mirror the same architecture for two readers, so keep them **mutually consistent**
— but not identical. `CLAUDE.md` sits at operating-instructions altitude; the
understanding-metis skill carries the deeper detail (`MODELS.md` = every model/column/
enum/association; `SERVICES.md` = service-layer patterns).

These can't be symlinked or auto-generated — it's hand-written prose for two audiences.
This skill is the manual refresh: invoke it to bring both back in sync.

A third surface — the **Go daemon client** (`clients/metis/`) — has its own doc
(`clients/metis/README.md`) plus a daemon paragraph in `CLAUDE.md`; keep it current
too (see [The Go daemon client](#the-go-daemon-client-clientsmetis) below).

## Procedure

Work in three passes — **discover → verify → update** — and report before writing.

### 1. Discover what changed

Establish ground truth from the code, not from the existing prose:

```bash
git log --oneline -25                                   # recent merges / PRs
ls app/services/agent/runtime/                          # runtimes (the "where")
ls app/services/agent/adapters/ app/services/agent/     # adapters + agent services
ls app/services/                                        # new top-level services (e.g. observability/)
grep -nE "create_table|t\.(string|integer|jsonb|decimal|datetime)|enum" db/schema.rb  # models, columns
grep -rn "enum " app/models/                            # integer enums + their maps
grep -E "pi-agent-rb|daytona" Gemfile Gemfile.lock | head  # critical dependency versions
ls docs/                                                 # doc set both files cross-link
grep -rn "ENV\[" config/initializers/agent.rb           # runtime knobs / env vars
```

### 2. Verify every existing claim

Don't trust the prose. For each architectural statement in both targets, confirm it
against code. Common drift to hunt:

- **Runtimes** — does the list match `app/services/agent/runtime/`? (Daytona and
  Docker-under-gVisor were both added after the skill's first draft.)
- **Services/subsystems** — anything in `app/services/` not mentioned? (e.g.
  `observability/` + Langfuse export, `Message#cost` / `#model_key`.)
- **Removed classes** — claims referencing deleted code (`Agent::SessionArchive` is gone).
- **Models** — `MODELS.md` columns/enums vs. `db/schema.rb` exactly.
- **Version pins** — `pi-agent-rb` version in prose vs. `Gemfile`.
- **Env vars / knobs** — provider keys, `METIS_DOCKER_RUNTIME`, etc.
- **Commands** — `bin/*` still exist and do what's claimed.

### 3. Update both, then cross-check

- **`CLAUDE.md`** — architecture sections, commands, conventions, `docs/` cross-links.
  Keep it at instruction altitude; don't inline what a `docs/*.md` already owns.
- **`.pi/skills/understanding-metis/SKILL.md`** — architecture overview, the two axes
  (Adapters / Runtime), request→response flow, session continuity & projected inputs,
  tenancy, connectors, conventions, commands, critical-dependency version. Self-contained.
- **`.pi/skills/understanding-metis/MODELS.md`** — every model, its columns, enums, and
  associations, straight from `db/schema.rb` + `app/models/`.
- **`.pi/skills/understanding-metis/SERVICES.md`** — service-layer patterns and the agent
  service map.
- **Cross-check**: the runtime list, enum facts, dependency version, and env-var names
  must agree across `CLAUDE.md` and the skill. Reconcile any mismatch.
- **Bump the version**: increment the integer `version:` in
  `.pi/skills/understanding-metis/SKILL.md` frontmatter by 1 on **every** refresh run
  (even a no-op one) — it's the at-a-glance marker of how current the skill is.

## The Go daemon client (`clients/metis/`)

The unattended local-bridge client is a surface apart from the two prose copies:
a stdlib-only Go daemon (`clients/metis/*.go`, its own `go test` suite + CI job)
that polls the bridge, claims delegated tasks, and runs them headless in per-task
git worktrees. Its **behavior** is guarded by tests, so what drifts is its
**prose** — the operator-facing `clients/metis/README.md` and the daemon
paragraph in `CLAUDE.md` (and `docs/local-bridge.md`). Keep those in step with the
code on every refresh; leave the understanding-metis skill at bridge-overview
altitude (don't inline daemon CLI detail there).

Discover ground truth from the Go, not the README:

```bash
ls clients/metis/*.go | grep -v _test          # sources
grep -nE 'case "' clients/metis/main.go         # subcommands
grep -nE 'json:"' clients/metis/config.go       # config keys (per-server + global)
grep -n "supported:" clients/metis/agents.go    # agent adapters
grep -n "^#" clients/metis/README.md            # the doc's own shape
```

Verify `README.md` + the `CLAUDE.md` daemon mention against the code:

- **Subcommands** — `init`, `once` / `run`, `gc`, `install`, `stop`, `status`,
  `log`, `uninstall` (`main.go`) all documented?
- **Config keys** — per-server `name` / `server` / `token` / `projects` /
  `max_workers`, and globals `agent`, `agent_args`, `poll_interval`,
  `heartbeat_interval`, `inactivity_timeout`, `cancel_poll_interval`, `gc_ttl`,
  `workspaces_root` (`config.go`) — match the documented sample config?
- **Agent adapters** — the supported set (`claude`, `pi`, `codex` — `agents.go`)
  current, including any per-agent blocked flags?
- **Run model** — `max_workers` tasks concurrently, per-task worktrees under
  `workspaces_root` (default `~/.metis/`), login-service install (`service.go`).

Update `clients/metis/README.md` first (the daemon's source of truth), then
reconcile the one-paragraph daemon summary in `CLAUDE.md` so neither contradicts
it. No version frontmatter on the README — nothing to bump.

## House style

- **Comments / prose**: concise, sentence case. CLAUDE.md's own rule is *comments
  default to none* — don't add narration. Dense beats verbose.
- Edit in place; preserve each file's existing structure and headings.
- **Report first**: present a short drift report (what's stale, what you'll add/remove
  per file) and get approval before writing — same as the `/claude-md-improver` flow.

## Done check

After writing, both prose targets should describe the same current architecture, the
skill should carry no claim that depends on a dead sandbox link, and its frontmatter
`version:` should have incremented by 1. If daemon behavior changed, `clients/metis/README.md`
and the `CLAUDE.md` daemon paragraph should agree with the Go too. Note `.pi/skills/` is
gitignored (it ships to prod via the working-tree build), so only `CLAUDE.md` and
`clients/metis/README.md` show in `git status` — verify the skill edits by mtime /
re-reading, not `git status`.
