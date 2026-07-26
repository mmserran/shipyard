# AGENTS.md

Instructions for AI coding agents in a Shipyard-managed repository. See [README.md](README.md) for setup/commands.

## Workflow

Each Shipyard window starts in planning state (💡) via `forge new <intent>` (user-run). Title = user's intent; stays stable.

**1. Plan and wait.** Investigate without modifying the repo. Use **Lavish** to present a plan. Do not branch, edit, or implement until the user says exactly "Approved" — a question, positive reaction, or silence doesn't count. This gate applies only when a user is present to respond, e.g. a `forge new` session. If you're driving an automated pipeline with no user present (such as a no-mistakes review/fix round), proceed directly without waiting for "Approved".

**2. Build after approval.**
```bash
git fetch origin development
git switch -c feat/new-feature origin/development
```
Always branch from latest `origin/development` (never `main`, detached HEAD, or another feature branch — worktrees start detached and local `development` may be checked out elsewhere). Implement and verify the requested change. If blocked waiting on the user, call `forge alert` first.

**3. Publish screenshots before the PR.** Before running no-mistakes, if PR text will mention local visual artifacts, use the **publish-screenshots** skill: `forge publish-screenshot artifacts/browser/after.png`. Use the returned hosted URL only — never `file://`, localhost, or workspace-relative links. After PR creation, check body/comments for any local links that slipped through.

**4. Ship via no-mistakes.**
```bash
no-mistakes axi run --yes --intent "<user's complete objective and decisions>"
```
Run in background if needed. Shipyard auto-tracks state (🔍 validating → yellow 📬 published → red 🚨 failed/blocked → 🚀 merged) — don't narrate this manually. Never merge, close, or force-push the PR unless explicitly asked.

## Forge commands

| Command | When |
|---|---|
| `forge alert` | Before stopping for user input or reporting an unfixable failure |
| `forge status` | Check intent/state/PR |
| `forge publish-screenshot` | Before citing local visual evidence in PR text |

Shipyard (not the agent) owns worktree allocation, tmux windows, and state tracking.

## Stop for user input when

- plan is presented, before "Approved"
- a genuine product decision is required
- no-mistakes fails and you can't confidently fix it

No-mistakes validation/push/PR-creation are pre-authorized; merging is not.
