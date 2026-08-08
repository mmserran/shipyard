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

    local branch tmpdir repo
    branch="$(git rev-parse --abbrev-ref HEAD)"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"; trap - RETURN' RETURN
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"

    local index=0
    local base label asset_name digest url
    for file in "$@"; do
        index=$((index + 1))
        base="$(basename "$file")"
        label="${base//\\/\\\\}"
        label="${label//[/\\[}"
        label="${label//]/\\]}"
        label="${label//$'\r'/'&#13;'}"
        label="${label//$'\n'/'&#10;'}"
        digest="$(git hash-object "$file")" || return
        asset_name="${branch//\//-}-${digest}-${base}"
        asset_name="${asset_name//[^A-Za-z0-9._-]/-}"
        if ! gh release view "$SCREENSHOT_RELEASE_TAG" --json assets --jq '.assets[].name' 2>/dev/null |
            grep -Fxq "$asset_name"; then
            ln -s "$(realpath "$file")" "$tmpdir/$asset_name"
            if ! gh release upload "$SCREENSHOT_RELEASE_TAG" "$tmpdir/$asset_name" >&2; then
                gh release view "$SCREENSHOT_RELEASE_TAG" --json assets --jq '.assets[].name' 2>/dev/null |
                    grep -Fxq "$asset_name" || return 1
            fi
        fi
        url="https://github.com/${repo}/releases/download/${SCREENSHOT_RELEASE_TAG}/${asset_name}"
        printf '![%s](%s)\n' "$label" "$url"
    done
}

# `gh pr edit --body` fails outright on every call: it re-fetches the full PR
# via a GraphQL query that still asks for the classic-Projects `projectCards`
# field, and GitHub's backend now rejects that field unconditionally since
# Projects (classic) was fully sunset -- so the whole mutation errors out
# before the body edit ever takes effect, regardless of gh version quirks or
# anything about the edit itself. This has been silently true on every
# `gh pr edit` call this tool makes; screenshot_autofix_pr_body swallowed the
# failure (`>/dev/null 2>&1`), so the self-heal always looked like it ran but
# never actually persisted. The REST endpoint doesn't touch that field.
#
# `-f key=@file`/`-f key=@-` (read the value from a file/stdin) is a newer gh
# feature -- confirmed absent on gh 2.4.0 (2022), where it's taken literally
# ("@-" ends up as the PR body, verbatim). `-f key=value` with the value
# passed directly as an argument JSON-encodes it internally and works on that
# same old version, so pass the body that way instead of trying to stream it.
screenshot_edit_pr_body() {
    local worktree="$1"
    local pr="$2"
    local body="$3"
    local repo pr_number

    case "$pr" in
        https://github.com/*/pull/*)
            repo="${pr#https://github.com/}"
            pr_number="${repo##*/pull/}"
            repo="${repo%%/pull/*}"
            ;;
        *)
            pr_number="$pr"
            repo="$(cd "$worktree" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
            ;;
    esac
    [[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1

    gh api -X PATCH "repos/${repo}/pulls/${pr_number}" -f "body=${body}" >/dev/null 2>&1
}

# Self-heals a PR body that still points at local screenshot files: GitHub
# can't render `file://`, absolute, or workspace-relative image links, and
# agents don't reliably remember to publish evidence before handing off to
# no-mistakes. Handles both Markdown images and no-mistakes' generated
# `(local file: <code>...</code>)` evidence annotations. Uploads each local
# image it can find on disk and rewrites the body in place. Idempotent -- once
# a link is hosted it no longer matches, so calling this every watcher poll is
# safe.
screenshot_autofix_pr_body() {
    local worktree="$1"
    local pr="$2"
    local body current_body new_body image marker target resolved line url changed prefix suffix
    local -A uploaded=()

    body="$(gh pr view "$pr" --json body --jq .body 2>/dev/null)" || return 0
    [[ -n "$body" ]] || return 0

    new_body="$body"
    changed=0

    local targets
    targets="$(grep -oE '!\[[^]]*\]\([^) ]+\)' <<<"$body" | sort -u || true)"

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        target="${image##*\](}"
        target="${target%)}"
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

        if [[ -z "${uploaded[$resolved]:-}" ]]; then
            line="$(cd "$worktree" && screenshot_publish "$resolved" 2>/dev/null)" || continue
            url="${line#*(}"
            url="${url%)*}"
            [[ -n "$url" ]] || continue
            uploaded[$resolved]="$url"
        fi

        suffix="$target)"
        prefix="${image%"$suffix"}"
        new_body="${new_body//"$image"/"$prefix${uploaded[$resolved]})"}"
        changed=1
    done <<<"$targets"

    # no-mistakes renders browser evidence as prose followed by a local-file
    # annotation rather than Markdown image syntax. Turn that annotation into
    # an embedded hosted image while its temporary evidence file still exists.
    targets="$(grep -oE '\(local file: <code>[^<]+</code>\)' <<<"$body" | sort -u || true)"

    while IFS= read -r marker; do
        [[ -n "$marker" ]] || continue
        target="${marker#\(local file: <code>}"
        target="${target%</code>\)}"
        case "${target,,}" in
            *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.svg) ;;
            *) continue ;;
        esac

        resolved="${target#file://}"
        [[ "$resolved" == /* ]] || resolved="$worktree/$resolved"
        [[ -f "$resolved" ]] || continue

        if [[ -z "${uploaded[$resolved]:-}" ]]; then
            line="$(cd "$worktree" && screenshot_publish "$resolved" 2>/dev/null)" || continue
            url="${line#*(}"
            url="${url%)*}"
            [[ -n "$url" ]] || continue
            uploaded[$resolved]="$url"
        fi

        line="![${resolved##*/}](${uploaded[$resolved]})"
        new_body="${new_body//"$marker"/$line}"
        changed=1
    done <<<"$targets"

    [[ "$changed" -eq 1 && "$new_body" != "$body" ]] || return 0
    current_body="$(gh pr view "$pr" --json body --jq .body 2>/dev/null)" || return 0
    [[ "$current_body" == "$body" ]] || return 0
    screenshot_edit_pr_body "$worktree" "$pr" "$new_body"
}
