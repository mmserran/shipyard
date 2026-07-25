# Shipyard

Shipyard presents intent-oriented development workflows in tmux. Each tmux
session owns one repository, and each window is a unit of work backed by a
leased Treehouse worktree.

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
4. creates an intent window rooted in that worktree;
5. records enough lease identity for safe automatic cleanup;
6. starts a state watcher; and
7. opens an ordinary shell without starting an agent.

If the remote's default branch cannot be resolved or fetched, `forge new`
warns and continues from the worktree's existing checkout.

The first unit creates the project session directly. Run the agent or
development command of your choice from the new shell.

Closing the window returns its Treehouse lease. Shipyard also reconciles stale
lease records on the next `forge new` after an abnormal tmux or machine exit.

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
| `` | no-mistakes is running without a PR | Automatic |
| yellow `⚠` | PR published | Automatic |
| red `⚠` | Agent blocked or validation failed | `forge alert` or automatic |
| `✓✓` | PR merged | Automatic |

PR publication replaces the validation badge; no spinner is shown. A later
failure or an unmerged closed PR takes precedence over the yellow publication
badge.

Agents can inspect or signal state with:

```bash
forge alert
forge status
```

Building is detected from changes in the leased worktree. Blocking remains
explicit; validation, publication, failure, and merge are observed from
no-mistakes and GitHub.

While a run is active, the window watcher also opens a side-by-side pane
running `no-mistakes attach`, so a human can watch the TUI without leaving the
window. The pane is left open after the run finishes; it's only reopened if it
isn't already running (closed by hand, or its process exited).

## Pane and status context

The status bar contains:

```text
project   💡 intent-a   ● intent-b   ⚠ intent-c       2026-10-22 00:53
```

- Left: the stable repository session name
- Center: intent windows and their current badges
- Right: local date and time

Every pane border independently shows its current `repository  branch`. Prompt
hooks and the window watcher refresh this context, so a pane that enters another
repository remains accurately labeled without changing the session identity.

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

## Commands

```text
forge open [path]
forge new <intent>
forge build  # manually override the state to building
forge alert
forge status
forge publish-screenshot <file> [<file> ...]
```

Internal `watch`, `reap`, and `reconcile` commands support tmux hooks and
automatic state management.

## Architecture

- `bin/forge` routes the CLI.
- `lib/session.sh` creates project sessions, leases worktrees, and records
  cleanup metadata.
- `lib/context.sh` maintains pane repository and branch context.
- `lib/pipeline.sh` maps effective states to tmux badges.
- `lib/watcher.sh` derives validation and PR states.
- `lib/screenshot.sh` publishes PR-safe visual evidence.
- `skills/publish-screenshots/SKILL.md` teaches agents when local visual
  evidence must be published.
- `tmux.conf` renders state and defines navigation and cleanup hooks.
