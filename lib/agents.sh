#!/usr/bin/env bash

# Subagent awareness for Claude Code orchestrator windows. Claude Code writes
# each session's transcript to
#   $CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session>.jsonl
# and every subagent it spawns to
#   .../<session>/subagents/agent-<id>.jsonl (+ agent-<id>.meta.json)
# so whether delegated work is running, and which PRs it opened, can be read
# straight off disk without scraping the terminal. Only Claude Code is
# understood; other agents leave every helper here reporting "none".

# Read-only helper types used while investigating; spawning these shouldn't
# flip a planning window into work-in-progress.
SHIPYARD_READONLY_AGENT_TYPES="${SHIPYARD_READONLY_AGENT_TYPES:-Explore Plan claude-code-guide statusline-setup}"

agents_claude_dir() {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# Claude Code names a project's transcript directory after its cwd with every
# non-alphanumeric character replaced by '-'.
agents_project_dir() {
    local worktree="$1"

    printf '%s/projects/%s\n' "$(agents_claude_dir)" "${worktree//[^a-zA-Z0-9]/-}"
}

# The most recently written top-level transcript is the live orchestrator
# session; older sessions in the same worktree are history.
agents_session_transcript() {
    local worktree="$1"
    local project_dir

    project_dir="$(agents_project_dir "$worktree")"
    [[ -d "$project_dir" ]] || return 1
    # shellcheck disable=SC2012 # session file names are UUIDs
    ls -t "$project_dir"/*.jsonl 2>/dev/null | head -n 1
}

agents_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

agents_is_readonly_type() {
    local agent_type="$1"
    local readonly_type

    for readonly_type in $SHIPYARD_READONLY_AGENT_TYPES; do
        [[ "$agent_type" == "$readonly_type" ]] && return 0
    done
    return 1
}

# A finished subagent's transcript ends with its final assistant turn.
agents_transcript_finished() {
    local last_line

    last_line="$(tail -n 1 "$1" 2>/dev/null)"
    [[ "$last_line" == *'"type":"assistant"'* && "$last_line" == *'"stop_reason":"end_turn"'* ]]
}

# Prints one of:
#   none     -- no work subagents in the current session (investigating, or
#               not a Claude orchestrator at all)
#   working  -- at least one work subagent is still running
#   paused   -- work subagents exist, but every one has finished, stalled
#               (unfinished yet silent for SHIPYARD_SUBAGENT_STALL_SECONDS),
#               or its orchestrator is no longer running
agents_subagent_activity() {
    local worktree="$1"
    local orchestrator_live="${2:-1}"
    local stall_seconds="${SHIPYARD_SUBAGENT_STALL_SECONDS:-600}"
    local transcript
    local subagent_dir
    local meta
    local agent_transcript
    local agent_type
    local now
    local mtime
    local seen=0

    transcript="$(agents_session_transcript "$worktree")" || true
    if [[ -z "$transcript" ]]; then
        printf 'none\n'
        return 0
    fi
    subagent_dir="${transcript%.jsonl}/subagents"
    now="$(date +%s)"

    for meta in "$subagent_dir"/agent-*.meta.json; do
        [[ -f "$meta" ]] || continue
        agent_type="$(sed -n 's/.*"agentType":"\([^"]*\)".*/\1/p' "$meta" | head -n 1)"
        agents_is_readonly_type "$agent_type" && continue
        seen=1
        [[ "$orchestrator_live" == 1 ]] || continue
        agent_transcript="${meta%.meta.json}.jsonl"
        [[ -f "$agent_transcript" ]] || continue
        agents_transcript_finished "$agent_transcript" && continue
        mtime="$(agents_mtime "$agent_transcript")"
        [[ -n "$mtime" ]] || continue
        if ((now - mtime < stall_seconds)); then
            printf 'working\n'
            return 0
        fi
    done

    if [[ "$seen" -eq 1 ]]; then
        printf 'paused\n'
    else
        printf 'none\n'
    fi
}

# owner/repo of the worktree's origin, for keeping only PRs in this product.
agents_github_repo() {
    local url

    url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    url="${url%.git}"
    case "$url" in
        *github.com[:/]*)
            printf '%s\n' "${url#*github.com[:/]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Prints the first PR, among those the current session or its subagents
# mention, that belongs to this worktree's repo, was created after the
# session started (so PRs the agent merely read about don't count), and is
# still open. PRs found merged, closed, or pre-dating the session are cached
# per session so they aren't asked about again.
agents_open_pr() {
    local worktree="$1"
    local transcript
    local session_start
    local repo
    local cache_dir
    local cache
    local url
    local info
    local state
    local created

    command -v gh >/dev/null 2>&1 || return 0
    transcript="$(agents_session_transcript "$worktree")" || true
    [[ -n "$transcript" ]] || return 0
    repo="$(agents_github_repo "$worktree")" || return 0
    session_start="$(grep -m 1 -o '"timestamp":"[^"]*"' "$transcript" | cut -d '"' -f 4)"
    [[ -n "$session_start" ]] || return 0

    cache_dir="$(shipyard_state_home)/agent-prs"
    mkdir -p "$cache_dir"
    cache="$cache_dir/$(basename "${transcript%.jsonl}")"
    touch "$cache"

    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        grep -Fxq "$url" "$cache" && continue
        info="$(gh pr view "$url" --json state,createdAt --jq '.state + " " + .createdAt' 2>/dev/null)" || continue
        state="${info%% *}"
        created="${info#* }"
        if [[ "${created:0:19}" < "${session_start:0:19}" || "$state" != "OPEN" ]]; then
            printf '%s\n' "$url" >>"$cache"
            continue
        fi
        printf '%s\n' "$url"
        return 0
    done < <(grep -ohE "https://github\.com/${repo//./\\.}/pull/[0-9]+" \
        "$transcript" "${transcript%.jsonl}"/subagents/agent-*.jsonl 2>/dev/null | sort -u)
}

# True while the window's main pane is running Claude Code itself.
agents_orchestrator_live() {
    local window_id="$1"

    tmux list-panes -t "$window_id" \
        -F '#{@shipyard_main_pane}|#{pane_current_command}' 2>/dev/null |
        grep -Fxq '1|claude'
}
