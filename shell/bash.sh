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
