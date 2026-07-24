---
name: publish-screenshots
description: Use before running no-mistakes whenever local screenshot artifacts (e.g. artifacts/browser/*.png) will be referenced in a commit message or PR description. GitHub can't render local file paths, so screenshots must be published to get a URL first.
---

# Publish Screenshots

GitHub PRs cannot display local artifact paths. Before running
`no-mistakes`, publish any screenshots you want referenced in the PR:

```bash
forge publish-screenshot artifacts/browser/example.png
```

Use the Markdown URL this returns — not the local path — in any commit
message or task summary that will become the PR description.

After the PR is created, double-check that the PR body and comments don't
contain local paths.
