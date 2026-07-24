#!/usr/bin/env bash

AGENTS_BLOCK_START='<!-- shipyard:start -->'
AGENTS_BLOCK_END='<!-- shipyard:end -->'

agents_print_block() {
    local source_agents="$1"

    printf '%s\n' "$AGENTS_BLOCK_START"
    cat "$source_agents"
    printf '%s\n' "$AGENTS_BLOCK_END"
}

agents_replace_block() {
    local project_agents="$1"
    local source_agents="$2"
    local tmp
    tmp="$(mktemp)"

    local in_block=0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$AGENTS_BLOCK_START" ]]; then
            agents_print_block "$source_agents" >>"$tmp"
            in_block=1
            continue
        fi

        if [[ "$line" == "$AGENTS_BLOCK_END" ]]; then
            in_block=0
            continue
        fi

        [[ "$in_block" -eq 1 ]] && continue

        printf '%s\n' "$line" >>"$tmp"
    done <"$project_agents"

    mv "$tmp" "$project_agents"
}

# Keeps a project's own AGENTS.md untouched while ensuring Shipyard's forge
# workflow instructions are present in a clearly delimited block. Safe to
# call on every `forge open`: creates the file if missing, appends the block
# once if the file exists without it, and refreshes the block in place if
# Shipyard's own AGENTS.md has since changed.
agents_sync() {
    local project_root="$1"
    local project_agents="$project_root/AGENTS.md"
    local source_agents="$SHIPYARD_HOME/AGENTS.md"

    [[ -f "$source_agents" ]] || return 0

    # Never sync Shipyard's own AGENTS.md into itself.
    if [[ "$(cd "$project_root" && pwd -P)" == "$(cd "$SHIPYARD_HOME" && pwd -P)" ]]; then
        return 0
    fi

    if [[ ! -f "$project_agents" ]]; then
        agents_print_block "$source_agents" >"$project_agents"
        return
    fi

    if grep -qxF "$AGENTS_BLOCK_START" "$project_agents"; then
        agents_replace_block "$project_agents" "$source_agents"
    else
        {
            printf '\n'
            agents_print_block "$source_agents"
        } >>"$project_agents"
    fi
}
