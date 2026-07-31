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

# Ambient, orthogonal to @pipeline_badge: a window can be building and dirty
# at once, that's normal. Purely informational -- surfaces that closing this
# window right now would need a decision, without judging the pipeline state.
watcher_apply_dirty() {
    local window_id="$1"
    local worktree="$2"
    local dirty=""
    local current

    [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]] && dirty=1
    current="$(tmux show-options -wqv -t "$window_id" @shipyard_dirty 2>/dev/null)"
    if [[ "$dirty" != "$current" ]]; then
        tmux set-option -w -t "$window_id" @shipyard_dirty "$dirty"
        tmux refresh-client -S 2>/dev/null || true
    fi
}

watcher_no_mistakes_status() {
    local worktree="$1"
    (cd "$worktree" && no-mistakes axi status 2>/dev/null) || true
}

# True once the agent has started working on a feature branch: HEAD is on a
# named branch other than the one the worktree was leased against, and the
# worktree has uncommitted changes or HEAD has moved past the commit it was
# leased at. Lets Shipyard detect the planning -> building transition without
# the agent having to call `forge build` itself. Still-detached worktrees and
# edits made directly on the base branch don't count as building.
watcher_worktree_building() {
    local window_id="$1"
    local worktree="$2"
    local base_branch
    local base_head
    local current_branch
    local current_head

    current_branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
    [[ -n "$current_branch" ]] || return 1

    base_branch="$(tmux show-options -wqv -t "$window_id" @shipyard_base_branch 2>/dev/null)"
    [[ -z "$base_branch" || "$current_branch" != "$base_branch" ]] || return 1

    [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]] && return 0

    base_head="$(tmux show-options -wqv -t "$window_id" @shipyard_base_head 2>/dev/null)"
    [[ -n "$base_head" ]] || return 1
    current_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$current_head" && "$current_head" != "$base_head" ]]
}

watcher_should_build() {
    local window_id="$1"
    local worktree="$2"
    local current_state

    current_state="$(tmux show-options -wqv -t "$window_id" @pipeline_state 2>/dev/null)"
    [[ "$current_state" == "building" ]] ||
        watcher_worktree_building "$window_id" "$worktree"
}

watcher_attach_pane_live() {
    local window_id="$1"

    tmux list-panes -t "$window_id" \
        -F '#{@shipyard_attach_pane} #{pane_current_command}' 2>/dev/null |
        grep -Fxq '1 no-mistakes'
}

watcher_main_pane() {
    local window_id="$1"

    tmux list-panes -t "$window_id" \
        -F '#{pane_id}|#{@shipyard_main_pane}|#{pane_top}|#{pane_left}' 2>/dev/null |
        awk -F '|' '
            $2 == "1" {
                tagged = $1
                next
            }
            candidate == "" || $3 < top || ($3 == top && $4 < left) {
                candidate = $1
                top = $3
                left = $4
            }
            END {
                if (tagged != "")
                    print tagged
                else if (candidate != "")
                    print candidate
            }
        '
}

watcher_ensure_attach_pane() {
    local window_id="$1"
    local worktree="$2"
    local main_pane_id
    local pane_id

    watcher_attach_pane_live "$window_id" && return 0
    main_pane_id="$(watcher_main_pane "$window_id")"
    [[ -n "$main_pane_id" ]] || return
    pane_id="$(tmux split-window -h -p 33 -P -F '#{pane_id}' -t "$main_pane_id" \
        -c "$worktree" -- no-mistakes attach)" || return
    tmux set-option -p -t "$pane_id" @shipyard_attach_pane 1
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
    local lock_cleanup

    [[ -n "$window_id" && -n "$worktree" ]] || return 2
    lock_dir="$(shipyard_state_home)/watch-${window_id}.lock"
    mkdir -p "$(shipyard_state_home)"
    mkdir "$lock_dir" 2>/dev/null || return 0
    printf -v lock_cleanup 'rmdir %q 2>/dev/null || true' "$lock_dir"
    trap "$lock_cleanup" EXIT

    while watcher_window_exists "$window_id"; do
        shipyard_refresh_window_context "$window_id"
        watcher_apply_dirty "$window_id" "$worktree"
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
                if command -v gh >/dev/null 2>&1; then
                    screenshot_autofix_pr_body "$worktree" "$pr"
                fi
                watcher_apply_state "$window_id" published "$pr"
            fi
        elif [[ "$run_status" == "running" ]]; then
            watcher_apply_state "$window_id" validating
            watcher_ensure_attach_pane "$window_id" "$worktree"
        elif [[ "$manual_state" != "planning" && -n "$manual_state" ]]; then
            watcher_apply_state "$window_id" "$manual_state"
        elif watcher_should_build "$window_id" "$worktree"; then
            watcher_apply_state "$window_id" building
        else
            watcher_apply_state "$window_id" planning
        fi

        sleep 10
    done
}
