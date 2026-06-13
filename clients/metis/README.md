# metis — the local-bridge daemon

The unattended local daemon for delegated Metis workflow steps
([`docs/local-bridge.md`](../../docs/local-bridge.md), Phase 4). It polls
the bridge pull API, claims tasks for the projects configured on this
machine, runs a coding agent headless in a per-task git worktree, streams
progress back, and submits the result. Metis never drives this machine —
the daemon pulls.

Go stdlib only, single static binary. macOS / Linux.

## Install

From a checkout:

```sh
cd clients/metis && go build -o /usr/local/bin/metis .
```

or directly:

```sh
go install github.com/chagel/metis/clients/metis@latest
```

## Configure

```sh
metis init       # writes ~/.metis/config.json
```

```jsonc
{
  "agent": "claude",                 // claude | pi | codex
  "servers": [
    {
      "name": "prod",
      "server": "https://your-metis-host",
      "token": "mbt_…",              // /settings/account → Local bridge on THAT deployment
      "max_workers": 2,              // concurrent tasks for this server (default 1)
      "projects": {
        "metis-api": "~/Workspaces/metis"   // Metis project name → local checkout
      }
    },
    {
      "name": "dev",
      "server": "https://your-dev-host",
      "token": "mbt_…",
      "projects": { "scratch": "~/code/scratch" }
    }
  ]
}
```

One daemon polls every configured server; tokens and projects are
per-server (different deployments, different identities), and each
server's worktrees live apart under
`workspaces_root/<server-name>/`. A single deployment can use the flat
`server` / `token` / `projects` shorthand at the top level instead of
`servers` (`max_workers` works there too). One unreachable server never
blocks the others, and a long task on one never starves the rest:
each server fills its own `max_workers` slots independently, every
worker in its own worktree with its own agent subprocess. Size
`max_workers` to what the machine (and your API budget) can carry —
each slot is a whole headless coding agent.

The daemon only claims tasks whose workflow project it has a checkout
for (the `?project=` claim filter) — it never blind-claims. Optional
keys (defaults): `agent_args` (`[]`, protocol-breaking flags are
stripped, your flags come after the defaults so they win),
`poll_interval` (30s), `heartbeat_interval` (240s),
`inactivity_timeout` (600s), `cancel_poll_interval` (30s), `gc_ttl`
(24h), `workspaces_root` (`~/.metis/worktrees`), `client`
(hostname). When several machines run daemons under one token, give
each a unique `client` — claim-moved detection compares that label, so
two machines both called "mbp" would alias each other.

## Run

```sh
metis once       # one poll → work the claimed tasks → exit (good first run)
metis run        # poll forever
metis gc         # sweep settled task worktrees now
```

## Install as a login service

```sh
metis install    # copies the binary to /usr/local/bin (or ~/.local/bin)
                        # and registers launchd (macOS) / systemd --user (Linux)
metis status     # installed? running? (with pid and log path)
metis log        # follow the daemon log (tail -F / journalctl -f)
metis stop       # halt until next login or metis install
metis uninstall  # stop + remove the service (binary stays)
```

The installer validates the config first (a service that would
crash-loop refuses to install), and bakes your current `PATH` into the
service definition — services get a bare PATH, and the agent CLIs
usually live in version-manager shims. Logs: `~/.metis/daemon.log`.

**Config edits need no restart**: the daemon hot-reloads `config.json`
while idle (never mid-task) — a valid edit swaps in once running tasks
finish, an invalid one is logged and ignored, keeping the previous
config running. Restart (`metis install` again, which also re-validates) only
for binary upgrades or PATH changes. Project names match
case-insensitively, mirroring the server.

## How a task runs

1. Claim from `GET /api/bridge/tasks/next?project=…` — the payload (step
   prompt + prior steps' full outputs) is the agent's entire brief.
2. `git worktree add` off the project checkout, branch `metis/<ref>` —
   the task never touches a checkout doing other duty. A re-claimed
   task whose worktree survives resumes in it.
3. The agent runs headless in its native JSON stream (`claude -p
   --output-format stream-json`, `pi -p --mode json`, `codex exec
   --json`), with the user's own credentials and subscription, in its
   own process group. Unattended means no one can answer permission
   prompts, so claude runs with `--permission-mode bypassPermissions`
   and codex with `--full-auto` — tighten via `agent_args` if your
   deployment wants less. The inner agent is isolated from your own MCP
   servers (`--strict-mcp-config`): a delegated task must not discover
   your other tools.
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

## Development

```sh
go test ./...           # the suite drives real worktrees, fake agents, and an httptest bridge
gofmt -l . && go vet ./...
```

Adding an agent: implement the two-method `Agent` interface in
`agents.go` (command array + stream-line parser + blocklist) and register
it in `AgentFor`. A generic ACP adapter belongs here the first time an
agent without a native headless JSON stream is needed.
