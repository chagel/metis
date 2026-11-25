# Unattended runs

A turn that runs with nobody watching gets limits Metis enforces in code, not
instructions in the prompt. This is phase P2 of the "one step ahead" plan.
Later phases (foresight, preparation, the decision ladder) run unattended only
inside these limits.

## What counts as unattended

`Agent::RunPolicy` decides per turn. A turn is unattended when its
conversation was fired by a routine (`Conversation#routine_id`) and its latest
user message has no human `sender`: scheduled fires, webhook fires, manual
"Run now" and the nightly memory review. A person replying in a routine's
conversation makes that turn attended again. Chats and workflow steps are
attended.

## Threat model

**What we protect.** The user's connector tokens (OAuth grants, team
credentials), the GitHub App installation token, the team's routines,
workflows and skills, and the user's money.

**Attacker.** Anyone who can put text in front of an unattended turn: a
webhook payload (a PR body, an issue comment), a web page or email the agent
fetches, a repo file it reads. The model may follow that text. We assume it
will, and limit what it can reach.

**Boundary.** The sandbox. Everything inside it is readable by the agent's
shell: `.pi/mcp.json`, env vars, files. So hiding a tool (pi's
`toolExposure: hidden`) or telling the agent not to call it is not a limit;
the agent can `curl` the server with the token. The only hard limit is which
credentials Rails puts in the sandbox, and what the host does for HostBridge
calls.

## Limits

| Limit | Enforced by |
| --- | --- |
| Connectors | Only those the routine grants are rendered into `.pi/mcp.json` (`Agent::McpConfig`). The rest never reach the sandbox. |
| Provider tokens | Connectors on one OAuth provider share the user's token, so they're one grant (`provider:google`, shown as "Google (Gmail, Calendar, Drive)"). It gates those connectors and the provider's CLI token (`GH_TOKEN`, the `gws` token) together. |
| GitHub bot | `github_bot` is staged only when granted. What it can then do is the GitHub App's own permissions; protect `main` with a ruleset that requires a reviewed PR so a person still merges what it pushes. |
| Self-widening | HostBridge allows only the ops in `RunPolicy::UNATTENDED_OPS` (reads and memory notes), so `create_*`/`update_*` for routines, workflows and skills are refused, as is any op added later until it's listed. An op in `RunPolicy::GRANTABLE_OPS` (`start_workflow`) follows the routine's `actions` grant. The agent gets a refusal it can report. |
| Memory | HostBridge refuses `remember`, `update_memory` and `forget_memory` unless the routine is the memory review, so an injected payload can't plant a memory that steers later chats. Reading memories and `note_memory_*` stay allowed. |
| Budget | `UnattendedBudget` refuses a fire once the user has had `METIS_UNATTENDED_DAILY_RUNS` (default 50) routine runs, or `METIS_UNATTENDED_DAILY_COST_USD` (default 10) of their cost, in the last 24 hours. A scheduled fire is skipped and its schedule advances; "Run now" shows the reason. |
| Untrusted input | `{{event_payload}}` is fenced in `<untrusted_event_payload>` with `</` escaped, and the identity says payloads and fetched content are data. This lowers the odds the model follows them; the limits above hold either way. |
| Skills on disk | A skill the agent writes under `.pi/skills/` or queues in `.pi/skills/.imports` becomes a team skill after the turn. Runtimes skip that sync unless the policy allows `update_skill`. |
| Deleted routine | A fire marks its conversation `settings["fired_by_routine"]`. If the routine is deleted before the turn runs, the turn is still unattended, with nothing granted. |
| Fail closed | The policy is computed while the turn's inputs are staged. If it raises, staging fails and the turn errors instead of running unrestricted; a HostBridge call that fails is refused. |

## Grants

Set on the routine form under **Unattended access**, in two groups.
**Connectors**: one checkbox per team connector, one per OAuth provider for
the connectors that share its token (`provider:google`), and the GitHub bot
when an admin enabled it. **Actions**: the HostBridge ops a routine may be
granted (`RunPolicy::GRANTABLE_OPS`, today **Can start workflows**). Stored
in `Routine#trigger_config["grants"]` as `connectors` and `actions`. Only someone who
can manage the routine can change them, and only from the form: the agent's
`metis_update_routine` can't. New routines (and agent-created ones) start
with none. Routines that existed before P2 were granted the access they had.

A grant is a connector, not a tool: a granted connector exposes all of its
tools, write ones included. Narrow it by connecting a read-only credential.

## Known gaps

- **Network.** Unattended sandboxes still reach any host, so a granted token
  can be sent anywhere. An egress allowlist is the next P2 step.
- **Workflows.** A routine allowed to start workflows starts runs whose steps
  are attended turns with the launcher's full access. Grant it only to
  routines whose prompt you trust.
- **Prompt edits.** An attended chat can change a routine's prompt through
  `metis_update_routine`, and that routine keeps its grants.
- **Provider-wide grants.** A provider grant covers every connector on it
  the user has authorized, because they share one token. Asking Google for a
  narrower token per run would allow finer grants.
- **Budget is checked at fire time.** A single long turn can overshoot the
  cost limit; the next fire is refused. The check and the conversation are
  created under a lock on the user, so a burst can't overshoot the run count.
  Deleting a routine's conversations removes them from the count.
- **Other runtimes.** The limits are the same on every runtime, but
  `local` is not a sandbox at all (`docs/coding-runtime.md`).
