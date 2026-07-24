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

1. derives the project session from the repository name;
2. leases a pre-warmed Treehouse worktree;
3. creates an intent window rooted in that worktree;
4. records enough lease identity for safe automatic cleanup;
5. starts a state watcher; and
6. opens an ordinary shell without starting an agent.

The first unit creates the project session directly. There is no permanent
command window. Run the agent or development command of your choice from the
new shell.

Closing the window returns its Treehouse lease. Shipyard also reconciles stale
lease records on the next `forge new` after an abnormal tmux or machine exit.

## Workflow states

| Badge | State | Source |
| --- | --- | --- |
| `💡` | Planning; awaiting explicit approval | `forge new` |
| `●` | Approved and building | `forge build` |
| `` | no-mistakes is running without a PR | Automatic |
| yellow `⚠` | PR published | Automatic |
| red `⚠` | Agent blocked or validation failed | `forge alert` or automatic |
| `✓✓` | PR merged | Automatic |

PR publication replaces the validation badge; no spinner is shown. A later
failure or an unmerged closed PR takes precedence over the yellow publication
badge.

Agents should call only:

```bash
forge build
forge alert
forge status
```

Approval and blocking are semantic states, so they remain explicit. Validation,
publication, failure, and merge are observed from no-mistakes and GitHub.

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
forge new <intent>
forge build
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
