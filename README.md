# Shipyard

Coordinates AI-powered software development workflows.

---

# Setup

## Bash

Add the following near the end of your `~/.bashrc`:

```bash
export SHIPYARD_HOME="$HOME/.config/shipyard"

if [[ -f "$SHIPYARD_HOME/shell/bash.sh" ]]; then
    source "$SHIPYARD_HOME/shell/bash.sh"
fi
```

## tmux

Your `~/.tmux.conf` only needs to source Shipyard's presentation layer.

```tmux
source-file ~/.config/shipyard/tmux.conf
```

---

# Commands

## Project

Open or create a project session.

```bash
forge open
forge open ~/projects/my-app
```

The project directory determines the tmux session name.

Also ensures the project's `AGENTS.md` has Shipyard's forge workflow
instructions in a delimited block, without overwriting the project's own
content. See `lib/agents.sh` below.

---

## Context

Refresh the pane title and window name from the current Git repository and branch.

```bash
forge sync
```

Useful after switching branches (`git switch -c feat/new-feature`) in a window whose
name was set before the branch existed. `forge build` runs this automatically, so a
freshly created feature branch is reflected in the window name as soon as work begins.

---

## Screenshots

Upload screenshot(s) to a rolling `pr-screenshots` GitHub Release (created on
first use) and print a markdown image line per file, ready to paste into a PR
description or comment.

```bash
forge publish-screenshot artifacts/browser/before.png artifacts/browser/after.png
```

Release assets live outside the git object database, so this never touches
repo history or clone size. Requires an authenticated `gh` CLI and a GitHub
remote on the current repository.

---

## Pipeline

Mark the current pipeline.

```bash
forge plan
forge build
forge wait
forge review
forge check
forge alert
forge done
forge clear
forge status
```

| Command        | Pipeline State        |
| -------------- | --------------------- |
| `forge plan`   | Planning              |
| `forge build`  | Building (also runs `forge sync`) |
| `forge wait`   | Waiting               |
| `forge review` | Ready for review      |
| `forge check`  | Validating (also opens a `no-mistakes attach` pane, split vertically) |
| `forge alert`  | Needs attention       |
| `forge done`   | Complete              |
| `forge clear`  | Remove pipeline state |
| `forge status` | Show current state    |

These commands update tmux window properties rather than modifying the window name itself.

---

# Keyboard Shortcuts

Shipyard builds on top of tmux with a small set of navigation shortcuts.

## Navigation

### Move between tools (panes)

Use **Alt + Arrow Keys** to move between panes without using the tmux prefix.

| Shortcut                      | Action        |
| ----------------------------- | ------------- |
| <kbd>Alt</kbd> + <kbd>←</kbd> | Previous pane |
| <kbd>Alt</kbd> + <kbd>→</kbd> | Next pane     |
| <kbd>Alt</kbd> + <kbd>↑</kbd> | Pane above    |
| <kbd>Alt</kbd> + <kbd>↓</kbd> | Pane below    |

---

### Move between pipelines (windows)

Use **Shift + Arrow Keys** to switch between pipelines.

| Shortcut                        | Action            |
| ------------------------------- | ----------------- |
| <kbd>Shift</kbd> + <kbd>←</kbd> | Previous pipeline |
| <kbd>Shift</kbd> + <kbd>→</kbd> | Next pipeline     |

Each tmux window represents one feature branch or workflow.

---

## Window Management

### Create a new pipeline

| Shortcut                         | Action                       |
| -------------------------------- | ---------------------------- |
| <kbd>Prefix</kbd> + <kbd>c</kbd> | Create a new pipeline window |

The new pipeline starts in the current working directory.

---

## Shipyard

### Designate the command center

| Shortcut                         | Action                                        |
| -------------------------------- | --------------------------------------------- |
| <kbd>Prefix</kbd> + <kbd>C</kbd> | Mark the current window as the command center |

The command center keeps a permanent identity and is not automatically renamed based on the current Git branch.

---

### Return to automatic pipeline naming

| Shortcut                         | Action                                         |
| -------------------------------- | ---------------------------------------------- |
| <kbd>Prefix</kbd> + <kbd>P</kbd> | Return the window to automatic pipeline naming |

The window name once again follows the current feature branch.

---

Navigate between tools with **Alt + Arrow Keys**, and between pipelines with **Shift + Arrow Keys**.


---

# Separation of Concerns

## bin/forge

The public CLI.

Responsible for:

* parsing commands
* routing commands
* user-facing help

Not responsible for:

* tmux configuration
* shell startup
* implementation details

Think of this as Shipyard's public API.

---

## shell/bash.sh

Bootstraps Shipyard into Bash.

Responsible for:

* adding Shipyard to PATH
* sourcing Shipyard libraries
* automatically opening a project session

Should contain almost no workflow logic.

---

## lib/context.sh

Maintains developer context.

Responsible for:

* pane titles
* pipeline window names
* prompt hooks
* opening the `no-mistakes attach` pane for `forge check`

It answers the question:

> "Where am I working?"

Example pane title:

```
portfolio  feat/navbar
```

---

## lib/pipeline.sh

Owns pipeline state.

Responsible for:

* pipeline lifecycle
* pipeline badges
* tmux window options

It answers the question:

> "What is this pipeline doing?"

Pipeline state is stored as window-scoped tmux options.

```
@pipeline_state
@pipeline_badge
```

This keeps presentation separate from workflow logic.

---

## lib/session.sh

Owns project sessions.

Responsible for:

* opening projects
* creating sessions
* attaching to sessions

It answers the question:

> "Which project am I working on?"

---

## lib/screenshot.sh

Publishes screenshots so they render in a PR.

Responsible for:

* uploading to the rolling `pr-screenshots` GitHub Release
* naming assets to avoid collisions across branches/runs
* printing PR-ready markdown image links

It answers the question:

> "How do I get this image in front of a reviewer?"

---

## lib/agents.sh

Keeps a project's `AGENTS.md` in sync with Shipyard's forge workflow
instructions.

Responsible for:

* creating `AGENTS.md` in a new project if none exists
* appending Shipyard's instructions in a delimited block if a project
  already has its own `AGENTS.md`
* refreshing that block in place on later syncs, without touching the
  rest of the file

It answers the question:

> "How does this project know about the forge workflow?"

Shipyard's block is wrapped in `<!-- shipyard:start -->` /
`<!-- shipyard:end -->` markers so a project's own `AGENTS.md` content is
never overwritten. `forge open` calls this automatically.

---

## tmux.conf

Presentation layer.

Responsible for:

* status bar
* key bindings
* pane borders
* window formatting
* navigation

It should never contain business logic.

Instead, it renders information exposed by Shipyard.

For example:

```
@pipeline_badge
