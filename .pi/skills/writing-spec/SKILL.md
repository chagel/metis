---
name: writing-spec
description: Write an implementation spec for a software change — a self-contained brief that a developer or coding agent can implement correctly without access to this conversation. Use when asked to write, design, or revise a spec, design doc, or implementation plan for a feature, fix, or change.
---

# Writing implementation specs

A spec is a handoff. Assume the implementer has only two things: your
spec and a checkout of the repository. They will build exactly what is
written — every gap becomes their guess, and reviewers will verify the
result against your text. Completeness beats brevity; spend length on
substance, never padding.

## Deliverables

1. **Save the spec as a markdown file** in the working directory
   (`<kebab-title>-spec.md`) so it ships as a downloadable artifact.
   *(always)*
2. **Include the full spec text in your reply** — the message is the
   version people review and quote. *(always)*
3. **For any UI-facing change, also build an HTML mockup** — save a
   self-contained `<kebab-title>-mockup.html` in the working directory
   and link it from the spec. It's the visual reference reviewers check
   the implementation against, so the words and the picture can't drift.
   Make it standalone (inline CSS, no build step, no external assets so
   it opens straight in a browser), cover every state the change
   introduces — empty / populated / loading / error, and each
   breakpoint that matters — and use realistic copy and data, not lorem
   ipsum. Match the repo's existing look where one exists; it's a
   reference for layout, states, and copy, not production code. Skip
   only when the change has no visible surface (pure API, job, schema,
   refactor).

## The closed-world test

Before finishing, reread the spec as someone who has never seen this
conversation. The repository already gives them code, conventions
(CLAUDE.md / AGENTS.md), and existing patterns — the spec must supply
everything else:

- **Intent** — what the user gets and why it's wanted.
- **Decisions already made** — choices settled during discussion and
  the alternatives rejected, so the implementer doesn't relitigate them.
- **Hidden constraints** — invariants not visible in the code: security
  boundaries, deliberate non-features, compatibility or deploy concerns,
  product promises.
- **Exact contracts** — data shapes, payloads, state transitions, error
  paths, user-facing copy. Write them precisely (real JSON keys, real
  enum values, verbatim strings), not as prose.
- **Anchors into the repo** — real file paths, class/method names, and
  an existing exemplar to imitate when one exists. Verify the names
  exist before writing them down.

Never hand off ambiguity: resolve open questions and record the
decision, or state the default you chose and why — a reviewer can
overrule a stated default cheaply; an implementer can't.

## Shape

Use these sections in this order, skipping any that are genuinely
empty:

```markdown
# Spec: <one-line title>

**Repo**: `owner/name` — one clause on stack and where conventions live.

## Goal
What changes for the user and why. Intent, not mechanism.

## Context & decisions
What the implementer can't recover from the repo: settled choices,
rejected alternatives, hidden constraints, relevant history.

## Requirements
Numbered, declarative, individually verifiable:
R1. …
R2. …
Every "should" is a requirement — write it as one or cut it.

## Approach
Files/touchpoints and what happens in each; exemplars to follow.
Behavior and seams, not method bodies — code only at signature level.

## Interfaces & data
Exact request/response examples, schema or jsonb shapes, enum values,
user-visible copy verbatim. For UI changes, link the mockup
(`<kebab-title>-mockup.html`) here and call out the states it shows.

## Edge cases
Each one paired with its expected behavior — an edge case without a
decision is an open question in disguise.

## Out of scope
What an eager implementer might do that you explicitly don't want.

## Acceptance
How a reviewer verifies each requirement: runnable commands (lint,
tests, curl) and observable behaviors, ideally mapped R-by-R. For UI
requirements, the built screen should match the mockup.
```

Numbered requirements with mapped acceptance are the traceability
spine: the implementer builds to R1–Rn, the reviewer ticks R1–Rn
against the diff, and nothing rides on shared memory.

## Rules

- **Self-contained or it doesn't exist.** Never write "as discussed
  above" or lean on conversation context — inline whatever matters.
- **Stay at spec altitude.** Describe behavior and contracts, not
  implementations — except where exactness *is* the requirement
  (payloads, copy, shapes), where verbatim is correct.
- **Revise in place.** When feedback comes back, rewrite the spec as a
  clean next version — fold the feedback in (and update the saved
  file); don't append a changelog or argue with the review.
- **Right-size the ask.** One spec, one landable PR. If the goal needs
  more, spec the first slice and name the rest in Out of scope.
