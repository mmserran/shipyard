---
name: browser
description: Use for visual verification, exploratory page inspection, and UI interaction against a running app. Invokes the shipyard `browser` command, which drives the current product repo's Playwright CLI.
---

# Browser

When a task needs to inspect or interact with a running app in a real
browser, use the `browser` command — not Playwright CLI directly:

```bash
browser open http://localhost:3000
browser snapshot
browser click e12
browser screenshot homepage --full-page
browser close
```

`browser` is on PATH in a Shipyard shell. It locates the current product
repo via git and runs that repo's `@playwright/cli` plus
`.playwright/cli.config.json`. The product repo must have `@playwright/cli`
installed (`npm install`). Run `browser --help` or `browser <command> --help`
for the full command and option lists.

## Session lifecycle

Sessions persist across commands and conversations. `open` leaves a
background browser process running until something closes it.

1. Ensure the application is running.
2. `browser open <url>`
3. Inspect with `snapshot`; interact using refs from the latest snapshot.
4. Screenshot only when visual verification is required.
5. Always `browser close` when the task finishes.

If a command behaves as though a stale session already has navigation or
auth state you didn't expect, run `browser list` to check, and
`browser kill-all` to clear anything stuck. `close-all` closes every
session; `kill-all` force-kills stale or zombie processes.

## Artifacts

Screenshots land at `artifacts/browser/screenshots/<name>.png`. Only
`screenshot` has automatic artifact path handling. Other save-as commands
(`pdf`, `video-start`, `state-save`, `tracing-start`/`stop`) use Playwright
CLI defaults under `.playwright-cli/` — pass an explicit filename under
`artifacts/browser/<type>/` if you need one kept.

Prefer accessibility snapshots over screenshots for navigation and reading
page content. Do not claim a UI change is visually correct unless it has
been inspected in the browser.
