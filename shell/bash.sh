#!/usr/bin/env bash

export SHIPYARD_HOME="${SHIPYARD_HOME:-$HOME/.config/shipyard}"

case ":$PATH:" in
    *":$SHIPYARD_HOME/bin:"*)
        ;;
    *)
        export PATH="$SHIPYARD_HOME/bin:$PATH"
        ;;
esac

# shellcheck source=../lib/context.sh
source "$SHIPYARD_HOME/lib/context.sh"

# shellcheck source=../lib/session.sh
source "$SHIPYARD_HOME/lib/session.sh"

# Identifies the current pane's window as a leased intent window whose last
# pane is exiting (so closing it is about to close the whole window), and
# prints "window_id\tworktree\tlease_id". Empty/failing otherwise: not in
# tmux, a `forge open` command window (no lease), or a pane other than the
# last one (closing it won't close the window, nothing to guard). Targets
# $TMUX_PANE explicitly rather than relying on ambient current-pane
# resolution, since that's set reliably in any real pane.
shipyard_exit_worktree_info() {
    local window_id
    local lease_id
    local worktree
    local pane_count

    [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || return 1
    window_id="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)" || return 1
    [[ -n "$window_id" ]] || return 1

    lease_id="$(tmux show-options -wqv -t "$window_id" @shipyard_lease_id 2>/dev/null)"
    [[ -n "$lease_id" ]] || return 1

    pane_count="$(tmux list-panes -t "$window_id" 2>/dev/null | wc -l)"
    [[ "$pane_count" -le 1 ]] || return 1

    worktree="$(tmux show-options -wqv -t "$window_id" @shipyard_worktree 2>/dev/null)"
    [[ -n "$worktree" ]] || return 1

    printf '%s\t%s\t%s\n' "$window_id" "$worktree" "$lease_id"
}

# The decision logic behind the exit() guard below, kept separate so it's
# testable without ever calling `exit` itself. A clean worktree returns the
# lease right here (rather than waiting on the window-unlinked hook) and
# proceeds. A dirty one calls `treehouse return` without --force while a
# real TTY is still attached, so Treehouse's own "Clean and return? [Y/n]"
# prompt is answered by an actual person instead of silently declining.
shipyard_exit_should_proceed() {
    local window_id="$1"
    local worktree="$2"
    local lease_id="$3"
    local transcript
    local return_output
    local return_status

    if [[ -z "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]]; then
        if return_output="$(treehouse return "$worktree" --if-lease-id "$lease_id" 2>&1)"; then
            return_status=0
        else
            return_status=$?
        fi
        if [[ "$return_status" -eq 0 && "$return_output" != *Aborted* ]]; then
            shipyard_forget_lease "$window_id"
            return 0
        fi
        [[ -z "$return_output" ]] || printf '%s\n' "$return_output" >&2
    else
        # Without --force, `treehouse return` exits 0 even when it declines --
        # same as shipyard_reap, this can't trust the exit code alone. Unlike
        # shipyard_reap, though, a real person needs to see the prompt and
        # answer it live, so the output can't just be captured away either:
        # tee shows it on the real terminal while also keeping a copy to check.
        transcript="$(mktemp)" || return 1
        treehouse return "$worktree" --if-lease-id "$lease_id" 2>&1 | tee "$transcript"
        return_status=${PIPESTATUS[0]}
        if [[ "$return_status" -eq 0 ]] && ! grep -q Aborted "$transcript"; then
            rm -f "$transcript"
            shipyard_forget_lease "$window_id"
            return 0
        fi
        rm -f "$transcript"
    fi

    printf 'forge: not exiting -- commit, stash, or discard your changes first.\n' >&2
    return 1
}

exit() {
    local info
    local window_id
    local worktree
    local lease_id

    # A function, unlike the builtin, also runs inside subshells and command
    # substitutions ($(exit), a background job, ...). There, returning and
    # forgetting the lease would be real -- treehouse return and rm aren't
    # subshell-scoped -- while `builtin exit` only ends that child process,
    # leaving the top-level shell (and the window) still attached to a
    # worktree Treehouse may already have reset or handed to other work.
    # Only guard the actual top-level shell; anything else exits plainly.
    if [[ "${BASHPID:-$$}" != "$$" ]]; then
        builtin exit "$@"
        return
    fi

    info="$(shipyard_exit_worktree_info 2>/dev/null)"
    if [[ -z "$info" ]]; then
        builtin exit "$@"
        return
    fi

    IFS=$'\t' read -r window_id worktree lease_id <<< "$info"
    if shipyard_exit_should_proceed "$window_id" "$worktree" "$lease_id"; then
        builtin exit "$@"
    fi
}
