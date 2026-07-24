# AGENTS.md

Instructions for AI coding agents working inside a repository managed by
Shipyard. For setup and command reference, see [README.md](README.md).

## Workflow contract

Each Shipyard window is a unit of work created by the user with:

```bash
forge new <intent>
```

Shipyard creates the window in planning state (`💡`). The window title is the
user's intent and must remain stable; the pane border reports repository and
branch context independently.

### 1. Plan and wait

Investigate the request without modifying the repository. Use the **Lavish**
skill to present a reviewable implementation plan.

Do not create a branch, edit files, or begin implementation until the user says
the exact word **"Approved"**. A question, positive reaction, or silence is not
approval.

### 2. Build only after approval

After the user says "Approved":

```bash
git fetch origin development
git switch -c feat/new-feature origin/development
forge build
```

Create the feature branch from the latest remote `development`, never from
`main`, a detached HEAD, or another feature branch. Treehouse worktrees begin
detached, and a local `development` branch may be checked out by another
worktree, so branch directly from `origin/development`. `forge build` moves the
window from planning (`💡`) to building (`●`). Implement and verify the
requested change.

If you are blocked and must wait for the user, call `forge alert` before asking.
This produces the red attention badge.

### 3. Publish screenshots before the PR

Use the **publish-screenshots** skill before invoking no-mistakes whenever
local visual artifacts will be mentioned in PR-facing text. Local file links
do not render for GitHub reviewers. Publish each artifact with:

```bash
forge publish-screenshot artifacts/browser/after.png
```

Use the printed hosted Markdown URL, never an absolute path, `file://` URL,
localhost URL, or workspace-relative screenshot link. After the PR is created,
inspect its body and comments for local links and correct any that slipped
through.

### 4. Ship through no-mistakes

When implementation is complete, immediately run:

```bash
no-mistakes axi run --yes --intent "<the user's complete objective and decisions>"
```

Run it in the background when necessary and continue reading its output.
Shipyard observes no-mistakes and GitHub automatically:

- `` — validation is running and no PR exists yet
- yellow `⚠` — the PR has been published
- red `⚠` — validation failed or the agent is blocked
- `✓✓` — the PR was merged

Do not manually narrate validation, publication, or merge state with forge
commands. Do not merge, close, or force-push the PR unless the user explicitly
asks.

## Agent-facing forge commands

| Command | When to use it |
| --- | --- |
| `forge build` | Immediately after the user says "Approved" |
| `forge alert` | Before stopping for a user decision or reporting an unfixable failure |
| `forge status` | To inspect the current intent, state, and PR |
| `forge publish-screenshot ...` | Before including local visual evidence in PR-facing text |

`forge new` is a user command. Shipyard owns worktree allocation, tmux window
creation, automatic state observation, and worktree return when the window is
closed.

## Stopping points

Stop for explicit user input:

- after presenting the Lavish plan and before "Approved";
- when requirements require a genuine product decision;
- when no-mistakes fails for a reason you cannot confidently fix.

No-mistakes validation, push, and PR creation are pre-authorized. Merging the PR
is not.
