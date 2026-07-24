#!/usr/bin/env bash

SCREENSHOT_RELEASE_TAG="pr-screenshots"

screenshot_usage() {
    cat <<'EOF'
Usage:
  forge publish-screenshot <file> [<file> ...]

Uploads each screenshot to the rolling "pr-screenshots" GitHub Release
(created on first use if missing) and prints a markdown image line per
file, ready to paste into a PR description or comment.
EOF
}

screenshot_publish() {
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        screenshot_usage
        return
    fi

    if ! gh release view "$SCREENSHOT_RELEASE_TAG" >/dev/null 2>&1; then
        gh release create "$SCREENSHOT_RELEASE_TAG" \
            --title "PR screenshot evidence" \
            --notes "Rolling storage for screenshots linked from PR descriptions. Not a versioned release; assets accumulate here, not in git history." \
            --prerelease
    fi

    local branch stamp tmpdir repo
    branch="$(git rev-parse --abbrev-ref HEAD)"
    stamp="$(date +%Y%m%d-%H%M%S)"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"; trap - RETURN' RETURN
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"

    local index=0
    local file base asset_name url
    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            printf 'forge: no such file: %s\n' "$file" >&2
            return 1
        fi
        index=$((index + 1))
        base="$(basename "$file")"
        asset_name="${branch//\//-}-${stamp}-${index}-${base}"
        ln -s "$(realpath "$file")" "$tmpdir/$asset_name"
        gh release upload "$SCREENSHOT_RELEASE_TAG" "$tmpdir/$asset_name" >&2
        url="https://github.com/${repo}/releases/download/${SCREENSHOT_RELEASE_TAG}/${asset_name}"
        printf '![%s](%s)\n' "$base" "$url"
    done
}
