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

shipyard_open() {
    local requested_path="${1:-.}"
    local project_root
    local session_name

    project_root="$(shipyard_project_root "$requested_path")" || return
    session_name="$(shipyard_session_name "$project_root")"

    agents_sync "$project_root"

    if ! command -v tmux >/dev/null 2>&1; then
        printf 'forge: tmux is not installed\n' >&2
        return 1
    fi

    if ! tmux has-session -t "=$session_name" 2>/dev/null; then
        tmux new-session \
            -d \
            -s "$session_name" \
            -n command \
            -c "$project_root"

        tmux set-window-option \
            -t "=$session_name:command" \
            @shipyard_role command
    fi

    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "=$session_name"
    else
        tmux attach-session -t "=$session_name"
    fi
}
