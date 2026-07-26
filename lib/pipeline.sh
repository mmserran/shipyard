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
            printf ' 💡 '
            ;;

        building)
            printf ' ● '
            ;;

        validating)
            printf ' 🔍 '
            ;;

        attention)
            printf '#[fg=white,bg=red,bold] 🔔 #[default]'
            ;;

        published)
            printf '#[fg=black,bg=yellow,bold] 📬 #[default]'
            ;;

        merged)
            printf ' 🚢 '
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

    tmux set-option -w @pipeline_manual_state "$state"
    tmux set-option -w @pipeline_state "$state"
    tmux set-option -w @pipeline_badge "$badge"
    tmux refresh-client -S 2>/dev/null || true

    printf 'Pipeline state: %s\n' "$state"
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

    local intent
    local pr
    intent="$(tmux show-options -wqv @shipyard_intent)"
    pr="$(tmux show-options -wqv @shipyard_pr)"
    [[ -z "$intent" ]] || printf 'Intent: %s\n' "$intent"
    [[ -z "$pr" ]] || printf 'PR: %s\n' "$pr"
}
