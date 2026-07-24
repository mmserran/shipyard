#!/usr/bin/env bash

context_sync() {
    if [[ -z "${TMUX:-}" ]]; then
        printf 'forge: sync must run inside tmux\n' >&2
        return 1
    fi

    shipyard_update_context
    tmux refresh-client -S || true
}

context_open_no_mistakes_tui() {
    [[ -n "${TMUX:-}" ]] || return 0
    command -v no-mistakes >/dev/null 2>&1 || return 0

    # Don't stack a second attach pane if one is already watching this run.
    # pane_current_command reports the foreground interpreter (e.g. bash),
    # not the script name, so tag the pane's title instead and match on that.
    if tmux list-panes -F '#{pane_title}' | grep -qx 'no-mistakes'; then
        return 0
    fi

    local pane_id
    pane_id="$(tmux split-window -h -c "$PWD" -P -F '#{pane_id}' 'no-mistakes attach')" || return 0
    tmux select-pane -t "$pane_id" -T 'no-mistakes' || true
}

shipyard_git_context() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

shipyard_repo_name() {
    basename "$(git rev-parse --show-toplevel)"
}

shipyard_branch_name() {
    git branch --show-current 2>/dev/null
}

shipyard_update_context() {
    [[ -n "${TMUX:-}" ]] || return 0

    local role
    local repo
    local branch
    local pane_title
    local window_name

    if shipyard_git_context; then
        repo="$(shipyard_repo_name)"
        branch="$(shipyard_branch_name)"

        if [[ -n "$branch" ]]; then
            pane_title="$repo  $branch"
            window_name="$branch"
        else
            pane_title="$repo  detached"
            window_name="plan:$repo"
        fi
    else
        repo="$(basename "$PWD")"
        pane_title="$repo"
        window_name="$repo"
    fi

    # The terminal title is scoped to the current pane.
    printf '\033]2;%s\033\\' "$pane_title"

    # The command window retains its permanent identity.
    role="$(tmux show-options -wqv @shipyard_role)"

    if [[ "$role" == "command" ]]; then
        return 0
    fi

    # The window represents the current pipeline.
    tmux rename-window "$window_name"
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
