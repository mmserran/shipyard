# AGENTS.md

Instructions for AI coding agents working in Shipyard repositories.

For user setup and command reference, see `README.md`.

---

## Core Principle

Shipyard's tmux status bar should always reflect the agent's current
workflow state. The moment your state changes, run the matching `forge`
command in the same turn — don't wait to be asked.

---

## Recognizing State Changes

Treat any of these as a signal to run the matching command immediately —
don't wait for an explicit instruction:

| Signal | Command |
|---|---|
| User says "Let's discuss" | `forge plan` |
| User says "Approved" and you start branching/editing | `forge build` |
| Implementation looks complete, about to validate | `forge review` |
| `no-mistakes axi run` has been kicked off | `forge check` |
| `no-mistakes` run succeeds | `forge done` |
| `no-mistakes` fails, or you're blocked/need clarification | `forge alert` |
| Repo/branch context goes stale (e.g. after a rebase) | `forge sync` |

---

## Workflow

1. `forge plan` — discuss and agree on a plan, using the `lavish` skill.
   **Stop here.** Do not write code or create a branch until the user
   explicitly says "Approved".
2. Branch from `development`:
   ```bash
   git switch development
   git pull
   git switch -c feat/<name>
   ```
3. `forge build` — implement the approved work.
4. When implementation looks complete: `forge review`, then immediately
   start `no-mistakes axi run --yes --intent "..."` in the background.
   (Publishing local screenshots first? See the `publish-screenshots`
   skill.)
5. `forge check` — only once the run exists.
6. Outcome:
   - Success → `forge done`
   - Failed/blocked → `forge alert`, resolve, then `forge build` and
     repeat from step 4.

---

## forge Commands

| Event | Command |
|--------|---------|
| Planning | `forge plan` |
| Coding | `forge build` |
| Ready for validation | `forge review` |
| `no-mistakes` running | `forge check` |
| Validation succeeded | `forge done` |
| Blocked or failed | `forge alert` |
| Repo/branch context stale | `forge sync` |
| Clear status | `forge clear` |
| Show current status | `forge status` |

Never use `forge wait` — reserved for user-managed pauses.

`forge` communicates workflow state; `no-mistakes` performs validation,
pushes commits, and opens the PR. `forge done` means the PR was created —
**not** that it was merged.

---

## Stopping Rules

Stop and wait for the user when:

- the plan hasn't been explicitly approved yet
- you need clarification or confirmation (`forge alert` first)
- you can't confidently resolve a `no-mistakes` failure (`forge alert` first)

Running `no-mistakes` and opening the PR are pre-authorized once
implementation is complete.

Never merge PRs, force-push, reset history, delete branches, or close
issues/PRs without explicit instruction.
