#!/usr/bin/env bash

pipeline_require_tmux() {
    if [[ -z "${TMUX:-}" ]]; then
        printf 'forge: pipeline commands must run inside tmux\n' >&2
        return 1
    fi
}

pipeline_badge_for() {
    case "$1" in
        planning)
            printf ''
            ;;

        building)
            printf '●'
            ;;

        waiting)
            printf '⏸'
            ;;

        ready)
            printf '✓'
            ;;

        validating)
            printf ''
            ;;

        attention)
            printf '#[fg=white,bg=red,bold] ⚠ #[default]'
            ;;

        complete)
            printf '✓✓'
            ;;

        *)
            return 1
            ;;
    esac
}

pipeline_set() {
    pipeline_require_tmux || return

    local state="$1"
    local badge

    if ! badge="$(pipeline_badge_for "$state")"; then
        printf 'forge: unknown pipeline state: %s\n' "$state" >&2
        return 2
    fi

    tmux set-option -w @pipeline_state "$state"
    tmux set-option -w @pipeline_badge "$badge"
    tmux refresh-client -S || true

    printf 'Pipeline state: %s\n' "$state"
}

pipeline_clear() {
    pipeline_require_tmux || return

    tmux set-option -wu @pipeline_state 2>/dev/null || true
    tmux set-option -wu @pipeline_badge 2>/dev/null || true
    tmux refresh-client -S || true

    printf 'Pipeline state cleared\n'
}

pipeline_status() {
    pipeline_require_tmux || return

    local state

    state="$(tmux show-options -wqv @pipeline_state)"

    if [[ -z "$state" ]]; then
        printf 'Pipeline state: none\n'
        return
    fi

    printf 'Pipeline state: %s\n' "$state"
}
