#!/usr/bin/env bash

# Point a project's local git config at Shipyard's absolute hooks directory so
# every worktree of that repository (including Treehouse leases) runs the same
# commit-msg normalizer without checking hooks into the product repo.
shipyard_install_git_hooks() {
    local project_root="${1:-}"
    local hooks_dir
    local current

    [[ -n "$project_root" ]] || return 0
    git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    hooks_dir="${SHIPYARD_HOME:-$HOME/.config/shipyard}/githooks"
    if [[ ! -f "$hooks_dir/commit-msg" ]]; then
        return 0
    fi
    chmod +x "$hooks_dir/commit-msg" 2>/dev/null || true
    hooks_dir="$(cd "$hooks_dir" && pwd -P)"

    current="$(git -C "$project_root" config --get core.hooksPath 2>/dev/null || true)"
    if [[ "$current" == "$hooks_dir" ]]; then
        return 0
    fi

    git -C "$project_root" config core.hooksPath "$hooks_dir"
}
