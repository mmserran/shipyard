#!/usr/bin/env bash

shipyard_project_root() {
    local requested_path="$1"
    local resolved_path

    if ! resolved_path="$(cd "$requested_path" 2>/dev/null && pwd -P)"; then
        printf 'forge: directory not found: %s\n' "$requested_path" >&2
        return 1
    fi

    if git -C "$resolved_path" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$resolved_path" rev-parse --show-toplevel
    else
        printf '%s\n' "$resolved_path"
    fi
}

shipyard_session_name() {
    local project_root="$1"
    local session_name

    session_name="$(basename "$project_root")"

    # tmux uses colons and periods as target separators in some contexts.
    session_name="${session_name//:/-}"
    session_name="${session_name//./-}"

    printf '%s\n' "$session_name"
}

shipyard_session_for_project() {
    local project_root="$1"
    local session_name
    local existing_root
    local digest

    session_name="$(shipyard_session_name "$project_root")"
    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        printf '%s\n' "$session_name"
        return
    fi

    existing_root="$(tmux show-options -qv -t "$session_name" @shipyard_project_root)"
    if [[ "$existing_root" == "$project_root" ]]; then
        printf '%s\n' "$session_name"
        return
    fi

    digest="$(printf '%s' "$project_root" | cksum | awk '{print $1}')"
    printf '%s-%s\n' "$session_name" "$digest"
}

shipyard_state_home() {
    printf '%s/shipyard' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shipyard_record_lease() {
    local window_id="$1"
    local path="$2"
    local lease_id="$3"
    local lease_holder="$4"
    local state_home

    state_home="$(shipyard_state_home)"
    mkdir -p "$state_home/windows"
    printf '%s\t%s\t%s\t%s\n' "$window_id" "$path" "$lease_id" "$lease_holder" \
        > "$state_home/windows/${lease_id}.lease"
}

shipyard_watcher_command() {
    local window_id="$1"
    local worktree="$2"
    local command

    printf -v command '%q watch %q %q' \
        "$SHIPYARD_HOME/bin/forge" "$window_id" "$worktree"
    printf '%s\n' "$command"
}

shipyard_new() {
    local intent="${*:-}"
    local project_root
    local session_name
    local lease_holder
    local lease_json
    local worktree
    local lease_id
    local window_id
    local pending_window_id
    local watcher_command
    local base_head

    if [[ -z "$intent" ]]; then
        printf 'forge: usage: forge new <intent>\n' >&2
        return 2
    fi

    project_root="$(shipyard_project_root "$PWD")" || return
    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    if ! command -v treehouse >/dev/null 2>&1; then
        printf 'forge: treehouse is not installed\n' >&2
        return 1
    fi

    session_name="$(shipyard_session_for_project "$project_root")"
    shipyard_reconcile
    lease_holder="shipyard:${session_name}:${intent}"
    lease_json="$(cd "$project_root" && treehouse get --lease --json --lease-holder "$lease_holder")" || return
    worktree="$(sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$lease_json")"
    if [[ -z "$worktree" ]]; then
        printf 'forge: Treehouse response did not include a worktree path\n' >&2
        return 1
    fi
    lease_id="$(sed -n 's/.*"lease_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$lease_json")"
    if [[ -z "$lease_id" ]]; then
        printf 'forge: Treehouse response did not include a lease id\n' >&2
        treehouse return "$worktree" --if-lease-holder "$lease_holder" || true
        return 1
    fi

    # Make the lease recoverable before attempting any tmux mutation. If the
    # process exits during setup, the next reconciliation sees that this
    # synthetic window does not exist and safely returns the exact lease.
    pending_window_id="pending-${lease_id}"
    shipyard_record_lease "$pending_window_id" "$worktree" "$lease_id" "$lease_holder"

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        if ! window_id="$(tmux new-session -d -P -F '#{window_id}' \
            -s "$session_name" -n "$intent" -c "$worktree")"; then
            shipyard_reap "$pending_window_id" || true
            return 1
        fi
        tmux set-option -t "$session_name" @shipyard_project_root "$project_root"
    else
        if ! window_id="$(tmux new-window -d -P -F '#{window_id}' \
            -t "=$session_name:" -n "$intent" -c "$worktree")"; then
            shipyard_reap "$pending_window_id" || true
            return 1
        fi
    fi

    base_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"

    shipyard_record_lease "$window_id" "$worktree" "$lease_id" "$lease_holder"
    tmux set-option -w -t "$window_id" @shipyard_intent "$intent"
    tmux set-option -w -t "$window_id" @shipyard_worktree "$worktree"
    tmux set-option -w -t "$window_id" @shipyard_lease_id "$lease_id"
    tmux set-option -w -t "$window_id" @shipyard_base_head "$base_head"
    tmux set-option -w -t "$window_id" @pipeline_manual_state planning
    tmux set-option -w -t "$window_id" @pipeline_state planning
    tmux set-option -w -t "$window_id" @pipeline_badge "$(pipeline_badge_for planning)"
    watcher_command="$(shipyard_watcher_command "$window_id" "$worktree")"
    tmux run-shell -b "$watcher_command"

    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$window_id"
    else
        tmux select-window -t "$window_id"
        tmux attach-session -t "=$session_name"
    fi
}

shipyard_reap() {
    local window_id="${1:-}"
    local lease_file
    local recorded_window_id
    local path
    local lease_id
    local lease_holder
    local result=0

    [[ -n "$window_id" ]] || return 2
    if tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fxq "$window_id"; then
        return 0
    fi

    for lease_file in "$(shipyard_state_home)"/windows/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r recorded_window_id path lease_id lease_holder < "$lease_file"
        [[ "$recorded_window_id" == "$window_id" ]] || continue
        if treehouse return "$path" --if-lease-id "$lease_id"; then
            rm -f "$lease_file"
        else
            result=1
        fi
    done
    rmdir "$(shipyard_state_home)/watch-${window_id}.lock" 2>/dev/null || true
    return "$result"
}

shipyard_reconcile() {
    local lease_file
    local window_id
    local state_home

    state_home="$(shipyard_state_home)"
    mkdir -p "$state_home/windows"
    for lease_file in "$state_home"/windows/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r window_id _ < "$lease_file"
        shipyard_reap "$window_id" || true
    done
}
