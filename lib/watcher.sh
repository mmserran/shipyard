#!/usr/bin/env bash

watcher_window_exists() {
    local window_id="$1"
    tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fxq "$window_id"
}

watcher_apply_state() {
    local window_id="$1"
    local state="$2"
    local pr="${3:-}"
    local current
    local badge

    current="$(tmux show-options -wqv -t "$window_id" @pipeline_state 2>/dev/null)"
    badge="$(pipeline_badge_for "$state")" || return
    if [[ "$current" != "$state" ]]; then
        tmux set-option -w -t "$window_id" @pipeline_state "$state"
        tmux set-option -w -t "$window_id" @pipeline_badge "$badge"
        tmux refresh-client -S 2>/dev/null || true
    fi
    if [[ -n "$pr" ]]; then
        tmux set-option -w -t "$window_id" @shipyard_pr "$pr"
    fi
}

watcher_no_mistakes_status() {
    local worktree="$1"
    (cd "$worktree" && no-mistakes axi status 2>/dev/null) || true
}

watcher_run() {
    local window_id="${1:-}"
    local worktree="${2:-}"
    local lock_dir
    local output
    local current_branch
    local run_branch
    local run_status
    local pr
    local pr_state
    local manual_state

    [[ -n "$window_id" && -n "$worktree" ]] || return 2
    lock_dir="$(shipyard_state_home)/watch-${window_id}.lock"
    mkdir -p "$(shipyard_state_home)"
    mkdir "$lock_dir" 2>/dev/null || return 0
    trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

    while watcher_window_exists "$window_id"; do
        shipyard_refresh_window_context "$window_id"
        manual_state="$(tmux show-options -wqv -t "$window_id" @pipeline_manual_state)"
        output=""
        if command -v no-mistakes >/dev/null 2>&1; then
            output="$(watcher_no_mistakes_status "$worktree")"
        fi
        current_branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
        run_branch="$(sed -n 's/^  branch: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$output" | head -n 1)"
        if [[ -z "$current_branch" || "$run_branch" != "$current_branch" ]]; then
            output=""
        fi
        run_status="$(sed -n 's/^  status: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$output" | head -n 1)"
        pr="$(sed -n 's/^  pr: *"\([^"]*\)".*/\1/p' <<<"$output" | head -n 1)"

        if [[ "$manual_state" == "attention" ]]; then
            watcher_apply_state "$window_id" attention "$pr"
        elif [[ "$run_status" == "failed" || "$run_status" == "cancelled" ]]; then
            watcher_apply_state "$window_id" attention "$pr"
        elif [[ -n "$pr" ]]; then
            pr_state=""
            if command -v gh >/dev/null 2>&1; then
                pr_state="$(gh pr view "$pr" --json state --jq .state 2>/dev/null || true)"
            fi
            if [[ "$pr_state" == "MERGED" ]]; then
                watcher_apply_state "$window_id" merged "$pr"
            elif [[ "$pr_state" == "CLOSED" ]]; then
                watcher_apply_state "$window_id" attention "$pr"
            else
                watcher_apply_state "$window_id" published "$pr"
            fi
        elif [[ "$run_status" == "running" ]]; then
            watcher_apply_state "$window_id" validating
        else
            watcher_apply_state "$window_id" "${manual_state:-planning}"
        fi

        sleep 10
    done
}
