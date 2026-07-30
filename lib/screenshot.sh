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

    local file
    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            printf 'forge: no such file: %s\n' "$file" >&2
            return 1
        fi
    done

    if ! gh release view "$SCREENSHOT_RELEASE_TAG" >/dev/null 2>&1; then
        local create_status
        if gh release create "$SCREENSHOT_RELEASE_TAG" \
            --title "PR screenshot evidence" \
            --notes "Rolling storage for screenshots linked from PR descriptions. Not a versioned release; assets accumulate here, not in git history." \
            --prerelease; then
            :
        else
            create_status=$?
            if ! gh release view "$SCREENSHOT_RELEASE_TAG" >/dev/null 2>&1; then
                return "$create_status"
            fi
        fi
    fi

    local branch stamp tmpdir run_id repo
    branch="$(git rev-parse --abbrev-ref HEAD)"
    stamp="$(date +%Y%m%d-%H%M%S)"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"; trap - RETURN' RETURN
    run_id="${tmpdir##*/}"
    run_id="${run_id//[^A-Za-z0-9._-]/-}"
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"

    local index=0
    local base label asset_name url
    for file in "$@"; do
        index=$((index + 1))
        base="$(basename "$file")"
        label="${base//\\/\\\\}"
        label="${label//[/\\[}"
        label="${label//]/\\]}"
        label="${label//$'\r'/'&#13;'}"
        label="${label//$'\n'/'&#10;'}"
        asset_name="${branch//\//-}-${stamp}-${run_id}-${index}-${base}"
        asset_name="${asset_name//[^A-Za-z0-9._-]/-}"
        ln -s "$(realpath "$file")" "$tmpdir/$asset_name"
        gh release upload "$SCREENSHOT_RELEASE_TAG" "$tmpdir/$asset_name" >&2
        url="https://github.com/${repo}/releases/download/${SCREENSHOT_RELEASE_TAG}/${asset_name}"
        printf '![%s](%s)\n' "$label" "$url"
    done
}

# Self-heals a PR body that still points at local screenshot files: GitHub
# can't render `file://`, absolute, or workspace-relative image links, and
# agents don't reliably remember to publish evidence before handing off to
# no-mistakes. Uploads each local image it can find on disk and rewrites the
# body in place. Idempotent -- once a link is hosted it no longer matches, so
# calling this every watcher poll is safe.
screenshot_autofix_pr_body() {
    local worktree="$1"
    local pr="$2"
    local body new_body target resolved line url changed
    local -A uploaded=()

    body="$(gh pr view "$pr" --json body --jq .body 2>/dev/null)" || return 0
    [[ -n "$body" ]] || return 0

    new_body="$body"
    changed=0

    local targets
    targets="$(grep -oE '\]\([^) ]+\)' <<<"$body" | sed -E 's/^\]\(//; s/\)$//' | sort -u)"

    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in
            http://*|https://*) continue ;;
        esac
        case "${target,,}" in
            *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.svg) ;;
            *) continue ;;
        esac

        resolved="${target#file://}"
        [[ "$resolved" == /* ]] || resolved="$worktree/$resolved"
        [[ -f "$resolved" ]] || continue

        if [[ -z "${uploaded[$target]:-}" ]]; then
            line="$(cd "$worktree" && screenshot_publish "$resolved" 2>/dev/null)" || continue
            url="${line#*(}"
            url="${url%)*}"
            [[ -n "$url" ]] || continue
            uploaded[$target]="$url"
        fi

        new_body="${new_body//"$target"/${uploaded[$target]}}"
        changed=1
    done <<<"$targets"

    [[ "$changed" -eq 1 && "$new_body" != "$body" ]] || return 0
    gh pr edit "$pr" --body "$new_body" >/dev/null 2>&1
}
