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
    if [[ "$1" == "run-shell" ]]; then
        watcher_launch="$3"
        return 0
    fi
    if [[ "$1" == "switch-client" ]]; then
        return 0
    fi
    if [[ "${fail_new_window:-0}" -eq 1 && "$1" == "new-window" ]]; then
        return 1
    fi
    if [[ "$1" == "split-window" ]]; then
        printf '%s\n' "$*" > "$test_tmp/split-window"
        printf '%%attach-test\n'
        return 0
    fi
    if [[ "$1" == "set-option" && "$*" == *"@shipyard_attach_pane"* ]]; then
        attach_pane_tag="$*"
        return 0
    fi
    if [[ "$1" == "list-panes" && -n "${attach_pane_list:-}" ]]; then
        printf '%s\n' "$attach_pane_list"
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
tmux set-option -t testrepo @shipyard_project_root "$repo_root"
window_id="$(tmux display-message -p '#{window_id}')"
pane_id="$(tmux display-message -p '#{pane_id}')"

assert_equal "💡" "$(pipeline_badge_for planning)" "planning uses lightbulb"
assert_equal "●" "$(pipeline_badge_for building)" "building uses dot"
assert_equal "✓✓" "$(pipeline_badge_for merged)" "merged uses two checks"

pipeline_set building >/dev/null
assert_equal "building" \
    "$(tmux show-options -wqv @pipeline_state)" \
    "forge build records building"
watcher_apply_state "$window_id" planning

scratch_repo="$test_tmp/scratch-repo"
git init -q "$scratch_repo"
git -C "$scratch_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
scratch_head="$(git -C "$scratch_repo" rev-parse HEAD)"
tmux set-option -w -t "$window_id" @shipyard_base_head "$scratch_head"

if watcher_worktree_building "$window_id" "$scratch_repo"; then
    printf 'not ok - clean worktree at base head is not building\n' >&2
    exit 1
fi
printf 'ok - clean worktree at base head is not building\n'

: > "$scratch_repo/untracked.txt"
if watcher_should_build "$window_id" "$scratch_repo"; then
    printf 'ok - dirty worktree is building\n'
else
    printf 'not ok - dirty worktree is building\n' >&2
    exit 1
fi
watcher_apply_state "$window_id" building
rm -f "$scratch_repo/untracked.txt"

if watcher_should_build "$window_id" "$scratch_repo"; then
    printf 'ok - building remains sticky after worktree becomes clean\n'
else
    printf 'not ok - building remains sticky after worktree becomes clean\n' >&2
    exit 1
fi

watcher_apply_state "$window_id" planning
git -C "$scratch_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m second
if watcher_should_build "$window_id" "$scratch_repo"; then
    printf 'ok - HEAD past base head is building\n'
else
    printf 'not ok - HEAD past base head is building\n' >&2
    exit 1
fi

watcher_apply_state "$window_id" published "https://example.test/pull/1"
assert_equal "published" \
    "$(tmux show-options -wqv @pipeline_state)" \
    "watcher records published PR"
assert_equal "https://example.test/pull/1" \
    "$(tmux show-options -wqv @shipyard_pr)" \
    "watcher records PR URL"

: > "$test_tmp/split-window"
attach_pane_tag=""
watcher_ensure_attach_pane "$window_id" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-h"*"-P"*"-F #{pane_id}"*"-t $window_id"*"$repo_root"*"no-mistakes attach")
        printf 'ok - opens a side-by-side pane running no-mistakes attach\n'
        ;;
    *)
        printf 'not ok - opens a side-by-side pane running no-mistakes attach\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac
assert_equal "set-option -p -t %attach-test @shipyard_attach_pane 1" \
    "$attach_pane_tag" \
    "tags the watcher-created attach pane"

: > "$test_tmp/split-window"
attach_pane_list=" no-mistakes"
watcher_ensure_attach_pane "$window_id" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"no-mistakes attach")
        printf 'ok - ignores an untagged no-mistakes pane\n'
        ;;
    *)
        printf 'not ok - ignores an untagged no-mistakes pane\n' >&2
        exit 1
        ;;
esac

: > "$test_tmp/split-window"
attach_pane_list="1 no-mistakes"
watcher_ensure_attach_pane "$window_id" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
assert_equal "" "$split_window_launch" \
    "does not reopen the attach pane while one is already live"
unset attach_pane_list

shipyard_refresh_window_context "$window_id"
expected_branch="$(git -C "$repo_root" branch --show-current)"
expected_branch="${expected_branch:-detached}"
assert_equal "$(basename "$repo_root")  $expected_branch" \
    "$(tmux show-options -pqv -t "$pane_id" @shipyard_context)" \
    "pane context contains repository and branch"

sync_origin="$test_tmp/sync-origin"
git init -q --bare "$sync_origin"

sync_source="$test_tmp/sync-source"
git init -q "$sync_source"
git -C "$sync_source" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m old
git -C "$sync_source" branch -M trunk
git -C "$sync_source" remote add origin "$sync_origin"
git -C "$sync_source" push -q origin trunk
git -C "$sync_origin" symbolic-ref HEAD refs/heads/trunk

sync_worktree="$test_tmp/sync-worktree"
git clone -q "$sync_origin" "$sync_worktree"
git -C "$sync_worktree" checkout -q --detach trunk

detected_branch="$(shipyard_default_branch "$sync_worktree")"
assert_equal "trunk" "$detected_branch" \
    "default branch is resolved from the remote, not a cached symref"

git -C "$sync_source" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m new
git -C "$sync_source" push -q origin trunk
fresh_head="$(git -C "$sync_source" rev-parse HEAD)"

shipyard_sync_worktree "$sync_worktree" "$detected_branch"
assert_equal "$fresh_head" "$(git -C "$sync_worktree" rev-parse HEAD)" \
    "sync fast-forwards a stale worktree to the remote's tip"
if git -C "$sync_worktree" symbolic-ref -q HEAD >/dev/null; then
    printf 'not ok - synced worktree stays detached\n' >&2
    exit 1
fi
printf 'ok - synced worktree stays detached\n'

returned_lease=""
treehouse() {
    case "$1" in
        get)
            if [[ "${5:-}" == *"setup failure"* ]]; then
                printf '{"path":"%s","lease_id":"lease-failure"}\n' "$repo_root"
            else
                printf '{"path":"%s","lease_id":"lease-new"}\n' "$repo_root"
            fi
            ;;
        return)
            returned_lease="$2|$4"
            ;;
    esac
}

# shipyard_new below leases $repo_root itself as a stand-in worktree so tmux
# assertions can inspect it; block the real sync's git mutations from running
# against this actual checkout by making its remote lookup fail closed.
git() {
    if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
        return 1
    fi
    command git "$@"
}

shipyard_record_lease "$window_id" "/tmp/test-worktree" "lease-123" "holder"
tmux kill-window -t "$window_id"
shipyard_reap "$window_id"
assert_equal "/tmp/test-worktree|lease-123" \
    "$returned_lease" \
    "closed window returns exact lease"

tmux new-session -d -s app -n existing
tmux set-option -t app @shipyard_project_root "/client/app"
collision_session="$(shipyard_session_for_project "/internal/app")"
case "$collision_session" in
    app-*)
        printf 'ok - same-basename repositories use distinct sessions\n'
        ;;
    *)
        printf 'not ok - same-basename repositories use distinct sessions\n' >&2
        exit 1
        ;;
esac

worktree_repo="$test_tmp/worktree-repo"
git init -q "$worktree_repo"
git -C "$worktree_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
linked_worktree="$test_tmp/worktree-repo-linked"
git -C "$worktree_repo" worktree add -q --detach "$linked_worktree"

assert_equal "$(shipyard_project_root "$worktree_repo")" \
    "$(shipyard_project_root "$linked_worktree")" \
    "a linked worktree resolves to the same project root as its main checkout"

tmux new-session -d -s worktree-repo -n main
tmux set-option -t worktree-repo @shipyard_project_root "$(shipyard_project_root "$worktree_repo")"
reused_session="$(shipyard_session_for_project "$(shipyard_project_root "$linked_worktree")")"
assert_equal "worktree-repo" "$reused_session" \
    "forge new from inside a linked worktree reuses the project's existing session"

bare_repo="$test_tmp/bare-repo.git"
git init -q --bare "$bare_repo"
git -C "$worktree_repo" remote add bare-test "$bare_repo"
git -C "$worktree_repo" push -q bare-test HEAD:main
bare_linked_worktree="$test_tmp/bare-repo-linked"
git -C "$bare_repo" worktree add -q --detach "$bare_linked_worktree" main

assert_equal "$(cd "$bare_repo" && pwd -P)" \
    "$(shipyard_project_root "$bare_linked_worktree")" \
    "a bare-backed linked worktree resolves to the bare repository"

quoted_command="$(shipyard_watcher_command "@9" "/tmp/it's a worktree")"
case "$quoted_command" in
    *"/tmp/it\\'s\\ a\\ worktree")
        printf 'ok - watcher command safely quotes shell metacharacters\n'
        ;;
    *)
        printf 'not ok - watcher command safely quotes shell metacharacters\n%s\n' \
            "$quoted_command" >&2
        exit 1
        ;;
esac

open_repo="$test_tmp/open-repo"
git init -q "$open_repo"
git -C "$open_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial

TMUX="test" shipyard_open "$open_repo"
open_session="$(shipyard_session_name "$(shipyard_project_root "$open_repo")")"
if ! tmux has-session -t "=$open_session" 2>/dev/null; then
    printf 'not ok - forge open creates the project session\n' >&2
    exit 1
fi
printf 'ok - forge open creates the project session\n'

open_window="$(shipyard_command_window "$open_session")"
assert_equal "command" \
    "$(tmux display-message -p -t "$open_window" '#{window_name}')" \
    "forge open names the window command"
assert_equal "command" \
    "$(tmux show-options -wqv -t "$open_window" @shipyard_role)" \
    "forge open tags the window with the command role"

TMUX="test" shipyard_open "$open_repo"
command_window_count="$(tmux list-windows -t "=$open_session" \
    -F '#{@shipyard_role}' | grep -Fxc 'command' || true)"
assert_equal "1" "$command_window_count" \
    "repeated forge open reuses the same command window"

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
intent_session="$(tmux display-message -p -t "$intent_window" '#{session_name}')"
assert_equal "$(shipyard_project_root "$repo_root")" \
    "$(tmux show-options -qv -t "$intent_session" @shipyard_project_root)" \
    "session records its canonical repository"
case "$watcher_launch" in
    *" watch "*)
        printf 'ok - watcher launch is shell quoted\n'
        ;;
    *)
        printf 'not ok - watcher launch is shell quoted\n%s\n' "$watcher_launch" >&2
        exit 1
        ;;
esac

returned_lease=""
fail_new_window=1
if TMUX="test" shipyard_new "setup failure"; then
    printf 'not ok - failed tmux setup returns its pending lease\n' >&2
    exit 1
fi
fail_new_window=0
assert_equal "$repo_root|lease-failure" \
    "$returned_lease" \
    "failed tmux setup returns its pending lease"

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

watch_iterations=0
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "running"\n'
}
: > "$test_tmp/split-window"
# watcher_run's lock only releases on process exit (an EXIT trap), which
# doesn't fire between calls made in the same test process; clear it by hand
# so this second call doesn't find the lock still held from the one above.
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
assert_equal "validating" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher marks an active run as validating"
case "$split_window_launch" in
    *"-h"*"no-mistakes attach")
        printf 'ok - watcher opens the attach pane for an active run\n'
        ;;
    *)
        printf 'not ok - watcher opens the attach pane for an active run\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac

printf 'all tests passed\n'
