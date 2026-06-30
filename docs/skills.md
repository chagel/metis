# Skills

Skills are pi's native unit of recallable know-how: a directory with a
`SKILL.md` (frontmatter `name` + `description`, markdown body) and any
supporting files. pi auto-discovers them from cwd — when the model
sees a task that matches a skill's description, it loads the body as
ambient instructions for that turn.

Metis projects skills into `workspace/.pi/skills/` from two sources,
layered into one tree:

| Source | Mechanism |
|---|---|
| Repo `.pi/skills/` (versioned in git, identical for every team) | Copied wholesale by `Workspace#stage_skills`. |
| Team's enabled `Skill` rows (DB-authored, per-team) | Extracted under `workspace/.pi/skills/<slug>/` after the repo copy. |

This is a per-turn projected input (like `uploads/`, `.mcp.json`,
`AGENTS.md`) — wiped + rewritten each turn, never archived. pi
auto-discovers from cwd, so a triggered skill surfaces as a `read`
tool call on `SKILL.md`, relabelled to `skill: <name>` by the
adapter.

## One tree, not two

An earlier version split repo and team into sibling trees
(`.pi/skills/` and `.pi/skills-db/`) and loaded team skills via
`pi --skill <path>`. The asymmetry was load-bearing in a bad way:
`--skill` paths get pre-loaded into pi's context at session start,
so triggering one emits no `read` tool call — team-skill activation
became invisible to the operator in the chat UI, while repo-skill
activation showed up normally. Merging into one tree restores parity.

## Tenancy

Skills follow the standard rule ([`tenancy.md`](tenancy.md)):

    belongs_to :team

A user's personal team holds their personal skills. Authorization
is `skill.team.members.include?(current_user)` — no scope branching.

## Repo isolation

The agent can write *anywhere* under `workspace/.pi/skills/` during a
turn, including into a repo skill's directory. Three invariants keep
that from corrupting anything:

1. **Wipe + re-copy each turn.** `stage_skills` does
   `rm -rf workspace/.pi/skills/` then `cp -r .pi/skills/` then writes
   team skills on top. Whatever pi did last turn — modify, delete,
   add — is gone. The version pi sees is always pristine from git.
2. **Ingest filters by repo slug.** `Workspace#ingest_team_skills`
   skips any subdir whose name is a repo slug
   (`Agent::Workspace.repo_slugs`). Repo-named writes never produce
   a team row.
3. **Model-level guard.** `Skill#slug_not_in_repo_tree` rejects any
   save where the slug matches a repo skill.

Frontmatter `name:` collisions (a repo skill and a team skill with
the same `name:` but different slugs) leave pi to pick one — treat as
a teaming convention, not a technical enforcement.

## Model

```ruby
create_table :skills do |t|
  t.references :team, null: false, foreign_key: true
  t.references :created_by, foreign_key: { to_table: :users }
  t.references :updated_by, foreign_key: { to_table: :users }
  t.string  :slug, null: false       # kebab-case, becomes the dir name
  t.string  :description             # one-liner pi reads for auto-trigger
  t.text    :content_cache           # denormalized SKILL.md body
  t.jsonb   :metadata, default: {}   # escape hatch for future fields
  t.boolean :enabled, default: true, null: false
  t.timestamps
  t.index [:team_id, :slug], unique: true
end
```

Files use Active Storage with a `metadata["relative_path"]` blob
field so one row backs a *tree* of files. `SKILL.md` is one of those
files; `content_cache` mirrors it for fast index/palette rendering.

## Projection

`Agent::Workspace#stage_skills` writes the merged tree. A successful
stage stamps `.staged.sig` with a fingerprint of (repo files +
enabled team skills); the next turn skips the wipe + recopy if the
fingerprint still matches.

`Local` and `Docker` invoke this directly — pi sees the host
workspace as cwd. `Runtime::E2b` mirrors the same layout into the
sandbox: repo skills are baked into the E2B template at build time
and `cp -r`'d into the workspace on first turn; team skills upload
per-file. E2b carries its own `.team-skills.sig` marker so a resumed
sandbox can skip the team rewrite when nothing has drifted.

## UI

Standard Rails resources, all Hotwire. No new JS surface beyond a
Stimulus controller for the filename auto-fill on the file uploader.

- **Routes.** `resources :skills` at top level. The team is implicit
  via `current_team`; resources are not nested.
- **Controller.** `index/new/create/edit/update/destroy`.
  `authorize_skill!` → `current_team.members.include?(current_user)`.
- **Views.** `index` lists with enable/disable toggle; `_form` has
  slug, description, SKILL.md textarea, supporting file uploads; an
  `_files` panel manages the supporting tree.
- **Broadcasting.** `after_commit` broadcasts to `[team, :skills]` —
  concurrent editors see updates live.

## Import from GitHub

Team skills can also be **imported from a public GitHub directory** —
useful for pulling in skills from [anthropics/skills](https://github.com/anthropics/skills)
or any community repo whose layout is `<dir>/SKILL.md` (+ optional
supporting files).

The form lives on `/settings/skills` and accepts:

- `owner/repo` (whole repo is the skill, `SKILL.md` at root)
- `owner/repo/path/to/skill`
- A full `https://github.com/owner/repo/tree/<ref>/<path>` URL
- A `https://github.com/owner/repo/blob/<ref>/<path>/SKILL.md` URL
  (trailing `SKILL.md` is collapsed to its parent dir)

`Agent::SkillImporter` walks the GitHub Contents API, builds the
`{rel_path => bytes}` map, and calls `Skill.upsert_from_files` —
the same DB upsert agent-authored ingest uses. The slug defaults to
the leaf directory name; repo-slug collision is still rejected by
the model validation. If the importing user has a GitHub
`OauthGrant`, its bearer is used to lift the rate limit from
60/hr to 5000/hr.

Skills are imported as **team skills** — mutable, per-team. The
operator can edit them post-import like any other team skill.
Re-importing the same source updates the row in place.

## Agent authoring

pi can create and modify team skills directly. The operator asks in
chat ("draft a skill for PR descriptions"); pi writes
`.pi/skills/<slug>/SKILL.md` (and supporting files) in its own
workspace; Metis ingests them at turn end.

The convention is taught to pi in `AGENTS.md` (see
[`agent-identity.md`](agent-identity.md)): write skills at
`.pi/skills/<slug>/SKILL.md` with YAML frontmatter (`name`,
`description`) plus a markdown body. Repo skills are read-only —
their slugs are reserved and any writes get wiped by the next
`stage_skills`.

### Event-driven ingest

Ingest is **event-driven, not scan-driven**. Every
`tool_execution_start` event for `write` / `edit` / `bash` is
inspected by `Agent::Adapters::Pi`:

- `write` / `edit` — `args.path` matched against `.pi/skills/<slug>/`.
  Match → `@runtime.note_skill_touched(slug)`.
- `bash` — `args.command` regex-scanned for the same path shape.

The runtime accumulates a `Set<slug>` across the turn. When the
turn ends, the runtime's ingest method iterates exactly those slugs
— no whole-tree scan, no mtime check, no I/O for untouched skills.

`Workspace#ingest_team_skill_from_files(slug:, files:, by:)` is the
runtime-agnostic DB upsert. It accepts an in-memory
`{rel_path => bytes}` map so it doesn't care whether the files came
from disk (Local/Docker) or a sandbox `read` (E2b):

- `find_or_initialize_by(slug:)`, set `created_by`/`updated_by`.
- Re-parse `description` from SKILL.md YAML frontmatter.
- Purge attached files, save, re-attach each file under its
  relative path. Mirror SKILL.md body to `content_cache`.

**Upsert-only — no auto-delete.** A row is never deleted just
because its slug wasn't in this turn's touched set. Destructive ops
stay in the operator's hands.

**Bash escape hatch.** The bash regex is a heuristic. An agent that
writes a SKILL.md via a subshell script where the path doesn't
literally appear in the command bypasses ingest — recreate from the
UI, or wait for an upstream pi file-write hook.

**Conflict with concurrent UI edits.** Last write wins. If a human
saves a skill in `/settings/skills` while a turn is running, the
turn's ingest may overwrite the human's edit (or vice-versa). v1
accepts this.

### Agent-triggered imports

The agent can also pull skills from GitHub on the operator's behalf
— same import path as the Marketplace tab. Convention (taught in
`AGENTS.md`):

- Append one GitHub source per line to `.pi/skills/.imports` —
  `owner/repo`, `owner/repo/path`, or a `https://github.com/...` URL.
- Lines starting with `#` are comments; blanks are skipped.
- The runtime drains the file at turn end and enqueues
  `ImportSkillJob` per unique source.
- Failures log; the agent doesn't see them. The operator sees the
  imported row appear under *Your skills* on the next page load.

The file lives inside `.pi/skills/`, so it's wiped automatically by
the next turn's `stage_skills` — no manual cleanup needed.

### Per-runtime coverage

| Runtime | Ingest path |
|---|---|
| `Local` | Workspace reads from host disk. |
| `Docker` | Same — the container bind-mounts the host workspace. |
| `E2b` | Runtime lists + reads each touched slug's dir from the sandbox via the E2B SDK, builds the file map, calls `Workspace#ingest_team_skill_from_files`. One list RPC + one read per file in the touched dir. |

## Open

1. **Sharing across teams.** Export/import, registry, git-backed —
   the same open question that connectors and extensions raise. The
   same answer should apply to all three.
2. **System skills' source of truth.** Today the repo's `.pi/skills/`
   is read-only from Metis. If a team forks a repo skill — copy into
   the team scope, or first-class "override" with a back-reference?
   v1 punts: a team can create a same-slug skill and override
   projection.
3. **Multi-team membership.** Team-only collapses "personal" cleanly
   today (team-of-one). When real-teams ships and a user is a
   member of multiple teams, a "personal skill that follows me
   anywhere" doesn't have a home — revisit alongside that milestone.
