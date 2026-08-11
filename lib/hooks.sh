#!/usr/bin/env bash

# Install Shipyard's commit-msg normalizer into the hooks directory that Git
# already uses, without taking exclusive core.hooksPath ownership. Product
# pre-commit/pre-push hooks (default .git/hooks, husky, lefthook, etc.) keep
# running; Treehouse worktrees still see the hook via the shared common hooks
# dir when no custom hooksPath is set.
shipyard_install_git_hooks() {
    local project_root="${1:-}"
    local source_hooks
    local source_commit_msg
    local current
    local abs_current
    local work_tree
    local git_common
    local active_hooks
    local target
    local wrapped
    local marker="# shipyard-managed-commit-msg"

    [[ -n "$project_root" ]] || return 0
    git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    source_hooks="${SHIPYARD_HOME:-$HOME/.config/shipyard}/githooks"
    source_commit_msg="$source_hooks/commit-msg"
    if [[ ! -f "$source_commit_msg" ]]; then
        return 0
    fi
    chmod +x "$source_commit_msg" 2>/dev/null || true
    source_hooks="$(cd "$source_hooks" && pwd -P)"
    source_commit_msg="$source_hooks/commit-msg"

    # Only honor repo-local hooksPath so we never rewrite a user's global hooks.
    current="$(git -C "$project_root" config --local --get core.hooksPath 2>/dev/null || true)"

    # Migrate off exclusive Shipyard hooksPath so default/product hooks run again.
    if [[ -n "$current" ]]; then
        if [[ "$current" = /* ]]; then
            abs_current="$(cd "$current" 2>/dev/null && pwd -P || true)"
        else
            work_tree="$(git -C "$project_root" rev-parse --show-toplevel)"
            abs_current="$(cd "$work_tree/$current" 2>/dev/null && pwd -P || true)"
        fi
        if [[ -n "$abs_current" && "$abs_current" == "$source_hooks" ]]; then
            git -C "$project_root" config --local --unset-all core.hooksPath 2>/dev/null || true
            current=""
        fi
    fi

    if [[ -n "$current" ]]; then
        if [[ "$current" = /* ]]; then
            active_hooks="$current"
        else
            work_tree="$(git -C "$project_root" rev-parse --show-toplevel)"
            active_hooks="$work_tree/$current"
        fi
        if [[ ! -d "$active_hooks" ]]; then
            echo "shipyard: warning: core.hooksPath is set to '$current' but that directory" >&2
            echo "shipyard: does not exist; refusing to install commit-msg hook there." >&2
            return 0
        fi
    else
        git_common="$(git -C "$project_root" rev-parse --git-common-dir)"
        if [[ "$git_common" != /* ]]; then
            git_common="$(cd "$project_root/$git_common" && pwd -P)"
        else
            git_common="$(cd "$git_common" && pwd -P)"
        fi
        active_hooks="$git_common/hooks"
        mkdir -p "$active_hooks"
    fi

    target="$active_hooks/commit-msg"
    wrapped="$active_hooks/commit-msg.shipyard-wrapped"

    if [[ -f "$target" ]] && grep -qF "$marker" "$target" 2>/dev/null; then
        _shipyard_write_commit_msg_wrapper "$target" "$source_commit_msg" "$wrapped" "$marker"
        return 0
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        if [[ ! -e "$wrapped" ]]; then
            mv "$target" "$wrapped"
        fi
    fi

    _shipyard_write_commit_msg_wrapper "$target" "$source_commit_msg" "$wrapped" "$marker"
}

_shipyard_write_commit_msg_wrapper() {
    local target="$1"
    local source_commit_msg="$2"
    local wrapped="$3"
    local marker="$4"

    cat >"$target" <<EOF
#!/usr/bin/env bash
$marker
set -euo pipefail
if [[ -e "$wrapped" ]]; then
    "$wrapped" "\$@" || exit \$?
fi
exec "$source_commit_msg" "\$@"
EOF
    chmod +x "$target" 2>/dev/null || true
}
