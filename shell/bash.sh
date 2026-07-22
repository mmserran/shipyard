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

shipyard_auto_open() {
    [[ -z "${TMUX:-}" ]] || return 0
    [[ -z "${NO_AUTO_TMUX:-}" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    exec forge open "$PWD"
}

shipyard_auto_open
