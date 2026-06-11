# metis-bridge

The unattended local daemon for delegated Metis workflow steps
([`docs/local-bridge.md`](../../docs/local-bridge.md), Phase 4). It polls
the bridge pull API, claims tasks for the projects configured on this
machine, runs a coding agent headless in a per-task git worktree, streams
progress back, and submits the result. Metis never drives this machine —
the daemon pulls.

Single file, Ruby stdlib only — no gems, no Bundler. Any Ruby ≥ 3.0.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/chagel/metis/main/clients/metis-bridge/metis-bridge \
  -o /usr/local/bin/metis-bridge && chmod +x /usr/local/bin/metis-bridge
```

(or copy it from a checkout — it's one file.)

## Configure

```sh
metis-bridge init       # writes ~/.metis-bridge/config.json
```

```jsonc
{
  "server": "https://your-metis-host",
  "token": "mbt_…",                  // /settings/account → Local bridge; or METIS_BRIDGE_TOKEN
  "agent": "claude",                 // claude | pi | codex
  "projects": {
    "metis-api": "~/Workspaces/metis"   // Metis project name → local checkout
  }
}
```

The daemon only claims tasks whose workflow project it has a checkout
for (the `?project=` claim filter) — it never blind-claims. Optional
keys (defaults): `agent_args` (`[]`, protocol-breaking flags are
stripped), `poll_interval` (30s), `heartbeat_interval` (240s),
`inactivity_timeout` (600s), `cancel_poll_interval` (30s), `gc_ttl`
(24h), `workspaces_root` (`~/.metis-bridge/worktrees`), `client`
(hostname).

## Run

```sh
metis-bridge once       # one poll → work the claimed task → exit (good first run)
metis-bridge run        # poll forever
metis-bridge gc         # sweep settled task worktrees now
```

## How a task runs

1. Claim from `GET /api/bridge/tasks/next?project=…` — the payload (step
   prompt + prior steps' full outputs) is the agent's entire brief.
2. `git worktree add` off the project checkout, branch `metis/<ref>` —
   the task never touches a checkout doing other duty. A re-claimed
   task whose worktree survives resumes in it.
3. The agent runs headless in its native JSON stream (`claude -p
   --output-format stream-json`, `pi -p --mode json`, `codex exec
   --json`), with the user's own credentials and subscription.
   Unattended means no one can answer permission prompts, so claude runs
   with `--permission-mode bypassPermissions` and codex with
   `--full-auto` — tighten via `agent_args` if your deployment wants
   less (your flags come last and win). The inner agent is isolated
   from your own MCP servers (`--strict-mcp-config`): a delegated task
   must not discover your other tools.
4. Three clocks watch the stream: a heartbeat posts progress (the
   server-side liveness signal), a poll of `GET /api/bridge/tasks/:id`
   kills the agent if the task settles or the claim moves, and the
   inactivity watchdog kills it after sustained *silence* — never for
   merely running long.
5. The agent's final `METIS_RESULT: {…}` line (taught in the prompt)
   becomes the structured result; its last message is the fallback. The
   run resumes in Metis.

Settled worktrees are swept after `gc_ttl`; the `metis/<ref>` branch
stays in your repo until you delete it.
