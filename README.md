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
5. symlinks the worktree's `node_modules` to the root checkout's, when the
   root has a `package.json`;
6. records enough lease identity for safe automatic cleanup;
7. starts a state watcher; and
8. opens an ordinary shell without starting an agent.

If the remote's default branch cannot be resolved or fetched, `forge new`
warns and continues from the worktree's existing checkout.

The first unit creates the project session directly. Run the agent or
development command of your choice from the new shell.

Closing the window returns its Treehouse lease. Shipyard also reconciles stale
lease records on the next `forge new` after an abnormal tmux or machine exit.

## Shared node_modules

Treehouse-provisioned worktrees copy the repository, including
`node_modules`; that copy can end up truncated or missing files, especially
for large native-addon packages. `forge new` sidesteps this by symlinking a
Node worktree's `node_modules` to its root checkout's instead of leaving
Treehouse's copy in place, so nothing gets copied and there's nothing to
truncate.

Because the symlink makes the worktree's `node_modules` the *same directory*
as root's, `npm install`/`ci`/`add`/`update`/`remove`/`uninstall`/`dedupe`/
`prune` are disabled inside a linked worktree — run from `bin/npm` on `PATH`,
which detects a symlinked `node_modules` and blocks only those subcommands,
passing everything else (`run`, `test`, `ls`, ...) through untouched. This
holds regardless of which agent, tool, or human is driving the worktree's
shell, since it isn't tied to any one agent's permission config.

```bash
forge new --new-deps nav-header   # skip linking; this worktree gets its own
                                   # independent, writable node_modules
forge new-deps                    # mid-session: swap a linked worktree's
                                   # node_modules for an independent copy
forge no-new-deps                 # mid-session: swap back to the symlink
                                   # shared with the root checkout
```

`forge new-deps` and `forge no-new-deps` run from inside a worktree's shell
and operate on it. `no-new-deps` warns (but does not block) if the worktree's
`package-lock.json` differs from root's, since a shared `node_modules` only
makes sense when the dependency trees actually agree. Neither command runs
`npm install` on your behalf.

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
| `🔍` | no-mistakes is running without a PR | Automatic |
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
forge new [--new-deps] <intent>
forge new-deps
forge no-new-deps
forge build  # manually override the state to building
forge alert
forge status
forge publish-screenshot <file> [<file> ...]
```

Internal `watch`, `reap`, and `reconcile` commands support tmux hooks and
automatic state management.

## Architecture

- `bin/forge` routes the CLI.
- `bin/npm` guards a worktree's shared `node_modules` from mutating npm
  subcommands; installed on `PATH` alongside `forge`.
- `lib/session.sh` creates project sessions, leases worktrees, links/unlinks
  shared `node_modules`, and records cleanup metadata.
- `lib/context.sh` maintains pane repository and branch context.
- `lib/pipeline.sh` maps effective states to tmux badges.
- `lib/watcher.sh` derives validation and PR states.
- `lib/screenshot.sh` publishes PR-safe visual evidence.
- `skills/publish-screenshots/SKILL.md` teaches agents when local visual
  evidence must be published.
- `tmux.conf` renders state and defines navigation and cleanup hooks.
