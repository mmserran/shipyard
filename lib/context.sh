#!/usr/bin/env bash

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
