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

shipyard_repo_window() {
    local session_name="$1"

    tmux list-windows -t "=$session_name" -F '#{window_id} #{@shipyard_role}' 2>/dev/null |
        awk '$2 == "repo" {print $1; exit}'
}

# Numbers only intent windows, in their tmux order. Repository-level windows
# deliberately have no visible number in the status bar.
shipyard_refresh_intent_numbers() {
    local session_name="$1"
    local window_id
    local number=0

    while IFS= read -r window_id; do
        [[ -n "$window_id" ]] || continue
        number=$((number + 1))
        tmux set-option -w -t "$window_id" @shipyard_intent_number "$number"
    done < <(tmux list-windows -t "=$session_name" \
        -F '#{?@shipyard_worktree,#{window_id},}' 2>/dev/null)
}

# Creates the decorative repo-named Yazi window if missing and keeps it
# leftmost so it replaces the old status-left project label. Callers must
# already have verified that yazi is on PATH and that the session exists.
shipyard_ensure_repo_window() {
    local session_name="$1"
    local project_root="$2"
    local repo_window_id
    local first_window_id

    repo_window_id="$(shipyard_repo_window "$session_name")"
    if [[ -z "$repo_window_id" ]]; then
        if ! repo_window_id="$(tmux new-window -d -P -F '#{window_id}' \
            -b -t "=$session_name:^" -n "$session_name" -c "$project_root" yazi)"; then
            return 1
        fi
        tmux set-option -w -t "$repo_window_id" @shipyard_role repo
    else
        first_window_id="$(tmux list-windows -t "=$session_name" -F '#{window_id}' | head -n 1)"
        if [[ "$repo_window_id" != "$first_window_id" ]]; then
            tmux move-window -b -s "$repo_window_id" -t "=$session_name:^"
        fi
    fi

    printf '%s\n' "$repo_window_id"
}

# Creates (or reuses) a project's tmux session, Yazi repo window, and command
# window, without attaching. Shared by shipyard_open and every restore path
# (`forge open` with no path, recreating a session `forge pause` tore down)
# so both stay in lockstep on how a project's windows are structured.
#
# Unlike `forge new`, these windows are not leased from Treehouse and carry no
# intent metadata or watcher. The repo window runs Yazi at the project root;
# the command window remains a plain shell for repository-wide commands.
shipyard_ensure_project_session() {
    local project_root="$1"
    local session_name="$2"
    local repo_window_id
    local command_window_id

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        if ! repo_window_id="$(tmux new-session -d -P -F '#{window_id}' \
            -s "$session_name" -n "$session_name" -c "$project_root" yazi)"; then
            return 1
        fi
        tmux set-option -t "$session_name" @shipyard_project_root "$project_root"
        tmux set-option -w -t "$repo_window_id" @shipyard_role repo
    else
        if ! repo_window_id="$(shipyard_ensure_repo_window "$session_name" "$project_root")"; then
            return 1
        fi
    fi

    command_window_id="$(shipyard_command_window "$session_name")"
    if [[ -z "$command_window_id" ]]; then
        if ! command_window_id="$(tmux new-window -d -P -F '#{window_id}' \
                -t "=$session_name:" -n command -c "$project_root")"; then
            return 1
        fi
        tmux set-option -w -t "$command_window_id" @shipyard_role command
    fi

    shipyard_refresh_window_context "$command_window_id"
    shipyard_refresh_intent_numbers "$session_name"
    printf '%s\n' "$command_window_id"
}

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
    if ! command -v yazi >/dev/null 2>&1; then
        printf 'forge: yazi is not installed\n' >&2
        return 1
    fi

    session_name="$(shipyard_session_for_project "$project_root")"
    window_id="$(shipyard_ensure_project_session "$project_root" "$session_name")" || return 1

    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$window_id"
    else
        tmux select-window -t "$window_id"
        tmux attach-session -t "=$session_name"
    fi
}

# Attaches to the first pre-existing shipyard session's command (or repo)
# window. Unlike shipyard_open, this never creates a session -- it only
# reattaches to one that's already running, so plain `forge` is safe to run
# without accidentally spinning up a project session from the wrong directory.
shipyard_attach() {
    local session_name
    local window_id

    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    while IFS= read -r session_name; do
        [[ -n "$session_name" ]] || continue
        [[ -n "$(tmux show-options -qv -t "$session_name" @shipyard_project_root 2>/dev/null)" ]] || continue

        window_id="$(shipyard_command_window "$session_name")"
        if [[ -z "$window_id" ]]; then
            window_id="$(shipyard_repo_window "$session_name")"
        fi
        [[ -n "$window_id" ]] || continue

        if [[ -n "${TMUX:-}" ]]; then
            tmux switch-client -t "$window_id"
        else
            tmux select-window -t "$window_id"
            tmux attach-session -t "=$session_name"
        fi
        return
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    printf 'No existing shipyard windows are open\n'
}

shipyard_state_home() {
    printf '%s/shipyard' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shipyard_intent_file() {
    local lease_id="$1"
    printf '%s/intents/%s.intent\n' "$(shipyard_state_home)" "$lease_id"
}

# Durable intent metadata is separate from tmux's ephemeral IDs. The file is
# replaced atomically so an abrupt power loss leaves either the old complete
# snapshot or the new one, never a partially-written manifest.
shipyard_record_intent() {
    local lease_id="$1"
    local project_root="$2"
    local session_name="$3"
    local intent="$4"
    local worktree="$5"
    local lease_holder="$6"
    local base_head="${7:--}"
    local base_branch="${8:--}"
    local agent="${9:--}"
    local state_home
    local intent_file
    local temporary_file

    state_home="$(shipyard_state_home)"
    mkdir -p "$state_home/intents"
    intent_file="$(shipyard_intent_file "$lease_id")"
    temporary_file="${intent_file}.tmp.$$"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$lease_id" "$project_root" "$session_name" "$intent" "$worktree" \
        "$lease_holder" "$base_head" "$base_branch" "$agent" > "$temporary_file"
    mv -f "$temporary_file" "$intent_file"
}

shipyard_forget_intent() {
    local lease_id="$1"
    rm -f "$(shipyard_intent_file "$lease_id")"
}

shipyard_project_file() {
    local session_name="$1"
    printf '%s/projects/%s.project\n' "$(shipyard_state_home)" "$session_name"
}

# Durable record of a paused session's repository identity. Intent manifests
# already survive tmux loss on their own, so they cover intent windows; a
# repo/command-only session (no intents yet) has nothing else recording that
# it existed, so `forge pause` writes this and `forge open` consumes it to
# recreate exactly those two windows.
shipyard_record_project() {
    local session_name="$1"
    local project_root="$2"
    local state_home
    local project_file
    local temporary_file

    state_home="$(shipyard_state_home)"
    mkdir -p "$state_home/projects"
    project_file="$(shipyard_project_file "$session_name")"
    temporary_file="${project_file}.tmp.$$"
    printf '%s\t%s\n' "$session_name" "$project_root" > "$temporary_file"
    mv -f "$temporary_file" "$project_file"
}

shipyard_forget_project() {
    local session_name="$1"
    rm -f "$(shipyard_project_file "$session_name")"
}

shipyard_snapshot_agent() {
    local window_id="$1"
    local lease_id
    local intent_file
    local fields
    local agent
    local lease_file recorded_window_id worktree recorded_lease_id lease_holder
    local project_root session_name intent base_head base_branch

    lease_id="$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id 2>/dev/null)"
    [[ -n "$lease_id" ]] || return 0
    intent_file="$(shipyard_intent_file "$lease_id")"
    if [[ ! -f "$intent_file" ]]; then
        lease_file="$(shipyard_state_home)/windows/${lease_id}.lease"
        [[ -f "$lease_file" ]] || return 0
        IFS=$'\t' read -r recorded_window_id worktree recorded_lease_id lease_holder < "$lease_file"
        [[ "$recorded_window_id" == "$window_id" && "$recorded_lease_id" == "$lease_id" ]] || return 0
        session_name="$(tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null)"
        project_root="$(tmux show-options -qv -t "$session_name" @shipyard_project_root 2>/dev/null)"
        intent="$(tmux show-options -wqv -t "$window_id" @shipyard_intent 2>/dev/null)"
        base_head="$(tmux show-options -wqv -t "$window_id" @shipyard_base_head 2>/dev/null)"
        base_branch="$(tmux show-options -wqv -t "$window_id" @shipyard_base_branch 2>/dev/null)"
        [[ -n "$project_root" && -n "$session_name" && -n "$intent" && -n "$worktree" ]] || return 0
        shipyard_record_intent "$lease_id" "$project_root" "$session_name" "$intent" \
            "$worktree" "$lease_holder" "$base_head" "$base_branch"
    fi
    agent="$(tmux list-panes -t "$window_id" \
        -F '#{@shipyard_main_pane}|#{pane_current_command}' 2>/dev/null |
        awk -F '|' '$1 == "1" { print $2; exit }')"
    case "$agent" in
        codex|claude|cursor-agent) ;;
        *) return 0 ;;
    esac
    IFS=$'\t' read -r -a fields < "$intent_file"
    [[ "${fields[8]:-}" == "$agent" ]] && return 0
    shipyard_record_intent "${fields[0]}" "${fields[1]}" "${fields[2]}" \
        "${fields[3]}" "${fields[4]}" "${fields[5]}" "${fields[6]}" \
        "${fields[7]}" "$agent"
}

shipyard_lease_is_current() {
    local lease_id="$1"
    local status_json

    # Exit codes are not interchangeable: 1 means the probe succeeded and
    # proved the lease absent (safe to forget); 2 means the probe itself
    # failed (daemon down, transient error) and the lease's fate is unknown.
    # Callers that wipe durable state on "not current" must treat these
    # differently, or a transient treehouse failure during bare `forge open`
    # (restore) would permanently destroy the manifests it exists to preserve.
    status_json="$(treehouse status --json 2>/dev/null)" || return 2
    grep -Fq '"lease_id":"'"$lease_id"'"' <<<"$status_json"
}

shipyard_resume_hint() {
    case "$1" in
        codex) printf 'codex resume\n' ;;
        claude) printf 'claude --continue\n' ;;
        cursor-agent) printf 'cursor-agent --resume\n' ;;
        *) printf 'codex resume  # or: claude --continue / cursor-agent --resume [thread-id]\n' ;;
    esac
}

shipyard_restore_intent() {
    local intent_file="$1"
    local lease_id project_root session_name intent worktree lease_holder base_head base_branch agent
    local window_id top_pane_id watcher_command hint

    IFS=$'\t' read -r lease_id project_root session_name intent worktree lease_holder \
        base_head base_branch agent < "$intent_file"
    [[ -n "$lease_id" && -n "$project_root" && -n "$session_name" && -n "$intent" && -n "$worktree" ]] || {
        printf 'forge: invalid intent manifest: %s\n' "$intent_file" >&2
        return 1
    }
    [[ "$base_head" == "-" ]] && base_head=""
    [[ "$base_branch" == "-" ]] && base_branch=""
    [[ "$agent" == "-" ]] && agent=""

    local lease_status=0
    shipyard_lease_is_current "$lease_id" || lease_status=$?
    if [[ "$lease_status" -eq 2 ]]; then
        printf 'forge: cannot restore %s: could not confirm Treehouse lease %s status; leaving manifest for a later retry\n' \
            "$intent" "$lease_id" >&2
        return 1
    fi
    if [[ ! -d "$worktree" || "$lease_status" -eq 1 ]]; then
        printf 'forge: cannot restore %s: Treehouse lease %s is no longer active at %s\n' \
            "$intent" "$lease_id" "$worktree" >&2
        shipyard_forget_intent "$lease_id"
        rm -f "$(shipyard_state_home)/windows/${lease_id}.lease"
        return 1
    fi

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        window_id="$(tmux new-session -d -P -F '#{window_id}' \
            -s "$session_name" -n "$intent" -c "$worktree")" || return
        tmux set-option -t "$session_name" @shipyard_project_root "$project_root"
    else
        while IFS= read -r window_id; do
            [[ -n "$window_id" ]] || continue
            if [[ "$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id)" == "$lease_id" ]]; then
                return 0
            fi
        done < <(tmux list-windows -t "=$session_name" -F '#{window_id}')
        window_id="$(tmux new-window -d -P -F '#{window_id}' \
            -t "=$session_name:" -n "$intent" -c "$worktree")" || return
    fi

    top_pane_id="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
    tmux set-option -p -t "$top_pane_id" @shipyard_main_pane 1
    tmux split-window -v -p 25 -t "$window_id" -c "$worktree"
    tmux select-pane -t "$top_pane_id"
    tmux set-option -w -t "$window_id" @shipyard_intent "$intent"
    tmux set-option -w -t "$window_id" @shipyard_worktree "$worktree"
    tmux set-option -w -t "$window_id" @shipyard_lease_id "$lease_id"
    tmux set-option -w -t "$window_id" @shipyard_base_head "$base_head"
    tmux set-option -w -t "$window_id" @shipyard_base_branch "$base_branch"
    tmux set-option -w -t "$window_id" @pipeline_manual_state planning
    tmux set-option -w -t "$window_id" @pipeline_state planning
    tmux set-option -w -t "$window_id" @pipeline_badge "$(pipeline_badge_for planning)"
    shipyard_record_lease "$window_id" "$worktree" "$lease_id" "$lease_holder"
    watcher_command="$(shipyard_watcher_command "$window_id" "$worktree")"
    tmux run-shell -b "$watcher_command"
    hint="$(shipyard_resume_hint "$agent")"
    tmux send-keys -t "$top_pane_id" \
        "printf '\\nRestored Shipyard intent. Resume your agent with:\\n  %s\\n\\n' '$hint'" Enter
}

shipyard_restore() {
    local state_home intent_file project_file session_name project_root existing_root
    local target_window="" result=0
    local found_intent=0
    local found_project=0
    local window_id

    state_home="$(shipyard_state_home)"
    for dependency in tmux treehouse yazi; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            printf 'forge: %s is not installed\n' "$dependency" >&2
            return 1
        fi
    done
    mkdir -p "$state_home/intents" "$state_home/projects"

    for intent_file in "$state_home"/intents/*.intent; do
        [[ -e "$intent_file" ]] || continue
        found_intent=1
        if ! shipyard_restore_intent "$intent_file"; then
            result=1
        fi
    done

    # Repo/command-only sessions (no intents of their own) have no other
    # durable record; a paused project's manifest is the only thing that can
    # rebuild them. Keep it on ensure failure so a later retry can still
    # recreate the session; drop it only after a successful ensure, when the
    # live session belongs to this same project root, or when the record is
    # corrupt. A basename collision with a different (or unmarked) session
    # must keep the file — pause frees short names that
    # shipyard_session_for_project will hand to another project without
    # consulting paused manifests.
    for project_file in "$state_home"/projects/*.project; do
        [[ -e "$project_file" ]] || continue
        found_project=1
        IFS=$'\t' read -r session_name project_root < "$project_file"
        if [[ -z "$session_name" || -z "$project_root" ]]; then
            rm -f "$project_file"
            continue
        fi
        if tmux has-session -t "=$session_name" 2>/dev/null; then
            existing_root="$(tmux show-options -qv -t "$session_name" @shipyard_project_root 2>/dev/null)"
            if [[ "$existing_root" == "$project_root" ]]; then
                rm -f "$project_file"
            else
                result=1
            fi
            continue
        fi
        if shipyard_ensure_project_session "$project_root" "$session_name" >/dev/null; then
            rm -f "$project_file"
        else
            result=1
        fi
    done

    while IFS= read -r session_name; do
        [[ -n "$session_name" ]] || continue
        if window_id="$(shipyard_ensure_project_session \
            "$(tmux show-options -qv -t "$session_name" @shipyard_project_root)" "$session_name")"; then
            [[ -n "$target_window" ]] || target_window="$window_id"
        else
            result=1
        fi
    done < <(tmux list-sessions -F '#{?@shipyard_project_root,#{session_name},}' 2>/dev/null)

    if [[ -z "$target_window" ]]; then
        [[ "$found_intent" -eq 1 || "$found_project" -eq 1 ]] ||
            printf 'forge: no prior sessions; pass a path to open a project (forge open <path>)\n'
        return "$result"
    fi
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$target_window"
    else
        tmux attach-session -t "$target_window"
    fi
    return "$result"
}

# Saves everything needed to fully recreate every open shipyard session, then
# tears them down. Intent windows are already durable via their manifest
# (refreshed here so the resume hint reflects the latest observed agent); a
# repository's plain repo/command windows are not durable anywhere else, so
# their identity is recorded too. Each intent window's lease record is
# disarmed before the session dies, so the window-unlinked hook's later
# `forge reap` has nothing to return -- the lease stays active in Treehouse
# throughout, and `forge open` rebuilds a fresh lease record for the window
# it recreates.
shipyard_pause() {
    local session_name
    local project_root
    local window_id
    local paused=0
    local current_session=""
    local deferred_session=""
    local sessions=""
    local kill_cmd

    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    if [[ -n "${TMUX_PANE:-}" ]]; then
        current_session="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" || true
    fi

    while IFS= read -r session_name; do
        [[ -n "$session_name" ]] || continue
        project_root="$(tmux show-options -qv -t "$session_name" @shipyard_project_root)"
        [[ -n "$project_root" ]] || continue

        while IFS= read -r window_id; do
            [[ -n "$window_id" ]] || continue
            shipyard_snapshot_agent "$window_id"
            shipyard_disarm_lease "$window_id"
        done < <(tmux list-windows -t "=$session_name" \
            -F '#{?@shipyard_worktree,#{window_id},}' 2>/dev/null)

        shipyard_record_project "$session_name" "$project_root"
        sessions+="${session_name}"$'\n'
        if [[ -n "$current_session" && "$session_name" == "$current_session" ]]; then
            deferred_session="$session_name"
        fi
        paused=$((paused + 1))
    done < <(tmux list-sessions -F '#{?@shipyard_project_root,#{session_name},}' 2>/dev/null)

    while IFS= read -r session_name; do
        [[ -n "$session_name" ]] || continue
        if [[ -n "$deferred_session" && "$session_name" == "$deferred_session" ]]; then
            continue
        fi
        tmux kill-session -t "=$session_name"
    done <<< "$sessions"

    if [[ "$paused" -eq 0 ]]; then
        printf 'forge: no open shipyard sessions to pause\n'
        return 0
    fi
    printf 'forge: paused %d shipyard session(s); run `forge open` to restore\n' "$paused"

    if [[ -n "$deferred_session" ]]; then
        printf -v kill_cmd 'tmux kill-session -t %q' "=$deferred_session"
        tmux run-shell -b "$kill_cmd"
    fi
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
    local lease_id

    for lease_file in "$(shipyard_state_home)/windows"/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r recorded_window_id _ lease_id _ < "$lease_file"
        if [[ "$recorded_window_id" == "$window_id" ]]; then
            rm -f "$lease_file"
            shipyard_forget_intent "$lease_id"
        fi
    done
    return 0
}

# Removes just a window's lease-tracking record, leaving its intent manifest
# in place -- unlike shipyard_forget_lease, which also forgets the intent.
# `forge pause` calls this before tearing a window down so the window-unlinked
# hook's later `forge reap` finds no matching record and leaves the Treehouse
# lease alone, while the intent it's paired with survives for `forge open` to
# rebuild a fresh lease record around.
shipyard_disarm_lease() {
    local window_id="$1"
    local lease_file
    local recorded_window_id

    for lease_file in "$(shipyard_state_home)/windows"/*.lease; do
        [[ -e "$lease_file" ]] || continue
        IFS=$'\t' read -r recorded_window_id _ < "$lease_file"
        [[ "$recorded_window_id" == "$window_id" ]] && rm -f "$lease_file"
    done
    return 0
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

    if ! command -v yazi >/dev/null 2>&1; then
        printf 'forge: yazi is not installed\n' >&2
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
    base_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
    shipyard_record_intent "$lease_id" "$project_root" "$session_name" "$intent" \
        "$worktree" "$lease_holder" "$base_head" "$base_branch"

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

    if ! shipyard_ensure_repo_window "$session_name" "$project_root" >/dev/null; then
        tmux kill-window -t "$window_id" 2>/dev/null || true
        shipyard_reap "$pending_window_id" || true
        return 1
    fi

    top_pane_id="$(tmux display-message -p -t "$window_id" '#{pane_id}')"
    tmux set-option -p -t "$top_pane_id" @shipyard_main_pane 1
    tmux split-window -v -p 25 -t "$window_id" -c "$worktree"
    tmux select-pane -t "$top_pane_id"

    shipyard_record_lease "$window_id" "$worktree" "$lease_id" "$lease_holder"
    tmux set-option -w -t "$window_id" @shipyard_intent "$intent"
    tmux set-option -w -t "$window_id" @shipyard_worktree "$worktree"
    tmux set-option -w -t "$window_id" @shipyard_lease_id "$lease_id"
    tmux set-option -w -t "$window_id" @shipyard_base_head "$base_head"
    tmux set-option -w -t "$window_id" @shipyard_base_branch "$base_branch"
    tmux set-option -w -t "$window_id" @pipeline_manual_state planning
    tmux set-option -w -t "$window_id" @pipeline_state planning
    tmux set-option -w -t "$window_id" @pipeline_badge "$(pipeline_badge_for planning)"
    shipyard_refresh_intent_numbers "$session_name"
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
#
# On a command window there is no lease of its own. It acts as the repository
# close-all control: every intent lease is safely returned, then the whole
# session (including the command and Yazi windows) is closed.
shipyard_close() {
    local window_id
    local worktree
    local lease_id
    local role

    window_id="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)"
    if [[ -z "$window_id" ]]; then
        printf 'forge: not inside a tmux window\n' >&2
        return 1
    fi

    worktree="$(tmux show-options -wqv -t "$window_id" @shipyard_worktree 2>/dev/null)"
    lease_id="$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id 2>/dev/null)"
    if [[ -z "$worktree" || -z "$lease_id" ]]; then
        role="$(tmux show-options -wqv -t "$window_id" @shipyard_role 2>/dev/null)"
        if [[ "$role" == command ]]; then
            shipyard_close_command_window "$window_id"
            return
        fi
        if [[ "$role" == repo ]]; then
            printf 'forge: the repository Yazi window cannot be closed with forge close\n' >&2
            return 1
        fi
        printf 'forge: not a leased intent window\n' >&2
        return 1
    fi

    shipyard_close_intent_window "$window_id"
}

shipyard_close_intent_window() {
    local window_id="$1"
    local worktree
    local lease_id
    local status_output
    local run_output
    local session_name

    worktree="$(tmux show-options -wqv -t "$window_id" @shipyard_worktree 2>/dev/null)"
    lease_id="$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id 2>/dev/null)"
    if [[ -z "$worktree" || -z "$lease_id" ]]; then
        printf 'forge: not a leased intent window\n' >&2
        return 1
    fi
    session_name="$(tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null)"

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
    shipyard_forget_intent "$lease_id"
    tmux kill-window -t "$window_id"
    if tmux has-session -t "=$session_name" 2>/dev/null; then
        shipyard_refresh_intent_numbers "$session_name"
    fi
}

# Finds another open repo's Yazi window (or its command window for compatibility
# with sessions created by an older Shipyard), so closing a command window can
# hand the client straight to that repository.
shipyard_next_repo_window() {
    local exclude_session="$1"
    local session_name
    local candidate

    while IFS= read -r session_name; do
        [[ -n "$session_name" && "$session_name" != "$exclude_session" ]] || continue
        [[ -n "$(tmux show-options -qv -t "$session_name" @shipyard_project_root 2>/dev/null)" ]] || continue
        candidate="$(shipyard_repo_window "$session_name")"
        if [[ -z "$candidate" ]]; then
            candidate="$(shipyard_command_window "$session_name")"
        fi
        [[ -n "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# Closes every intent in the command window's repository, then removes its
# repository-level windows by killing the session. Each intent is closed via
# the same guarded lease-return path as a direct `forge close`.
shipyard_close_command_window() {
    local window_id="$1"
    local session_name
    local next_window
    local intent_window

    session_name="$(tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null)"
    next_window="$(shipyard_next_repo_window "$session_name")"

    while IFS= read -r intent_window; do
        [[ -n "$intent_window" ]] || continue
        if ! shipyard_close_intent_window "$intent_window"; then
            printf 'forge: failed to close all intent windows; repository session remains open\n' >&2
            return 1
        fi
    done < <(tmux list-windows -t "=$session_name" \
        -F '#{?@shipyard_worktree,#{window_id},}' 2>/dev/null)

    if [[ -n "$next_window" && -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$next_window"
    fi

    shipyard_forget_project "$session_name"
    tmux kill-session -t "=$session_name"
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
        if return_output="$(treehouse return "$path" --if-lease-id "$lease_id" < /dev/null 2>&1)"; then
            return_status=0
        else
            return_status=$?
        fi
        printf '%s\n' "$return_output" >&2
        if [[ "$return_status" -eq 0 && "$return_output" != *Aborted* ]]; then
            rm -f "$lease_file"
            shipyard_forget_intent "$lease_id"
        elif [[ "$return_output" == *"is not leased"* ]]; then
            # Treehouse already released this lease by some other path (e.g.
            # a manual `treehouse return --force`), so the precondition
            # fails even though there's nothing left to protect. Treat it
            # the same as success rather than leaving an orphaned record
            # that every future reconcile fails to clear.
            rm -f "$lease_file"
            shipyard_forget_intent "$lease_id"
        else
            shipyard_forget_intent "$lease_id"
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
        IFS=$'\t' read -r window_id _ lease_id _ < "$lease_file"
        # Intent remaining means no reap has claimed this window yet
        # (reboot / tmux loss). Preserve for bare `forge open` (restore).
        # After a normal window-unlinked reap, the intent is cleared even if
        # Treehouse declines, so reconcile can keep retrying the lease.
        [[ -f "$(shipyard_intent_file "$lease_id")" ]] && continue
        shipyard_reap "$window_id" || true
    done
}
