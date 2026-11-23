# User memory

Metis learns about each user as they chat and applies what it learned in
every later conversation. This is phase P0 of the "Metis, one step ahead"
plan: the memory every later phase (decision log, foresight, the decision
ladder) builds on.

## Model

`UserMemory` belongs to a `Team` and a `User`: one user's memories within
one team, so context learned in a work team never reaches a personal team.

| Column | Meaning |
| --- | --- |
| `content` | One short fact, encrypted, at most 500 characters |
| `kind` | `preference`, `correction`, `fact`, `goal`, `commitment`, `experience` |
| `source` | `stated` (the user said it) or `inferred` (Metis concluded it) |
| `confidence` | `low`, `medium`, `high`; stated memories are `high` |
| `source_conversation` | Where it was learned; nullified if that chat is deleted |
| `last_applied_at` | Last time a turn reported the memory shaped its reply |

At most 100 per user per team; past that a save is refused and the agent is
told to update or forget one. Leaving a team deletes your memories there
(`Membership` `after_destroy`).

## Record

The agent decides what to record. Four tools in
`.pi/extensions/metis-workflow`, through `Agent::HostBridge` to
`Agent::MemoryManager`:

- `metis_remember` — a new memory (defaults to `inferred`/`low`)
- `metis_update_memory` — revise content, kind or confidence by id. New
  wording is a new claim: it becomes `inferred` from this conversation
  unless the agent marks it `stated`; a confidence-only change keeps the
  provenance
- `metis_forget` — delete by id
- `metis_note_applied` — report which memories shaped this reply

Every op is scoped to the conversation's own user and team, so a turn can
only touch that user's memories; there is no admin gate. Tool results
report the id and labels, not the text.

## Where memory applies

Memories are private, so they're used only where the user alone reads the
replies (`UserMemory.available_in?`): a personal conversation with no
public share link, not a workflow run, whose user is still a member of its
team. Team-visible and shared chats get no memory block and the tools
refuse. Sharing a chat later doesn't retract replies already written in it.

Writes lock the user's `Membership` row, so concurrent saves can't exceed
the cap and a save can't land after leaving the team deletes the rest.

## Apply

`Agent::Identity` renders "What you've learned about the operator" after
the operator's own `about_you` / `custom_instructions`: every memory as
`[id · kind · source/confidence] content`, the rules for applying them
(by default; low confidence is a hunch; the current request wins and the
memory gets updated), and what to record or never record. When a memory
shapes a reply, the agent says so in a few words and calls
`metis_note_applied`.

## Control

`/settings/memory` (`Settings::MemoriesController`) lists the current
team's memories by kind with their provenance. The user can edit, confirm
(an inference becomes `stated`/`high`), delete, or clear all. Deleting a
memory removes it from the list every later turn is given. It doesn't
erase chat history: a resumed pi session still holds the turn where the
memory was said or written.

## Not yet

Consolidation, outcome scoring (P1), directions and foresight (P3).
