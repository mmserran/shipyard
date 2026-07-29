#!/usr/bin/env bash

shipyard_project_root() {
    local requested_path="$1"
    local resolved_path
    local common_dir

    if ! resolved_path="$(cd "$requested_path" 2>/dev/null && pwd -P)"; then
        printf 'forge: directory not found: %s\n' "$requested_path" >&2
        return 1
    fi

    # Resolve through the shared git-common-dir rather than --show-toplevel:
    # every worktree of a repository (including Treehouse-leased ones) shares
    # one common-dir, so this keeps forge new landing in the same tmux
    # session regardless of which worktree it's invoked from. --show-toplevel
    # would instead return each worktree's own directory, so running forge
    # new from inside an already-leased worktree would fail to recognize the
    # project and spin up a colliding new session.
    if common_dir="$(git -C "$resolved_path" rev-parse --git-common-dir 2>/dev/null)"; then
        case "$common_dir" in
            /*) ;;
            *) common_dir="$resolved_path/$common_dir" ;;
        esac
        if [[ "$(basename "$common_dir")" == ".git" ]]; then
            (cd "$common_dir/.." && pwd -P)
        else
            (cd "$common_dir" && pwd -P)
        fi
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

shipyard_command_window() {
    local session_name="$1"

    tmux list-windows -t "=$session_name" -F '#{window_id} #{@shipyard_role}' 2>/dev/null |
        awk '$2 == "command" {print $1; exit}'
}

# Unlike `forge new`, this window is not leased from Treehouse and carries no
# intent metadata or watcher: it's a plain shell rooted in the project itself,
# for commands that operate on the repository rather than a unit of work.
shipyard_open() {
    local requested_path="${1:-.}"
    local project_root
    local session_name
    local window_id

    project_root="$(shipyard_project_root "$requested_path")" || return
    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    session_name="$(shipyard_session_for_project "$project_root")"

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        if ! window_id="$(tmux new-session -d -P -F '#{window_id}' \
            -s "$session_name" -n command -c "$project_root")"; then
            return 1
        fi
        tmux set-option -t "$session_name" @shipyard_project_root "$project_root"
        tmux set-option -w -t "$window_id" @shipyard_role command
    else
        window_id="$(shipyard_command_window "$session_name")"
        if [[ -z "$window_id" ]]; then
            if ! window_id="$(tmux new-window -d -P -F '#{window_id}' \
                -t "=$session_name:" -n command -c "$project_root")"; then
                return 1
            fi
            tmux set-option -w -t "$window_id" @shipyard_role command
        fi
    fi

    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$window_id"
    else
        tmux select-window -t "$window_id"
        tmux attach-session -t "=$session_name"
    fi
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

# Removes a window's own lease-tracking record, without touching Treehouse.
# For callers that already returned the lease themselves (the exit() guard,
# forge close) so the window-unlinked hook's later shipyard_reap finds
# nothing left to reap for this window and cleanly no-ops, rather than
# attempting a second `treehouse return` on an already-released lease.
shipyard_forget_lease() {
    local window_id="$1"
    local lease_file
    local recorded_window_id

    for lease_file in "$(shipyard_state_home)/windows"/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r recorded_window_id _ < "$lease_file"
        [[ "$recorded_window_id" == "$window_id" ]] && rm -f "$lease_file"
    done
}

shipyard_watcher_command() {
    local window_id="$1"
    local worktree="$2"
    local command

    printf -v command '%q watch %q %q' \
        "$SHIPYARD_HOME/bin/forge" "$window_id" "$worktree"
    printf '%s\n' "$command"
}

# Treehouse's pool worktrees are pre-warmed against the backing repo's
# default branch as of whenever they were created or last returned, which
# drifts from the remote's actual default branch over time. Resolve it from
# the remote directly rather than trusting a local refs/remotes/origin/HEAD
# symref, which is set once at clone time and otherwise never refreshed.
shipyard_default_branch() {
    local worktree="$1"

    git -C "$worktree" ls-remote --symref origin HEAD 2>/dev/null \
        | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p'
}

shipyard_sync_worktree() {
    local worktree="$1"
    local base_branch="$2"

    git -C "$worktree" fetch --quiet origin \
        "$base_branch:refs/remotes/origin/$base_branch" 2>/dev/null || return 1
    git -C "$worktree" checkout --quiet --detach "origin/$base_branch" 2>/dev/null || return 1
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
    local base_branch
    local top_pane_id

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

    if base_branch="$(shipyard_default_branch "$worktree")" && [[ -n "$base_branch" ]]; then
        if ! shipyard_sync_worktree "$worktree" "$base_branch"; then
            printf 'forge: warning: could not sync worktree to origin/%s; continuing with its current checkout\n' \
                "$base_branch" >&2
        fi
    else
        printf 'forge: warning: could not determine origin'"'"'s default branch; continuing with the worktree'"'"'s current checkout\n' >&2
    fi

    lease_id="$(sed -n 's/.*"lease_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$lease_json")"
    if [[ -z "$lease_id" ]]; then
        printf 'forge: Treehouse response did not include a lease id\n' >&2
        # --force is safe here: this worktree was only just synced, before
        # any window or work existed, so there is nothing local to lose.
        treehouse return "$worktree" --if-lease-holder "$lease_holder" --force || true
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

    top_pane_id="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
    tmux split-window -v -p 25 -t "$window_id" -c "$worktree"
    tmux select-pane -t "$top_pane_id"

    base_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"

    shipyard_record_lease "$window_id" "$worktree" "$lease_id" "$lease_holder"
    tmux set-option -w -t "$window_id" @shipyard_intent "$intent"
    tmux set-option -w -t "$window_id" @shipyard_worktree "$worktree"
    tmux set-option -w -t "$window_id" @shipyard_lease_id "$lease_id"
    tmux set-option -w -t "$window_id" @shipyard_base_head "$base_head"
    tmux set-option -w -t "$window_id" @shipyard_base_branch "$base_branch"
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

# Force-closes the current window. Running this command at all is the
# explicit "I want to close" signal (unlike exit(), which protects against
# losing work by accident), so uncommitted changes are discarded rather than
# prompted for -- but reported, not silent. Aborts an active no-mistakes run
# for this branch first, so its daemon isn't left tracking a worktree
# Treehouse is about to reset and potentially hand to a different unit of
# work out from under it.
shipyard_close() {
    local window_id
    local worktree
    local lease_id
    local status_output
    local run_output

    window_id="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)"
    if [[ -z "$window_id" ]]; then
        printf 'forge: not inside a tmux window\n' >&2
        return 1
    fi

    worktree="$(tmux show-options -wqv -t "$window_id" @shipyard_worktree 2>/dev/null)"
    lease_id="$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id 2>/dev/null)"
    if [[ -z "$worktree" || -z "$lease_id" ]]; then
        printf 'forge: not a leased intent window\n' >&2
        return 1
    fi

    if command -v no-mistakes >/dev/null 2>&1; then
        run_output="$(cd "$worktree" && no-mistakes axi status 2>/dev/null)" || run_output=""
        # No outcome: line means the run hasn't reached a terminal state
        # (checks-passed/passed/failed/cancelled) -- it's still active.
        if [[ -n "$run_output" ]] && ! grep -q '^outcome:' <<<"$run_output"; then
            printf 'forge: aborting the active no-mistakes run for this branch\n' >&2
            (cd "$worktree" && no-mistakes axi abort) 2>&1 | sed 's/^/forge: /' >&2
        fi
    fi

    status_output="$(git -C "$worktree" status --short 2>/dev/null)"
    if [[ -n "$status_output" ]]; then
        printf 'forge: closing %s and discarding uncommitted changes:\n%s\n' \
            "$worktree" "$status_output" >&2
    fi

    if ! treehouse return "$worktree" --if-lease-id "$lease_id" --force; then
        printf 'forge: failed to return the Treehouse lease; not closing the window\n' >&2
        return 1
    fi

    shipyard_forget_lease "$window_id"
    tmux kill-window -t "$window_id"
}

shipyard_reap() {
    local window_id="${1:-}"
    local lease_file
    local recorded_window_id
    local path
    local lease_id
    local lease_holder
    local result=0
    local return_output
    local return_status

    [[ -n "$window_id" ]] || return 2
    if tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fxq "$window_id"; then
        return 0
    fi

    for lease_file in "$(shipyard_state_home)"/windows/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r recorded_window_id path lease_id lease_holder < "$lease_file"
        [[ "$recorded_window_id" == "$window_id" ]] || continue
        # Without --force, `treehouse return` exits 0 even when it declines
        # (uncommitted changes, no TTY to answer "Clean and return?") --
        # trusting the exit code alone would delete this lease's only
        # record while Treehouse still holds it, orphaning the slot beyond
        # anything shipyard_reconcile can ever retry. Check the output too.
        return_output="$(treehouse return "$path" --if-lease-id "$lease_id" < /dev/null 2>&1)"
        return_status=$?
        printf '%s\n' "$return_output" >&2
        if [[ "$return_status" -eq 0 && "$return_output" != *Aborted* ]]; then
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
