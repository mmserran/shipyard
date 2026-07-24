#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d)"
test_socket="shipyard-tests-$$"

cleanup() {
    command tmux -L "$test_socket" kill-server 2>/dev/null || true
    rm -rf "$test_tmp"
}
trap cleanup EXIT

export XDG_STATE_HOME="$test_tmp/state"
export TMUX="test"
export SHIPYARD_HOME="$repo_root"

# shellcheck source=../lib/context.sh
source "$repo_root/lib/context.sh"
# shellcheck source=../lib/pipeline.sh
source "$repo_root/lib/pipeline.sh"
# shellcheck source=../lib/session.sh
source "$repo_root/lib/session.sh"
# shellcheck source=../lib/watcher.sh
source "$repo_root/lib/watcher.sh"

tmux() {
    if [[ "$1" == "run-shell" || "$1" == "switch-client" ]]; then
        return 0
    fi
    command tmux -L "$test_socket" "$@"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'not ok - %s\nexpected: %s\nactual:   %s\n' \
            "$label" "$expected" "$actual" >&2
        return 1
    fi
    printf 'ok - %s\n' "$label"
}

tmux new-session -d -s testrepo -n intent -c "$repo_root"
window_id="$(tmux display-message -p '#{window_id}')"
pane_id="$(tmux display-message -p '#{pane_id}')"

assert_equal "💡" "$(pipeline_badge_for planning)" "planning uses lightbulb"
assert_equal "●" "$(pipeline_badge_for building)" "building uses dot"
assert_equal "✓✓" "$(pipeline_badge_for merged)" "merged uses two checks"

pipeline_set building >/dev/null
assert_equal "building" \
    "$(tmux show-options -wqv @pipeline_state)" \
    "forge build records building"

watcher_apply_state "$window_id" published "https://example.test/pull/1"
assert_equal "published" \
    "$(tmux show-options -wqv @pipeline_state)" \
    "watcher records published PR"
assert_equal "https://example.test/pull/1" \
    "$(tmux show-options -wqv @shipyard_pr)" \
    "watcher records PR URL"

shipyard_refresh_window_context "$window_id"
expected_branch="$(git -C "$repo_root" branch --show-current)"
expected_branch="${expected_branch:-detached}"
assert_equal "$(basename "$repo_root")  $expected_branch" \
    "$(tmux show-options -pqv -t "$pane_id" @shipyard_context)" \
    "pane context contains repository and branch"

returned_lease=""
treehouse() {
    case "$1" in
        get)
            printf '{"path":"%s","lease_id":"lease-new"}\n' "$repo_root"
            ;;
        return)
            returned_lease="$2|$4"
            ;;
    esac
}

shipyard_record_lease "$window_id" "/tmp/test-worktree" "lease-123" "holder"
tmux kill-window -t "$window_id"
shipyard_reap "$window_id"
assert_equal "/tmp/test-worktree|lease-123" \
    "$returned_lease" \
    "closed window returns exact lease"

TMUX="test" shipyard_new "intent workflow"
intent_window="$(tmux list-windows -a -F '#{window_name} #{window_id}' |
    sed -n 's/^intent workflow //p')"
assert_equal "intent workflow" \
    "$(tmux display-message -p -t "$intent_window" '#{window_name}')" \
    "forge new preserves the intent as the window title"
assert_equal "💡" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_badge)" \
    "forge new starts in planning"
assert_equal "bash" \
    "$(tmux display-message -p -t "$intent_window" '#{pane_current_command}')" \
    "forge new starts a shell rather than an agent"

watch_iterations=0
watcher_window_exists() {
    ((watch_iterations++ == 0))
}
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "complete"\n'
    printf '  pr: "https://example.test/pull/2"\n'
}
git() {
    if [[ "$1" == "-C" && "$3" == "branch" && "$4" == "--show-current" ]]; then
        printf 'feat/intent-workflow\n'
    else
        command git "$@"
    fi
}
gh() {
    printf 'MERGED\n'
}
sleep() {
    :
}
watcher_run "$intent_window" "$repo_root"
assert_equal "merged" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher observes a merged GitHub PR"

printf 'all tests passed\n'
