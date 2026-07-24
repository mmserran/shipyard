# AGENTS.md

Instructions for AI coding agents (e.g. Claude Code) working inside a repository
managed by Shipyard. This document defines how an agent should communicate
workflow state through `forge`, and where it must stop and hand control back to
the user. For end-user setup and command reference, see [README.md](README.md).

---

## Core principle

Shipyard's tmux status bar exists so the user can glance at a window and know
what an agent is doing without opening the pane. That signal is only useful if
the agent keeps it current.

**Report workflow state through `forge`, not just through chat.** When your
status changes — you start planning, start implementing, finish a change, hit
a problem — call the matching `forge` command in the same turn. Do this
proactively. Do not wait for the user to say "use forge commands" or "mark
this as building" — treat those as defaults, not requests.

---

## Lifecycle

```
forge plan
# Discuss and agree on an approach before writing code.
# Stop here and wait. Do not create a branch or write any code until the
# user explicitly says "Approved" — proposing a plan is not the same as
# getting it approved, and silence or a related follow-up question is not
# approval either.

git switch development
git pull
git switch -c feat/new-feature
forge build
# Only after the user says "Approved": branch off `development` (never off
# `main` or whatever branch happens to be checked out) and implement the
# change. forge build also runs `forge sync`, so the window/pane immediately
# reflect the new branch.

forge review
# Implementation looks complete.

no-mistakes axi run --yes --intent "..."
# Start immediately, in the background — do not wait to be asked, and
# do not pause for a human look at the diff first. axi run blocks
# synchronously and can run for minutes (review, test, and CI steps),
# so background it and read its output as it progresses. It runs its
# own automated review, tests, lint, docs, and — if everything passes —
# pushes and opens the PR.

forge check
# Mark validating now that the run actually exists. This also opens a
# `no-mistakes attach` pane so the run is visible live, split vertically
# (side by side) so the agent pane and the TUI stay simultaneously
# visible. Order matters here: attach shows "no active run" and exits
# within a couple seconds if nothing is running yet, so forge check
# must come after axi run has started, never before.

forge done      # no-mistakes passed; the PR is up.
forge alert     # no-mistakes failed.
```

`forge review` → start no-mistakes → `forge check` is one continuous move,
not three separate decisions — treat reaching "implementation looks done" as
the trigger for all of it. Only the order of the last two is fixed (the run
must exist before you call `forge check`); everything else follows
immediately without waiting to be asked.

If no-mistakes fails, `forge alert`, summarize the failure, and either fix it
yourself or ask the user for direction if the fix isn't obvious. Once fixed:

```bash
forge build
# Address the failure, then forge review / forge check / no-mistakes again.
```

If you're blocked and need a decision from the user mid-implementation
(unrelated to a no-mistakes failure), also use `forge alert`.

`forge clear` removes pipeline state entirely; `forge status` prints the
current state. Use `forge sync` on its own if the window/pane context ever
looks stale (e.g. after a manual `git switch` outside of `forge build`).

---

## Command triggers

| When this happens                                                   | Call this      |
| ---------------------------------------------------------------------- | --------------- |
| You start discussing/designing an approach, before any code exists     | `forge plan`   |
| The user says "Approved" and you create the feature branch and start writing code | `forge build` |
| Your implementation looks complete                                     | `forge review` |
| Right after starting `no-mistakes axi run` in the background           | `forge check`  |
| no-mistakes passes (pushed, PR open)                                   | `forge done`   |
| no-mistakes fails, or you're blocked and need a decision               | `forge alert`  |
| You resume coding after a failure or feedback                          | `forge build`  |
| The branch's context (repo/branch shown in window) looks wrong         | `forge sync`   |

Don't call `forge wait` speculatively — it's for the user's own pauses in a
pipeline, not something an agent needs to set.

---

## Screenshots in PRs

A local file path (e.g. `artifacts/browser/after.png`) never renders in a
GitHub PR description or comment — only a published, hosted URL does.
`no-mistakes` authors the PR body from whatever it's given; it has no
awareness of where your screenshots live, so a stale local path silently
becomes a dead link in the PR.

**Publish before invoking `no-mistakes`.** Run `forge publish-screenshot
<file> [<file> ...]` and use the printed `![...](...)` markdown lines — not
local artifact paths — in whatever commit message or task summary
`no-mistakes` will draw the PR description from. This is the primary fix: it
prevents a broken-link PR body from ever being generated, rather than
requiring a later correction.

```bash
forge publish-screenshot artifacts/browser/after.png
# ![after.png](https://github.com/.../releases/download/pr-screenshots/...)
```

**Safety net:** after `no-mistakes` creates or updates a PR, check the PR
body/comments for lingering local artifact paths:

```bash
gh pr view <n> --json body,comments
```

Fix any that slipped through with `gh pr edit` / `gh pr comment`.

---

## Stopping points

An agent must stop and wait for explicit user input at these points, even if
`forge` state has been updated:

- **Before any code is written.** After `forge plan`, wait for the user to
  say the word "Approved" before creating a branch or calling `forge build`.
  Do not infer approval from an enthusiastic reaction, a clarifying question,
  or moving on to another topic — if the user hasn't said "Approved", treat
  the plan as still open for discussion.
- **Feature branches always branch off `development`.** Before `git switch
  -c`, switch to `development` and pull latest, regardless of what branch is
  currently checked out. Never branch off `main` or off another in-progress
  feature branch.
- **Running no-mistakes through to a passing push/PR is pre-authorized** by
  this workflow — that's the one exception to asking first. It does not
  extend to anything else: don't merge the PR, force-push, `git reset
  --hard`, delete branches, or close issues/PRs without being asked. Opening
  the PR is the workflow's job; deciding what happens to it is the user's.
- **When blocked on a genuine decision** the user needs to make (ambiguous
  requirements, a choice between approaches) — call `forge alert` and ask,
  rather than guessing and continuing to `forge build`.
- **When no-mistakes fails for a reason you can't confidently fix** — call
  `forge alert`, explain what failed, and ask before retrying with a
  different approach.

---

## What `forge` is not

`forge` tracks *pipeline state* for the tmux status bar — it does not run
tests, does not validate code, and does not push or open PRs itself.
`no-mistakes` does that work; `forge check`/`forge done`/`forge alert` just
narrate the outcome. `forge done` means no-mistakes shipped the PR, not that
the PR has been merged — merging is still the user's call.
