# Shipyard

Shipyard presents intent-oriented development workflows in tmux. Each tmux
session owns one repository, with intent windows backed by leased Treehouse
worktrees, a Yazi repo window, and an optional command window rooted in the
repository itself.

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

Shipyard requires `tmux`, `treehouse`, and `yazi`. Automatic PR state
additionally uses `no-mistakes` and the authenticated GitHub CLI, `gh`.

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
5. ensures the leftmost repo-named Yazi window exists so the status bar keeps
   a clickable repository label even before `forge open`;
6. records lease identity for cleanup and a durable intent manifest for
   restore after tmux loss;
7. starts a state watcher; and
8. opens an ordinary shell without starting an agent.

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

In a project's command window, `forge close` acts as a repository-wide close:
it applies the same forced cleanup to every intent window, then closes the
command and Yazi windows with their tmux session. If another Shipyard project
is open, the tmux client switches to its Yazi window first; otherwise tmux
falls back normally, detaching or exiting when no session remains. If any
lease return fails, Shipyard stops and leaves the repository session open.
The Yazi window itself remains protected from direct `forge close`; other
unleased windows are rejected.

## Open a project's repo windows

```bash
forge open ~/projects/my-app
```

Opens (creating if needed) the project's tmux session, ensures its two
repository-level windows exist, and switches to the `command` window. That
window is a plain shell rooted in the project for commands that operate on the
repository as a whole rather than on a specific intent. The repo-named Yazi
window remains available at the left of the window list and doubles as the
clickable repository label in the status bar. Neither window is leased from
Treehouse or tied to a unit of work.

Repeated calls reuse both windows instead of creating duplicates. If the Yazi
window was manually killed through tmux, the next `forge open` (or `forge new`)
recreates it at the left of the window list.

If the session doesn't exist yet, `forge open` creates it, so it also works
as a way to open a new tmux session for a repository you haven't started
working in yet:

```bash
forge open ~/.config/shipyard
forge open portfolio/mserrano.net-web-services
```

## Pause and resume

```bash
forge pause
```

Saves the state of every open shipyard repository and intent window, then
closes all of them: every session, its Yazi repo window, its command window,
and every leased intent window. Nothing is discarded and no Treehouse lease is
returned — worktrees, uncommitted changes, and leases stay exactly as they
were. Run `forge open` with no path afterward to restore every one of them,
the same way it recovers from a reboot.

## Restore after a reboot or pause

```bash
forge open
```

`forge open` with no path doesn't open a project — it restores every paused
repository session and leased intent window instead. Shipyard stores a durable
manifest for every active intent, plus a manifest for each repository
`forge pause` saved. After a reboot, `forge pause`, or other tmux server loss,
this verifies that each exact Treehouse lease is still active, recreates the
repository sessions and standard two-pane intent windows, restarts their
watchers, rebuilds any repo/command windows a pause saved, and attaches to the
recovered sessions. It never silently substitutes a new lease when the original
one is gone, and it never silently opens the current directory as a project
either — pass a path (even `.`) for that.
The watcher automatically backfills manifests for intent windows created by an
older Shipyard version, so they become recoverable after upgrading too.

When the watcher previously observed Codex, Claude, or Cursor Agent in the main
pane, the recovered shell prints that agent's safe resume command. Shipyard does
not scrape conversation identifiers or automatically execute an agent: use the
agent's picker or provide its known ID, for example `codex resume`,
`claude --continue`, or `cursor-agent --resume [thread-id]`.

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

While a run is active, the window watcher splits the upper main pane and gives
one-third of that row to `no-mistakes attach`, so a human can watch the TUI
without leaving the window. This placement is independent of which pane is
active. The pane is left open after the run finishes; it's only reopened if it
isn't already running (closed by hand, or its process exited).

## Pane and status context

The status bar contains:

```text
project   command   1:💡 intent-a   2:● intent-b       2026-10-22 00:53
```

- Left: the repo-named Yazi window, selectable like any other tmux window
- Center: the unnumbered command window plus intent windows, numbered from 1,
  and their current badges
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
disk gets published and swapped for its hosted URL automatically. It also
turns no-mistakes' generated `(local file: <code>...</code>)` screenshot
evidence into an embedded hosted image as soon as the watcher sees the PR, so
a missed manual publish before a run doesn't leave dead links in the PR body.
This is only a backstop for images in the body; publish up front because it
does not repair PR comments or non-image local links.

## Commands

```text
forge             # attach to a pre-existing shipyard window, if one is open
forge open [path]  # open/create the repo's Yazi and command windows
forge open        # no path: restore paused sessions and intents
forge new <intent>
forge close  # close one intent, or the whole repo from its command window
forge pause  # save and close every open repo/intent window, keeping leases
forge build  # manually override the state to building
forge alert
forge status
forge publish-screenshot <file> [<file> ...]
forge --help  # list all commands
```

Internal `watch`, `reap`, and `reconcile` commands support tmux hooks and
automatic state management.

## Git commit trailers

AI-assisted commits must use exactly one
`Co-Authored-By: [ToolName] [Model] <[identifier]>` trailer (see
[AGENTS.md](AGENTS.md)). `forge open` and `forge new` install a `commit-msg`
wrapper into the repository's active hooks directory (default shared
`.git/hooks`, or an existing `core.hooksPath`) without taking exclusive
ownership, so product hooks keep running across worktrees including Treehouse
leases. The normalizer drops only generic one-token Cursor-style injectors when
a valid ToolName + Model trailer is also present.

## Architecture

- `bin/forge` routes the CLI.
- `shell/bash.sh` sets up a Shipyard shell, including the exit() guard that
  protects an intent window's lease from an accidental close.
- `lib/session.sh` creates project sessions, leases worktrees, saves and
  closes every open window (`forge pause`), restores them after tmux loss or
  a pause (`forge open` with no path), force-closes windows (`forge close`),
  and records lease cleanup plus durable intent and project manifests.
- `lib/hooks.sh` installs Shipyard's commit-msg wrapper into the active hooks
  directory without exclusive `core.hooksPath` ownership.
- `githooks/commit-msg` drops generic one-token Co-Authored-By injectors when a
  ToolName + Model trailer is present, leaving other trailers intact.
- `lib/context.sh` maintains pane repository and branch context.
- `lib/pipeline.sh` maps effective states to tmux badges.
- `lib/watcher.sh` derives validation and PR states, snapshots the observed
  agent for restore hints, and flags a worktree's uncommitted-changes status
  for the status bar.
- `lib/screenshot.sh` publishes PR-safe visual evidence and self-heals local
  screenshot references left in a PR body.
- `skills/publish-screenshots/SKILL.md` teaches agents when local visual
  evidence must be published.
- `tmux.conf` renders state and defines navigation and cleanup hooks.
