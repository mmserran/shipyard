---
name: publish-screenshots
description: Use before running no-mistakes whenever local screenshot artifacts will be referenced in a commit message, intent, PR description, or PR comment. GitHub cannot render local file paths, so screenshots must be published first.
---

# Publish Screenshots

GitHub PRs cannot display local artifact paths. Before running no-mistakes,
publish every screenshot that should appear in PR-facing text:

```bash
forge publish-screenshot artifacts/browser/example.png
```

Use the returned Markdown URL instead of the local path in commit messages,
no-mistakes intent, task summaries, PR descriptions, and comments.

After the PR is created, verify that its body and comments contain no absolute
paths, `file://` URLs, localhost URLs, or workspace-relative screenshot links.
