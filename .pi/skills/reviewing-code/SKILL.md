---
name: reviewing-code
description: Code review methodology — security checklist, Rails anti-patterns, review quality standards. Use when reviewing pull requests or generating PR review feedback.
---

# Reviewing Code

## Review Methodology

1. **Verify the change delivers its stated purpose** — Before judging code
   quality, prove the feature actually works end to end. Take each
   requirement or user-visible promise in the PR description (and the
   linked spec, if there is one) and trace it to the specific code path
   that produces that behavior at runtime. A change can be wired but
   inert: a setting nothing reads, a toggle no code branches on, an API
   field no consumer consumes, copy that describes behavior no shipped
   code produces. **Passing tests and clean code do not mean the feature
   works** — tests can cover the plumbing while the headline behavior is a
   no-op. If a stated promise has no code path that delivers it, that is
   REQUEST_CHANGES, full stop. This is the first check because it is the
   one most often skipped and the most expensive to miss.
2. **Understand the change** — Read the PR description and all commits, not just the diff
3. **Check for regressions** — Does the change break existing behavior?
4. **Verify test coverage** — New code should have tests; changed code should have updated tests. A test that exercises the wiring but never asserts the user-visible outcome is not coverage of the feature.
5. **Review security** — See [SECURITY_CHECKLIST.md](SECURITY_CHECKLIST.md)
6. **Check Rails patterns** — See [RAILS_PATTERNS.md](RAILS_PATTERNS.md)
7. **Spot simplification opportunities** — See [SIMPLIFICATION.md](SIMPLIFICATION.md)
8. **Read previous discussion** — Never re-raise issues already addressed in PR comments.
   A finding the author answered with reasoning, or the PR documents as a known
   gap, is addressed: re-raise it only to rebut that reasoning, in its thread.

## Severity

Rate every finding by what breaks and **who can trigger it**, separately from
confidence (how sure you are it's real):

- **P1** — blocks merge. The PR's stated purpose doesn't work; a security
  boundary can be crossed by someone it's meant to stop (an outside
  contributor, injected content, another team); data loss or corruption.
- **P2** — should fix. Wrong behavior in an edge case, a race with a bounded
  effect, a risky path without a test, a limit the owner can bypass on
  their own resources.
- **P3** — polish. Naming, clarity, small simplifications.

A path that needs the user or an admin to act against their own interest
(deleting their own records to reset their own limit) is not a P1. Say who
the attacker is; if you can't name one, it's not a security finding.

A race or ordering finding is a P2 only with a **realistic trigger**: name
the sequence and why it happens in normal use, given the real timings and
the infrastructure's actual guarantees. If it needs a component to be down
or stalled for the whole operation, or the same gap already exists outside
this PR, it's a P3 suggestion (or a follow-up issue), not a P2.

## Review Verdicts

- **REQUEST_CHANGES**: at least one open **P1**.
- **COMMENT**: no P1, at least one open P2.
- **APPROVE**: only P3s or nothing. List the P3s as non-blocking notes.

## Verdict Authority

The verdict is set by the **most severe unresolved finding** — not an
average, not an overall vibe. One open P1 makes the whole review
REQUEST_CHANGES; a long list of positives does not outvote it, and neither
does a later review pass.

You may downgrade a prior blocking finding **only** by showing it is:
- **Fixed** — cite the commit and the lines that fix it, or
- **Refuted** — show concretely why it was never real.

For a **P1**, "acknowledged, but shipping anyway", "out of this PR's scope"
(see below), "the daemon/client/follow-up will handle it", or "tests pass so
it's fine" are **not** resolutions; the verdict stays REQUEST_CHANGES. For a
P2 or P3, a reasoned decision in the thread or a documented known gap is a
resolution unless you rebut it.

## Re-reviews Converge

A re-review exists to confirm the earlier findings are closed, not to
re-audit the PR from scratch.

1. Settle each prior finding first: fixed (cite the commit), refuted, or
   decided by the author in its thread.
2. New findings are limited to **regressions the commits since your last
   review introduce**, plus any **P1** anywhere. Don't open new P2/P3s on
   code you already reviewed and passed.
3. A finding on a fix commit must show the fix **broke** something. Further
   hardening of a concern the fix already addresses is a suggestion.
4. Don't ask for a larger mechanism (reconciliation, versioning, replay) to
   close a residual edge of a fix. Name it as a follow-up.
5. If everything left is P3, or P2s the author answered with a decision or a
   tracked follow-up issue, **APPROVE** and list them as non-blocking.

## Scope Is Not an Escape Hatch

"Out of scope" applies only to work **orthogonal** to the PR's goal —
unrelated refactors, pre-existing issues the PR didn't touch, gold-plating.

It **never** applies to the PR's own stated purpose. If the missing piece
is what makes the headline feature actually work, it is in scope and
blocking — even when that piece lives in another component (a daemon, a
background job, a client, a separate service). A toggle whose enforcement
lives server-side, a setting the client must read, an API field that needs
a consumer: the consuming side is part of "does this feature work," not a
separable follow-up. Do not approve a feature by relocating its core gap
to a future PR.

## Comment Quality

Good review comments:
- Explain the *why*, not just the *what*
- Suggest concrete fixes, not vague criticism — the smallest one that closes the gap, not a redesign
- Distinguish blocking issues from suggestions (prefix non-blocking with "nit:" or "suggestion:")
- Reference specific lines and files

Bad review comments:
- "This looks wrong" (no explanation)
- Nitpicking style when there's no project convention
- Requesting changes unrelated to the PR's goal (but the PR's *own* goal is never out of scope — see Scope Is Not an Escape Hatch)
- Repeating what linters already catch

## Confidence Scoring

Score each issue 0-100 before including in your review:
- **90-100**: Definite bug, security vulnerability, data loss risk
- **80-89**: Very likely issue — missing error handling, race condition, N+1 query
- **60-79**: Probable but context-dependent — verify via codebase tools before including
- **Below 60**: Style nit or uncertain — omit

Only report issues scoring **80+**. For 60-79 scores, use Read/Grep on the local codebase to verify the issue is real before including it.

This threshold is about *uncertain* findings. A delivery gap from step 1 (a
stated promise with no working code path) is not uncertain — you confirm it
by tracing the code, which makes it a 90+ finding, not a 60-79 maybe. Don't
let "I'm not sure the feature is inert" justify omitting it: trace it until
you are sure, then report it.

## Summary Format

The review summary should include these sections:

### Review Summary
**Status: [VERDICT]**

[2-3 sentence overview of what the PR does and your overall assessment]

### Key Issues Identified
1. **[Issue Title]** (P1 · blocks merge, confidence: N)
   [Explanation of why it matters and potential impact]

Mark every finding, in the summary and its inline comment, as
**blocks merge** (P1) or **non-blocking** (P2, P3), so the author knows
what stands between the PR and an approval.

### Positive Aspects
- **[Aspect]**: [Brief explanation]

### Recommendations
[Action items or confirmation of merge readiness]

## Output Format

Write the review as Markdown following the **Summary Format** above — verdict first, then issues, positives, and recommendations. Don't output raw JSON or wrap the whole review in a code fence.

When posting to a pull request, use the **`github_bot`** MCP server (it acts as the bot, so it can approve / request changes — the regular `github` server can't review your own PR). Put the summary in the review body and attach per-issue notes as inline comments on the relevant lines. If `github_bot` isn't available, fall back to the `github` server (comment-only) or render the Markdown directly in the chat.

End every review with this attribution footer. For the model, use the
**Model** id from the *This turn* section of your `AGENTS.md` boot file
(e.g. `anthropic/claude-opus-4-8`) — that's the real one; don't guess
from memory, you'll get it wrong.

```
---
🤖 Reviewed by [Metis](https://github.com/chagel/metis) · `<Model from AGENTS.md>`
```

## Simplification Opportunities

Flag code that does the right thing but does too much of it. These are usually `suggestion:` (non-blocking) unless complexity is masking a bug.

- **Duplication** — same logic in 2+ places. Suggest a shared method/concern only if duplication is exact and likely to drift.
- **Defensive code on internal boundaries** — `try`, `&.`, `nil?` checks, or `rescue` for values guaranteed by the caller or framework. Trust internal guarantees; validate only at system boundaries (user input, external APIs).
- **Premature abstraction** — single-caller helpers, one-method service objects, parametrized methods with one real call site. Three similar lines is better than the wrong abstraction.
- **Dense one-liners** — chained `map.select.reject.group_by` that needs a comment to read. Prefer explicit intermediate variables.
- **Nested conditionals / ternaries** — flatten with guard clauses, early returns, or case statements.
- **Restating-code comments** — comments that paraphrase what the next line obviously does. Only the *why* (non-obvious constraint, workaround, surprise) earns a comment.
- **Backwards-compat shims for unreleased code** — feature flags, fallbacks, or `# removed` placeholders for code paths nothing in production calls yet.
- **Error handling for impossible states** — validating things the type system or DB constraint already enforces.

When suggesting simplification: show the rewrite, don't just describe it. See [SIMPLIFICATION.md](SIMPLIFICATION.md) for concrete before/after examples.

What *not* to flag as simplification:
- Removing helpful abstractions because they have one caller *today* but a clear second caller incoming
- Collapsing readable multi-line code into a clever one-liner
- Removing comments that explain *why* (constraints, workarounds, invariants)
- Style preferences with no project convention behind them

## Prompt Smell

Flag these in PRs that modify prompt files (`app/prompts/`, SKILL.md descriptions):

- **Emphasis abuse**: `NEVER`/`ALWAYS`/`MANDATORY`/ALL CAPS — the agent architecture should enforce behavior, not the prompt's volume
- **Hardcoded names in shared prompts**: Feature-specific skill names, tool names, or business logic in generic templates like `base_agent.md.erb` — should be dynamic (ERB conditional, metadata-driven)
- **Prompt bloat**: Adding >5 lines to a shared prompt for a single feature — should it be conditional, a partial, or handled structurally?
- **Scaling test**: "If we add 5 more of these, does the prompt still work?" If the pattern requires editing the base prompt for each new instance, it's the wrong approach
- **Rhetorical fixes for structural problems**: Adding instructions like "do NOT use tool X, use tool Y instead" — this is a routing/priority problem that should be solved with metadata, tool design, or configuration

## For Detailed Reference

- **Security checklist**: See [SECURITY_CHECKLIST.md](SECURITY_CHECKLIST.md)
- **Rails anti-patterns to catch**: See [RAILS_PATTERNS.md](RAILS_PATTERNS.md)
