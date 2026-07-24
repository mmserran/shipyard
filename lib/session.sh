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

shipyard_new() {
    local intent="${*:-}"
    local project_root
    local session_name
    local lease_holder
    local lease_json
    local worktree
    local lease_id
    local window_id

    if [[ -z "$intent" ]]; then
        printf 'forge: usage: forge new <intent>\n' >&2
        return 2
    fi

    project_root="$(shipyard_project_root "$PWD")" || return
    session_name="$(shipyard_session_name "$project_root")"

    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    if ! command -v treehouse >/dev/null 2>&1; then
        printf 'forge: treehouse is not installed\n' >&2
        return 1
    fi

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

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        window_id="$(tmux new-session -d -P -F '#{window_id}' \
            -s "$session_name" -n "$intent" -c "$worktree")"
    else
        window_id="$(tmux new-window -d -P -F '#{window_id}' \
            -t "=$session_name:" -n "$intent" -c "$worktree")"
    fi

    tmux set-option -w -t "$window_id" @shipyard_intent "$intent"
    tmux set-option -w -t "$window_id" @shipyard_worktree "$worktree"
    tmux set-option -w -t "$window_id" @shipyard_lease_id "$lease_id"
    tmux set-option -w -t "$window_id" @pipeline_manual_state planning
    tmux set-option -w -t "$window_id" @pipeline_state planning
    tmux set-option -w -t "$window_id" @pipeline_badge "$(pipeline_badge_for planning)"
    shipyard_record_lease "$window_id" "$worktree" "$lease_id" "$lease_holder"
    tmux run-shell -b "$SHIPYARD_HOME/bin/forge watch '$window_id' '$worktree'"

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
