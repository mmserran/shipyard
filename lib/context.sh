#!/usr/bin/env bash

shipyard_git_context() {
    git -C "${1:-$PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

shipyard_repo_name() {
    basename "$(git -C "${1:-$PWD}" rev-parse --show-toplevel)"
}

shipyard_branch_name() {
    git -C "${1:-$PWD}" branch --show-current 2>/dev/null
}

shipyard_context_for_path() {
    local path="$1"
    local repo
    local branch

    if shipyard_git_context "$path"; then
        repo="$(shipyard_repo_name "$path")"
        branch="$(shipyard_branch_name "$path")"
        printf '%s  %s' "$repo" "${branch:-detached}"
    else
        basename "$path"
    fi
}

shipyard_update_context() {
    [[ -n "${TMUX:-}" ]] || return 0

    local pane_title
    pane_title="$(shipyard_context_for_path "$PWD")"

    printf '\033]2;%s\033\\' "$pane_title"
    tmux set-option -pq @shipyard_context "$pane_title"
}

shipyard_refresh_window_context() {
    local window_id="$1"
    local pane_id
    local path
    local pane_title

    while IFS='|' read -r pane_id path; do
        [[ -n "$pane_id" && -n "$path" ]] || continue
        pane_title="$(shipyard_context_for_path "$path")"
        tmux set-option -pq -t "$pane_id" @shipyard_context "$pane_title"
    done < <(tmux list-panes -t "$window_id" -F '#{pane_id}|#{pane_current_path}' 2>/dev/null)
}

shipyard_install_prompt_hook() {
    case ";${PROMPT_COMMAND:-};" in
        *";shipyard_update_context;"*)
            return
            ;;

        *)
            PROMPT_COMMAND="shipyard_update_context${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            ;;
    esac
}

shipyard_install_prompt_hook
