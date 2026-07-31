# Shipyard

Shipyard presents intent-oriented development workflows in tmux. Each tmux
session owns one repository, with intent windows backed by leased Treehouse
worktrees and an optional command window rooted in the repository itself.

## Setup

Add this near the end of `~/.bashrc`:

```bash
export SHIPYARD_HOME="$HOME/.config/shipyard"
source "$SHIPYARD_HOME/shell/bash.sh"
```

Source Shipyard's presentation layer from `~/.tmux.conf`:

```tmux
source-file ~/.config/shipyard/tmux.conf
```

Shipyard requires `tmux` and `treehouse`. Automatic PR state additionally uses
`no-mistakes` and the authenticated GitHub CLI, `gh`.

## Create a unit of work

From any Git repository:

```bash
forge new nav-header
```

Shipyard:

1. resolves one project session identity shared by the repository and its
   linked worktrees;
2. leases a pre-warmed Treehouse worktree;
3. refreshes that worktree to a detached checkout of the remote's current
   default-branch tip when the remote is available;
4. creates an intent window rooted in that worktree, split into a top pane
   (75% of the height) for the main work and a bottom pane (25%) for a
   secondary tool, with focus on the top pane;
5. records enough lease identity for safe automatic cleanup;
6. starts a state watcher; and
7. opens an ordinary shell without starting an agent.

If the remote's default branch cannot be resolved or fetched, `forge new`
warns and continues from the worktree's existing checkout.

The first unit creates the project session directly. Run the agent or
development command of your choice from the new shell.

Closing a clean window returns its Treehouse lease. If automatic cleanup
cannot return a lease, Shipyard keeps the cleanup record and retries during
the next `forge new`.

## Closing a unit of work

Typing `exit` in a leased window's last pane checks the worktree first: clean,
and it returns the lease and exits immediately; uncommitted changes, and it
runs Treehouse's own `Clean and return? [Y/n]` prompt with a real terminal
attached, so an actual person answers it instead of it silently declining in
the background. Answering no cancels the exit and drops you back in the shell
rather than losing the session.

```bash
forge close
```

Force-closes the current window instead: aborts any active no-mistakes run
for it first (so its daemon isn't left tracking a worktree Treehouse is about
to reset and hand to a different unit of work), discards uncommitted changes,
and returns the lease. Running the command at all is the explicit signal to
discard, so it doesn't prompt — but it does report what it's discarding.
If returning the lease fails, the window stays open and its cleanup record is
preserved.

In a project's command window, `forge close` closes that window without lease
cleanup. If another Shipyard project is open, the tmux client switches to its
command window first; otherwise tmux falls back normally, detaching or exiting
when no session remains. Unleased windows not marked as command windows are
still rejected.

## Open a project's command window

```bash
forge open
forge open ~/projects/my-app
```

Opens (creating if needed) the project's tmux session and switches to its
`command` window: a plain shell rooted in the project itself, not leased from
Treehouse and not tied to any unit of work. Use it for commands that operate
on the repository as a whole rather than on a specific intent. Repeated calls
reuse the same command window instead of creating another one.

If the session doesn't exist yet, `forge open` creates it, so it also works
as a way to open a new tmux session for a repository you haven't started
working in yet:

```bash
forge open ~/.config/shipyard
forge open portfolio/mserrano.net-web-services
```

## Workflow states

| Badge | State | Source |
| --- | --- | --- |
| `💡` | Planning; awaiting explicit approval | `forge new` |
| `●` | Building | Automatic |
| `📝` | no-mistakes is running without a PR | Automatic |
| yellow `📬` | PR published | Automatic |
| red `🔔` | Agent blocked or validation failed | `forge alert` or automatic |
| `🚢` | PR merged | Automatic |

PR publication replaces the validation badge. A later failure or an
unmerged closed PR takes precedence over the yellow publication badge.

Agents can inspect or signal state with:

```bash
forge alert
forge status
```

Building is detected from changes in the leased worktree once the agent has
checked out a named feature branch; edits made directly on the base branch,
or a worktree still detached at its leased commit, don't trigger it. Blocking
remains explicit; validation, publication, failure, and merge are observed
from no-mistakes and GitHub.

While a run is active, the window watcher also opens a side-by-side pane
running `no-mistakes attach`, so a human can watch the TUI without leaving the
window. The pane is left open after the run finishes; it's only reopened if it
isn't already running (closed by hand, or its process exited).

## Pane and status context

The status bar contains:

```text
project   💡 intent-a   ● intent-b   🔔 intent-c       2026-10-22 00:53
```

- Left: the stable repository session name
- Center: intent windows and their current badges
- Right: local date and time

Every pane border independently shows its current `repository  branch`. Prompt
hooks and the window watcher refresh this context, so a pane that enters another
repository remains accurately labeled without changing the session identity.

A window's title turns red when its worktree currently has uncommitted
changes. It's orthogonal to the pipeline badge — a window can be `building`
and dirty at once, that's normal — and purely informational: closing that
window right now would need a decision, one way or another.

## Navigation

| Shortcut | Action |
| --- | --- |
| <kbd>Alt</kbd> + arrow | Move between panes |
| <kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> | Previous/next unit of work |
| <kbd>Shift</kbd> + <kbd>↑</kbd>/<kbd>↓</kbd> | Previous/next repository session |
| tmux prefix + <kbd>s</kbd> | Choose a session by name |

## Screenshots in PRs

Publish screenshots to the rolling `pr-screenshots` GitHub Release before
referencing them in no-mistakes or PR-facing text:

```bash
forge publish-screenshot artifacts/browser/before.png artifacts/browser/after.png
```

The command prints hosted Markdown image links. It does not add the image to Git
history.

As a safety net, the window watcher also self-heals a PR body once it appears:
any `file://`, absolute, or workspace-relative image link it can resolve on
disk gets published and swapped for its hosted URL automatically, so a missed
manual publish before a no-mistakes run doesn't leave dead links in the PR
body. This is only a backstop for image links in the body; publish up front
because it does not repair PR comments or non-image local links.

## Commands

```text
forge open [path]
forge new <intent>
forge close  # close the current intent or command window
forge build  # manually override the state to building
forge alert
forge status
forge publish-screenshot <file> [<file> ...]
```

Internal `watch`, `reap`, and `reconcile` commands support tmux hooks and
automatic state management.

## Architecture

- `bin/forge` routes the CLI.
- `shell/bash.sh` sets up a Shipyard shell, including the exit() guard that
  protects an intent window's lease from an accidental close.
- `lib/session.sh` creates project sessions, leases worktrees, force-closes
  windows (`forge close`), and records cleanup metadata.
- `lib/context.sh` maintains pane repository and branch context.
- `lib/pipeline.sh` maps effective states to tmux badges.
- `lib/watcher.sh` derives validation and PR states, and flags a worktree's
  uncommitted-changes status for the status bar.
- `lib/screenshot.sh` publishes PR-safe visual evidence and self-heals local
  screenshot links left in a PR body.
- `skills/publish-screenshots/SKILL.md` teaches agents when local visual
  evidence must be published.
- `tmux.conf` renders state and defines navigation and cleanup hooks.
