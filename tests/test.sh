#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d)"
test_socket="shipyard-tests-$$"

mkdir -p "$test_tmp/bin"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$test_tmp/bin/yazi"
chmod +x "$test_tmp/bin/yazi"

cleanup() {
    command tmux -L "$test_socket" kill-server 2>/dev/null || true
    rm -rf "$test_tmp"
}
trap cleanup EXIT

export XDG_STATE_HOME="$test_tmp/state"
export TMUX="test"
export SHIPYARD_HOME="$repo_root"
export PATH="$test_tmp/bin:$PATH"

# shellcheck source=../lib/context.sh
source "$repo_root/lib/context.sh"
# shellcheck source=../lib/hooks.sh
source "$repo_root/lib/hooks.sh"
# shellcheck source=../lib/pipeline.sh
source "$repo_root/lib/pipeline.sh"
# shellcheck source=../lib/session.sh
source "$repo_root/lib/session.sh"
# shellcheck source=../lib/watcher.sh
source "$repo_root/lib/watcher.sh"
# shellcheck source=../lib/screenshot.sh
source "$repo_root/lib/screenshot.sh"
# shellcheck source=../shell/bash.sh
source "$repo_root/shell/bash.sh"
# shell/bash.sh shadows the exit builtin with a function; this script relies
# on real `exit N` for its own control flow (every failing assertion below
# calls it), so drop the override immediately and test its pieces by name
# instead of ever exercising exit() itself.
unset -f exit

tmux() {
    if [[ "$1" == "run-shell" ]]; then
        watcher_launch="${3:-}"
        if [[ "$watcher_launch" == tmux\ kill-session* ]]; then
            eval "$watcher_launch"
        fi
        return 0
    fi
    if [[ "$1" == "switch-client" ]]; then
        switch_client_target="${3:-}"
        return 0
    fi
    if [[ "${fail_new_window:-0}" -eq 1 && "$1" == "new-window" ]]; then
        return 1
    fi
    if [[ "${fail_new_session:-0}" -eq 1 && "$1" == "new-session" ]]; then
        return 1
    fi
    if [[ "$1" == "split-window" && "$*" == *" -h "* ]]; then
        printf '%s\n' "$*" > "$test_tmp/split-window"
        printf '%%attach-test\n'
        return 0
    fi
    if [[ "$1" == "set-option" && "$*" == *"@shipyard_attach_pane"* ]]; then
        attach_pane_tag="$*"
        return 0
    fi
    if [[ "$1" == "list-panes" && "$*" == *"@shipyard_attach_pane"* &&
        -n "${attach_pane_list:-}" ]]; then
        printf '%s\n' "$attach_pane_list"
        return 0
    fi
    if [[ "$1" == "list-panes" && "$*" == *"@shipyard_main_pane"* &&
        -n "${main_pane_list:-}" ]]; then
        printf '%s\n' "$main_pane_list"
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

# These run before any other shipyard session exists, so the "no shipyard
# windows open" case can be tested for real instead of having to fake an
# empty tmux list-sessions.
switch_client_target=""
no_windows_output="$(TMUX="test" shipyard_attach)"
assert_equal "No existing shipyard windows are open" "$no_windows_output" \
    "forge with no args reports when no shipyard windows are open"
assert_equal "" "$switch_client_target" \
    "forge with no args does not switch clients when nothing is open"

tmux new-session -d -s attach-command -n command -c "$test_tmp"
tmux set-option -t attach-command @shipyard_project_root "$test_tmp/attach-command"
attach_command_window="$(tmux display-message -p -t attach-command '#{window_id}')"
tmux set-option -w -t "$attach_command_window" @shipyard_role command

switch_client_target=""
TMUX="test" shipyard_attach
assert_equal "$attach_command_window" "$switch_client_target" \
    "forge with no args attaches to an existing shipyard command window"
tmux kill-session -t attach-command

tmux new-session -d -s attach-repo -n repo -c "$test_tmp"
tmux set-option -t attach-repo @shipyard_project_root "$test_tmp/attach-repo"
attach_repo_window="$(tmux display-message -p -t attach-repo '#{window_id}')"
tmux set-option -w -t "$attach_repo_window" @shipyard_role repo

switch_client_target=""
TMUX="test" shipyard_attach
assert_equal "$attach_repo_window" "$switch_client_target" \
    "forge with no args falls back to the Yazi repo window when no command window exists"
tmux kill-session -t attach-repo

switch_client_target=""
tmux new-session -d -s close-cmd-solo -n command -c "$test_tmp"
tmux set-option -t close-cmd-solo @shipyard_project_root "$test_tmp/close-cmd-solo"
solo_command_window="$(tmux display-message -p -t close-cmd-solo '#{window_id}')"
solo_command_pane="$(tmux display-message -p -t close-cmd-solo '#{pane_id}')"
tmux set-option -w -t "$solo_command_window" @shipyard_role command
solo_repo_window="$(tmux new-window -d -P -F '#{window_id}' -t close-cmd-solo -n close-cmd-solo -c "$test_tmp")"
tmux set-option -w -t "$solo_repo_window" @shipyard_role repo

TMUX_PANE="$solo_command_pane" shipyard_close
assert_equal "" "$switch_client_target" \
    "closing a command window with no other shipyard repo open does not switch clients"
if tmux has-session -t "=close-cmd-solo" 2>/dev/null; then
    printf 'not ok - closing a command window closes its repository session\n' >&2
    exit 1
fi
printf 'ok - closing a command window closes its repository session\n'

tmux new-session -d -s close-cmd-other -n command -c "$test_tmp"
tmux set-option -t close-cmd-other @shipyard_project_root "$test_tmp/close-cmd-other"
other_command_window="$(tmux display-message -p -t close-cmd-other '#{window_id}')"
tmux set-option -w -t "$other_command_window" @shipyard_role command
other_repo_window="$(tmux new-window -d -P -F '#{window_id}' -t close-cmd-other -n close-cmd-other -c "$test_tmp")"
tmux set-option -w -t "$other_repo_window" @shipyard_role repo

tmux new-session -d -s close-cmd-mine -n command -c "$test_tmp"
tmux set-option -t close-cmd-mine @shipyard_project_root "$test_tmp/close-cmd-mine"
mine_command_window="$(tmux display-message -p -t close-cmd-mine '#{window_id}')"
mine_command_pane="$(tmux display-message -p -t close-cmd-mine '#{pane_id}')"
tmux set-option -w -t "$mine_command_window" @shipyard_role command
mine_repo_window="$(tmux new-window -d -P -F '#{window_id}' -t close-cmd-mine -n close-cmd-mine -c "$test_tmp")"
tmux set-option -w -t "$mine_repo_window" @shipyard_role repo

switch_client_target=""
TMUX_PANE="$mine_command_pane" shipyard_close
assert_equal "$other_repo_window" "$switch_client_target" \
    "closing a command window with another Shipyard repo open switches to its Yazi window"
if tmux has-session -t "=close-cmd-mine" 2>/dev/null; then
    printf 'not ok - closing a command window removes its repo session\n' >&2
    exit 1
fi
printf 'ok - closing a command window removes its repo session\n'
if ! tmux has-session -t "=close-cmd-other" 2>/dev/null; then
    printf 'not ok - closing a command window leaves the other shipyard repo open\n' >&2
    exit 1
fi
printf 'ok - closing a command window leaves the other shipyard repo open\n'
tmux kill-session -t close-cmd-other 2>/dev/null || true

tmux new-session -d -s close-repo -n close-repo -c "$test_tmp"
tmux set-option -t close-repo @shipyard_project_root "$test_tmp/close-repo"
protected_repo_window="$(tmux display-message -p -t close-repo '#{window_id}')"
protected_repo_pane="$(tmux display-message -p -t close-repo '#{pane_id}')"
tmux set-option -w -t "$protected_repo_window" @shipyard_role repo
if TMUX_PANE="$protected_repo_pane" shipyard_close 2>/dev/null; then
    printf 'not ok - forge close refuses the Yazi repo window\n' >&2
    exit 1
fi
if ! tmux has-session -t "=close-repo" 2>/dev/null; then
    printf 'not ok - the protected Yazi repo window remains open\n' >&2
    exit 1
fi
printf 'ok - forge close refuses the Yazi repo window\n'
printf 'ok - the protected Yazi repo window remains open\n'
tmux kill-session -t close-repo

tmux new-session -d -s close-cmd-norole -n intent -c "$test_tmp"
norole_window="$(tmux display-message -p -t close-cmd-norole '#{window_id}')"
norole_pane="$(tmux display-message -p -t close-cmd-norole '#{pane_id}')"
if TMUX_PANE="$norole_pane" shipyard_close 2>/dev/null; then
    printf 'not ok - forge close still refuses an unleased, non-command window\n' >&2
    exit 1
fi
printf 'ok - forge close still refuses an unleased, non-command window\n'
tmux kill-session -t close-cmd-norole 2>/dev/null || true

tmux new-session -d -s intent-numbers -n repo -c "$test_tmp"
number_repo_window="$(tmux display-message -p -t intent-numbers '#{window_id}')"
tmux set-option -w -t "$number_repo_window" @shipyard_role repo
number_command_window="$(tmux new-window -d -P -F '#{window_id}' -t intent-numbers -n command -c "$test_tmp")"
tmux set-option -w -t "$number_command_window" @shipyard_role command
number_intent_one="$(tmux new-window -d -P -F '#{window_id}' -t intent-numbers -n one -c "$test_tmp")"
tmux set-option -w -t "$number_intent_one" @shipyard_worktree /tmp/one
number_intent_two="$(tmux new-window -d -P -F '#{window_id}' -t intent-numbers -n two -c "$test_tmp")"
tmux set-option -w -t "$number_intent_two" @shipyard_worktree /tmp/two
shipyard_refresh_intent_numbers intent-numbers
assert_equal "1" "$(tmux show-options -wqv -t "$number_intent_one" @shipyard_intent_number)" \
    "intent numbering ignores repo and command windows"
assert_equal "2" "$(tmux show-options -wqv -t "$number_intent_two" @shipyard_intent_number)" \
    "intent numbering increments in window order"
tmux kill-window -t "$number_intent_one"
shipyard_refresh_intent_numbers intent-numbers
assert_equal "1" "$(tmux show-options -wqv -t "$number_intent_two" @shipyard_intent_number)" \
    "remaining intent windows renumber from 1"
tmux kill-session -t intent-numbers

tmux new-session -d -s testrepo -n intent -c "$repo_root"
tmux set-option -t testrepo @shipyard_project_root "$repo_root"
window_id="$(tmux display-message -p '#{window_id}')"
pane_id="$(tmux display-message -p '#{pane_id}')"

assert_equal " 💡" "$(pipeline_badge_for planning)" "planning uses lightbulb"
assert_equal " ●" "$(pipeline_badge_for building)" "building uses dot"
assert_equal " 📝" "$(pipeline_badge_for validating)" "validating uses memo"
assert_equal " 🚢" "$(pipeline_badge_for merged)" "merged uses cargo ship"

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
scratch_branch="$(git -C "$scratch_repo" branch --show-current)"
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

watcher_apply_dirty "$window_id" "$scratch_repo"
assert_equal "1" "$(tmux show-options -wqv -t "$window_id" @shipyard_dirty)" \
    "dirty badge is set for an uncommitted worktree"

watcher_apply_state "$window_id" building
rm -f "$scratch_repo/untracked.txt"

watcher_apply_dirty "$window_id" "$scratch_repo"
assert_equal "" "$(tmux show-options -wqv -t "$window_id" @shipyard_dirty)" \
    "dirty badge clears once the worktree is clean again"

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

watcher_apply_state "$window_id" planning
tmux set-option -w -t "$window_id" @shipyard_base_branch "$scratch_branch"

: > "$scratch_repo/on-base-branch.txt"
if watcher_worktree_building "$window_id" "$scratch_repo"; then
    printf 'not ok - dirty tree on the base branch is not building\n' >&2
    exit 1
fi
printf 'ok - dirty tree on the base branch is not building\n'

git -C "$scratch_repo" checkout -q -b feature/test
if watcher_worktree_building "$window_id" "$scratch_repo"; then
    printf 'ok - dirty tree on a feature branch is building\n'
else
    printf 'not ok - dirty tree on a feature branch is building\n' >&2
    exit 1
fi
rm -f "$scratch_repo/on-base-branch.txt"

git -C "$scratch_repo" checkout -q --detach HEAD
: > "$scratch_repo/detached.txt"
if watcher_worktree_building "$window_id" "$scratch_repo"; then
    printf 'not ok - detached HEAD with dirty tree is not building\n' >&2
    exit 1
fi
printf 'ok - detached HEAD with dirty tree is not building\n'
rm -f "$scratch_repo/detached.txt"
tmux set-option -wu -t "$window_id" @shipyard_base_branch

watcher_apply_state "$window_id" published "https://example.test/pull/1"
assert_equal "published" \
    "$(tmux show-options -wqv @pipeline_state)" \
    "watcher records published PR"
assert_equal "https://example.test/pull/1" \
    "$(tmux show-options -wqv @shipyard_pr)" \
    "watcher records PR URL"

: > "$test_tmp/split-window"
attach_pane_tag=""
main_pane_list=$'%main-fallback||0|0\n%bottom||75|0'
watcher_ensure_attach_pane "$window_id" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-h"*"-p 33"*"-P"*"-F #{pane_id}"*"-t %main-fallback"*"$repo_root"*"no-mistakes attach")
        printf 'ok - opens a one-third-width attach pane beside the upper pane\n'
        ;;
    *)
        printf 'not ok - opens a one-third-width attach pane beside the upper pane\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac
assert_equal "set-option -p -t %attach-test @shipyard_attach_pane 1" \
    "$attach_pane_tag" \
    "tags the watcher-created attach pane"

: > "$test_tmp/split-window"
main_pane_list=$'%upper-left||0|0\n%tagged|1|0|80\n%bottom||75|0'
watcher_ensure_attach_pane "$window_id" "$repo_root"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-t %tagged"*)
        printf 'ok - prefers the tagged main pane over pane geometry\n'
        ;;
    *)
        printf 'not ok - prefers the tagged main pane over pane geometry\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac

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
unset attach_pane_list main_pane_list

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

env_project="$test_tmp/env-project"
git init -q "$env_project"
printf '.env*\n!.env.example\n' > "$env_project/.gitignore"
printf 'SECRET=1\n' > "$env_project/.env"
printf 'SECRET=2\n' > "$env_project/.env.local"
printf 'SECRET=example\n' > "$env_project/.env.example"
git -C "$env_project" add .gitignore .env.example
git -C "$env_project" -c user.email=test@example.com -c user.name=test \
    commit -q -m initial

env_worktree="$test_tmp/env-worktree"
mkdir -p "$env_worktree"
printf 'PRE_EXISTING=1\n' > "$env_worktree/.env.local"

shipyard_link_env_files "$env_project" "$env_worktree"

assert_equal "$env_project/.env" "$(readlink "$env_worktree/.env" 2>/dev/null)" \
    "shipyard_link_env_files symlinks a gitignored env file into the worktree"
assert_equal "PRE_EXISTING=1" "$(cat "$env_worktree/.env.local")" \
    "shipyard_link_env_files never clobbers a file already present in the worktree"
if [[ -e "$env_worktree/.env.example" || -L "$env_worktree/.env.example" ]]; then
    printf 'not ok - shipyard_link_env_files leaves tracked templates untouched\n' >&2
    exit 1
fi
printf 'ok - shipyard_link_env_files leaves tracked templates untouched\n'

env_worktree_empty="$test_tmp/env-worktree-empty"
mkdir -p "$env_worktree_empty"
env_project_empty="$test_tmp/env-project-empty"
git init -q "$env_project_empty"
shipyard_link_env_files "$env_project_empty" "$env_worktree_empty"
assert_equal "0" "$(find "$env_worktree_empty" -mindepth 1 | wc -l | tr -d ' ')" \
    "shipyard_link_env_files is a silent no-op when the project has no env files"

# Under forge's errexit, a failed ln must not abort the caller — otherwise
# shipyard_new can exit after treehouse get --lease and before
# shipyard_record_lease, orphaning the lease with no pending window.
env_worktree_ro="$test_tmp/env-worktree-ro"
mkdir -p "$env_worktree_ro"
chmod a-w "$env_worktree_ro"
link_warn="$(shipyard_link_env_files "$env_project" "$env_worktree_ro" 2>&1)" || {
    chmod u+w "$env_worktree_ro" 2>/dev/null || true
    printf 'not ok - shipyard_link_env_files must not fail when ln cannot create a symlink\n' >&2
    exit 1
}
chmod u+w "$env_worktree_ro"
if [[ "$link_warn" != *"could not link"* ]]; then
    printf 'not ok - shipyard_link_env_files warns when a symlink fails\n' >&2
    exit 1
fi
printf 'ok - shipyard_link_env_files stays best-effort when ln fails under errexit\n'

# A file rather than a variable: shipyard_reap now captures `treehouse
# return`'s output via $(...), which runs this mock in a subshell, so a
# plain variable assignment here wouldn't survive back to the assertions.
returned_lease_file="$test_tmp/returned-lease"
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
            printf '%s|%s' "$2" "$4" > "$returned_lease_file"
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

rm -f "$returned_lease_file"
shipyard_record_lease "$window_id" "/tmp/test-worktree" "lease-123" "holder"
tmux kill-window -t "$window_id"
shipyard_reap "$window_id"
assert_equal "/tmp/test-worktree|lease-123" \
    "$(cat "$returned_lease_file" 2>/dev/null)" \
    "closed window returns exact lease"

# `treehouse return` without --force exits 0 even when it declines (dirty
# worktree, no TTY to answer "Clean and return?"), printing Aborted. reap
# must not mistake that for success and delete the lease's only record.
treehouse() {
    case "$1" in
        return)
            printf 'Worktree has uncommitted changes. Clean and return? [Y/n] '
            printf '\xf0\x9f\x8c\xb3 Aborted.\n'
            ;;
    esac
}
shipyard_record_lease "@aborted-test" "/tmp/aborted-worktree" "lease-aborted" "holder"
shipyard_record_intent "lease-aborted" "/projects/app" "app" "aborted intent" \
    "/tmp/aborted-worktree" "holder" "abc" "development"
if shipyard_reap "@aborted-test"; then
    printf 'not ok - reap does not report success when treehouse return is declined\n' >&2
    exit 1
fi
printf 'ok - reap does not report success when treehouse return is declined\n'
if [[ -e "$(shipyard_state_home)/windows/lease-aborted.lease" ]]; then
    printf 'ok - reap keeps the lease record when the return is declined\n'
else
    printf 'not ok - reap keeps the lease record when the return is declined\n' >&2
    exit 1
fi
if [[ -e "$(shipyard_intent_file lease-aborted)" ]]; then
    printf 'not ok - reap clears the intent after a declined reclaim so reconcile can retry\n' >&2
    exit 1
fi
printf 'ok - reap clears the intent after a declined reclaim so reconcile can retry\n'
rm -f "$(shipyard_state_home)/windows/lease-aborted.lease"

# If the lease was already returned by some other path (e.g. a manual
# `treehouse return --force` run to work around a dirty worktree), a later
# `treehouse return --if-lease-id` fails its precondition with a nonzero
# exit and "is not leased" -- reap must treat that as done rather than
# leaving an orphaned record no future reconcile can ever clear.
treehouse() {
    case "$1" in
        return)
            printf 'failed to return worktree: lease precondition failed: worktree %s is not leased\n' "$2" >&2
            return 1
            ;;
    esac
}
shipyard_record_lease "@already-returned-test" "/tmp/already-returned-worktree" "lease-already-returned" "holder"
shipyard_reap "@already-returned-test"
printf 'ok - reap reports success when treehouse says the lease is already returned\n'
if [[ -e "$(shipyard_state_home)/windows/lease-already-returned.lease" ]]; then
    printf 'not ok - reap clears the lease record once treehouse confirms it is already returned\n' >&2
    exit 1
else
    printf 'ok - reap clears the lease record once treehouse confirms it is already returned\n'
fi
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
            printf '%s|%s' "$2" "$4" > "$returned_lease_file"
            ;;
    esac
}

exit_worktree="$test_tmp/exit-guard-worktree"
git init -q "$exit_worktree"
git -C "$exit_worktree" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial

tmux new-session -d -s exit-guard -n intent -c "$exit_worktree"
exit_window="$(tmux display-message -p -t exit-guard '#{window_id}')"
exit_pane="$(tmux display-message -p -t exit-guard '#{pane_id}')"

if TMUX_PANE="$exit_pane" shipyard_exit_worktree_info >/dev/null 2>&1; then
    printf 'not ok - exit guard is a no-op for a window with no lease\n' >&2
    exit 1
fi
printf 'ok - exit guard is a no-op for a window with no lease\n'

tmux set-option -w -t "$exit_window" @shipyard_lease_id "lease-exit-guard"
tmux set-option -w -t "$exit_window" @shipyard_worktree "$exit_worktree"

printf -v exit_info_expected '%s\t%s\t%s' "$exit_window" "$exit_worktree" "lease-exit-guard"
assert_equal "$exit_info_expected" \
    "$(TMUX_PANE="$exit_pane" shipyard_exit_worktree_info)" \
    "exit guard identifies a leased window's worktree and lease"

tmux split-window -t "$exit_window" -c "$exit_worktree"
if TMUX_PANE="$exit_pane" shipyard_exit_worktree_info >/dev/null 2>&1; then
    printf 'not ok - exit guard is a no-op when more than one pane remains\n' >&2
    exit 1
fi
printf 'ok - exit guard is a no-op when more than one pane remains\n'
tmux kill-pane -a -t "$exit_pane"

rm -f "$returned_lease_file"
shipyard_record_lease "$exit_window" "$exit_worktree" "lease-exit-guard" "holder"
if shipyard_exit_should_proceed "$exit_window" "$exit_worktree" "lease-exit-guard"; then
    printf 'ok - exit guard proceeds immediately on a clean worktree\n'
else
    printf 'not ok - exit guard proceeds immediately on a clean worktree\n' >&2
    exit 1
fi
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'not ok - exit guard forgets the lease after returning a clean worktree\n' >&2
    exit 1
fi
printf 'ok - exit guard forgets the lease after returning a clean worktree\n'

treehouse() {
    case "$1" in
        return)
            printf 'lease mismatch\n' >&2
            return 1
            ;;
    esac
}
shipyard_record_lease "$exit_window" "$exit_worktree" "lease-exit-guard" "holder"
if shipyard_exit_should_proceed "$exit_window" "$exit_worktree" "lease-exit-guard" 2>/dev/null; then
    printf 'not ok - exit guard stops when a clean return fails\n' >&2
    exit 1
fi
printf 'ok - exit guard stops when a clean return fails\n'
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'ok - exit guard keeps the lease record after a clean return failure\n'
else
    printf 'not ok - exit guard keeps the lease record after a clean return failure\n' >&2
    exit 1
fi

: > "$exit_worktree/dirty.txt"
treehouse() {
    case "$1" in
        return)
            printf 'Worktree has uncommitted changes. Clean and return? [Y/n] '
            printf '\xf0\x9f\x8c\xb3 Aborted.\n'
            ;;
    esac
}
shipyard_record_lease "$exit_window" "$exit_worktree" "lease-exit-guard" "holder"
if shipyard_exit_should_proceed "$exit_window" "$exit_worktree" "lease-exit-guard" 2>/dev/null; then
    printf 'not ok - exit guard does not proceed when a dirty return is declined\n' >&2
    exit 1
fi
printf 'ok - exit guard does not proceed when a dirty return is declined\n'
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'ok - exit guard keeps the lease record when declined\n'
else
    printf 'not ok - exit guard keeps the lease record when declined\n' >&2
    exit 1
fi

treehouse() {
    case "$1" in
        return)
            printf 'lease mismatch\n' >&2
            return 1
            ;;
    esac
}
if shipyard_exit_should_proceed "$exit_window" "$exit_worktree" "lease-exit-guard" 2>/dev/null; then
    printf 'not ok - exit guard stops when a dirty return fails\n' >&2
    exit 1
fi
printf 'ok - exit guard stops when a dirty return fails\n'
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'ok - exit guard keeps the lease record after a dirty return failure\n'
else
    printf 'not ok - exit guard keeps the lease record after a dirty return failure\n' >&2
    exit 1
fi

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
            printf '%s|%s' "$2" "$4" > "$returned_lease_file"
            ;;
    esac
}
if shipyard_exit_should_proceed "$exit_window" "$exit_worktree" "lease-exit-guard"; then
    printf 'ok - exit guard proceeds once a dirty return succeeds\n'
else
    printf 'not ok - exit guard proceeds once a dirty return succeeds\n' >&2
    exit 1
fi
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'not ok - exit guard forgets the lease after a dirty return succeeds\n' >&2
    exit 1
fi
printf 'ok - exit guard forgets the lease after a dirty return succeeds\n'

# exit() is a function, so it also runs inside subshells/command
# substitutions -- $(exit) only ends the subshell, but treehouse return and
# rm aren't subshell-scoped, so without the BASHPID guard this would really
# return and forget the lease while the top-level shell (and window) is
# still attached to that worktree.
shipyard_record_lease "$exit_window" "$exit_worktree" "lease-exit-guard" "holder"
source "$repo_root/shell/bash.sh"
(TMUX_PANE="$exit_pane" exit 0) 2>/dev/null || true
unset -f exit
if [[ -e "$(shipyard_state_home)/windows/lease-exit-guard.lease" ]]; then
    printf 'ok - exit guard does not act from inside a subshell\n'
else
    printf 'not ok - exit guard does not act from inside a subshell\n' >&2
    exit 1
fi
rm -f "$(shipyard_state_home)/windows/lease-exit-guard.lease"

# kill-window on a session's last window already tears down the session.
tmux kill-window -t "$exit_window" 2>/dev/null || true

if TMUX_PANE="" shipyard_close 2>/dev/null; then
    printf 'not ok - forge close requires a tmux window\n' >&2
    exit 1
fi
printf 'ok - forge close requires a tmux window\n'

tmux new-session -d -s close-test -n intent -c "$exit_worktree"
close_window="$(tmux display-message -p -t close-test '#{window_id}')"
close_pane="$(tmux display-message -p -t close-test '#{pane_id}')"

if TMUX_PANE="$close_pane" shipyard_close 2>/dev/null; then
    printf 'not ok - forge close requires a leased window\n' >&2
    exit 1
fi
printf 'ok - forge close requires a leased window\n'

no_mistakes_active=0
no_mistakes_aborted_file="$test_tmp/no-mistakes-aborted"
rm -f "$no_mistakes_aborted_file"
no-mistakes() {
    case "$1" in
        axi)
            case "${2:-}" in
                status)
                    if [[ "$no_mistakes_active" -eq 1 ]]; then
                        printf 'run:\n  status: running\n'
                    else
                        printf 'run:\n  status: completed\noutcome: passed\n'
                    fi
                    ;;
                abort)
                    : > "$no_mistakes_aborted_file"
                    ;;
            esac
            ;;
    esac
}

tmux set-option -w -t "$close_window" @shipyard_worktree "$exit_worktree"
tmux set-option -w -t "$close_window" @shipyard_lease_id "lease-close-test"
rm -f "$returned_lease_file"
shipyard_record_lease "$close_window" "$exit_worktree" "lease-close-test" "holder"
shipyard_record_lease "%unrelated" "$exit_worktree" "zz-unrelated" "holder"

export test_socket test_tmp returned_lease_file no_mistakes_active no_mistakes_aborted_file
export -f tmux treehouse no-mistakes shipyard_close shipyard_close_intent_window \
    shipyard_refresh_intent_numbers shipyard_forget_lease shipyard_forget_intent \
    shipyard_intent_file shipyard_state_home
if TMUX_PANE="$close_pane" bash -e -c 'shipyard_close' 2>/dev/null; then
    printf 'ok - forge close returns the lease and closes a clean window\n'
else
    printf 'not ok - forge close returns the lease and closes a clean window\n' >&2
    exit 1
fi
assert_equal "$exit_worktree|lease-close-test" "$(cat "$returned_lease_file" 2>/dev/null)" \
    "forge close force-returns the lease"
if tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fxq "$close_window"; then
    printf 'not ok - forge close actually closes the window\n' >&2
    exit 1
fi
printf 'ok - forge close actually closes the window\n'
if [[ -e "$(shipyard_state_home)/windows/lease-close-test.lease" ]]; then
    printf 'not ok - forge close forgets the lease record\n' >&2
    exit 1
fi
printf 'ok - forge close forgets the lease record\n'
if [[ ! -e "$(shipyard_state_home)/windows/zz-unrelated.lease" ]]; then
    printf 'not ok - forge close preserves unrelated lease records\n' >&2
    exit 1
fi
printf 'ok - forge close preserves unrelated lease records under errexit\n'
rm -f "$(shipyard_state_home)/windows/zz-unrelated.lease"
if [[ -e "$no_mistakes_aborted_file" ]]; then
    printf 'not ok - forge close does not abort a no-mistakes run that already reached an outcome\n' >&2
    exit 1
fi
printf 'ok - forge close does not abort a no-mistakes run that already reached an outcome\n'

tmux new-session -d -s close-test -n intent -c "$exit_worktree"
close_window="$(tmux display-message -p -t close-test '#{window_id}')"
close_pane="$(tmux display-message -p -t close-test '#{pane_id}')"
tmux set-option -w -t "$close_window" @shipyard_worktree "$exit_worktree"
tmux set-option -w -t "$close_window" @shipyard_lease_id "lease-close-test"
shipyard_record_lease "$close_window" "$exit_worktree" "lease-close-test" "holder"
: > "$exit_worktree/dirty-close.txt"
no_mistakes_active=1
rm -f "$no_mistakes_aborted_file"

close_stderr="$(TMUX_PANE="$close_pane" shipyard_close 2>&1 1>/dev/null)"
case "$close_stderr" in
    *"aborting the active no-mistakes run"*"discarding uncommitted changes"*)
        printf 'ok - forge close warns and aborts an active run before closing a dirty window\n'
        ;;
    *)
        printf 'not ok - forge close warns and aborts an active run before closing a dirty window\n%s\n' \
            "$close_stderr" >&2
        exit 1
        ;;
esac
if [[ -e "$no_mistakes_aborted_file" ]]; then
    printf 'ok - forge close aborts a genuinely active no-mistakes run\n'
else
    printf 'not ok - forge close aborts a genuinely active no-mistakes run\n' >&2
    exit 1
fi
no_mistakes_active=0
rm -f "$exit_worktree/dirty-close.txt"

tmux new-session -d -s close-test -n intent -c "$exit_worktree"
close_window="$(tmux display-message -p -t close-test '#{window_id}')"
close_pane="$(tmux display-message -p -t close-test '#{pane_id}')"
tmux set-option -w -t "$close_window" @shipyard_worktree "$exit_worktree"
tmux set-option -w -t "$close_window" @shipyard_lease_id "lease-close-test"
shipyard_record_lease "$close_window" "$exit_worktree" "lease-close-test" "holder"
treehouse() {
    case "$1" in
        get)
            printf '{"path":"%s","lease_id":"lease-new"}\n' "$repo_root"
            ;;
        return)
            printf 'lease id mismatch\n' >&2
            return 1
            ;;
    esac
}
if TMUX_PANE="$close_pane" shipyard_close 2>/dev/null; then
    printf 'not ok - forge close does not close the window when the return fails\n' >&2
    exit 1
fi
printf 'ok - forge close does not close the window when the return fails\n'
if tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -Fxq "$close_window"; then
    printf 'ok - window survives a failed force-return\n'
else
    printf 'not ok - window survives a failed force-return\n' >&2
    exit 1
fi
tmux kill-window -t "$close_window" 2>/dev/null || true

tmux new-session -d -s close-all-failure -n command -c "$repo_root"
tmux set-option -t close-all-failure @shipyard_project_root "$repo_root"
failed_command_window="$(tmux display-message -p -t close-all-failure '#{window_id}')"
failed_command_pane="$(tmux display-message -p -t close-all-failure '#{pane_id}')"
tmux set-option -w -t "$failed_command_window" @shipyard_role command
failed_repo_window="$(tmux new-window -d -P -F '#{window_id}' -t close-all-failure -n repo -c "$repo_root")"
tmux set-option -w -t "$failed_repo_window" @shipyard_role repo
failed_intent_window="$(tmux new-window -d -P -F '#{window_id}' -t close-all-failure -n intent -c "$repo_root")"
tmux set-option -w -t "$failed_intent_window" @shipyard_worktree "$repo_root"
tmux set-option -w -t "$failed_intent_window" @shipyard_lease_id lease-close-all-failure
shipyard_record_lease "$failed_intent_window" "$repo_root" lease-close-all-failure holder
if TMUX_PANE="$failed_command_pane" shipyard_close 2>/dev/null; then
    printf 'not ok - command close fails when an intent lease cannot be returned\n' >&2
    exit 1
fi
if ! tmux has-session -t "=close-all-failure" 2>/dev/null; then
    printf 'not ok - failed command close preserves the repository session\n' >&2
    exit 1
fi
printf 'ok - failed command close preserves the repository session\n'
tmux kill-session -t close-all-failure
rm -f "$(shipyard_state_home)/windows/lease-close-all-failure.lease"
unset -f no-mistakes
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
            printf '%s|%s' "$2" "$4" > "$returned_lease_file"
            ;;
    esac
}

tmux new-session -d -s close-all-success -n command -c "$repo_root"
tmux set-option -t close-all-success @shipyard_project_root "$repo_root"
close_all_command_window="$(tmux display-message -p -t close-all-success '#{window_id}')"
close_all_command_pane="$(tmux display-message -p -t close-all-success '#{pane_id}')"
tmux set-option -w -t "$close_all_command_window" @shipyard_role command
close_all_repo_window="$(tmux new-window -d -P -F '#{window_id}' -t close-all-success -n repo -c "$repo_root")"
tmux set-option -w -t "$close_all_repo_window" @shipyard_role repo
for close_all_number in 1 2; do
    close_all_intent_window="$(tmux new-window -d -P -F '#{window_id}' \
        -t close-all-success -n "intent-$close_all_number" -c "$repo_root")"
    tmux set-option -w -t "$close_all_intent_window" @shipyard_worktree "$repo_root"
    tmux set-option -w -t "$close_all_intent_window" @shipyard_lease_id "lease-close-all-$close_all_number"
    shipyard_record_lease "$close_all_intent_window" "$repo_root" \
        "lease-close-all-$close_all_number" holder
done
TMUX_PANE="$close_all_command_pane" shipyard_close
if tmux has-session -t "=close-all-success" 2>/dev/null; then
    printf 'not ok - command close removes repo, command, and intent windows\n' >&2
    exit 1
fi
printf 'ok - command close removes repo, command, and intent windows\n'
if [[ -e "$(shipyard_state_home)/windows/lease-close-all-1.lease" ||
    -e "$(shipyard_state_home)/windows/lease-close-all-2.lease" ]]; then
    printf 'not ok - command close forgets every returned intent lease\n' >&2
    exit 1
fi
printf 'ok - command close forgets every returned intent lease\n'

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

repo_window="$(shipyard_repo_window "$open_session")"
assert_equal "$open_session" \
    "$(tmux display-message -p -t "$repo_window" '#{window_name}')" \
    "forge open names the Yazi window after the repository session"
assert_equal "repo" \
    "$(tmux show-options -wqv -t "$repo_window" @shipyard_role)" \
    "forge open tags the Yazi window with the repo role"
assert_equal "yazi" \
    "$(tmux display-message -p -t "$repo_window" '#{pane_start_command}')" \
    "forge open starts Yazi in the repo window"

open_window="$(shipyard_command_window "$open_session")"
assert_equal "command" \
    "$(tmux display-message -p -t "$open_window" '#{window_name}')" \
    "forge open names the window command"
assert_equal "command" \
    "$(tmux show-options -wqv -t "$open_window" @shipyard_role)" \
    "forge open tags the window with the command role"
assert_equal "open-repo  $(git -C "$open_repo" branch --show-current)" \
    "$(tmux show-options -pqv -t "$open_window" @shipyard_context)" \
    "forge open initializes the command pane repository and branch context"
assert_equal "$open_window" "$switch_client_target" \
    "forge open switches to the command window"

TMUX="test" shipyard_open "$open_repo"
command_window_count="$(tmux list-windows -t "=$open_session" \
    -F '#{@shipyard_role}' | grep -Fxc 'command' || true)"
assert_equal "1" "$command_window_count" \
    "repeated forge open reuses the same command window"
repo_window_count="$(tmux list-windows -t "=$open_session" \
    -F '#{@shipyard_role}' | grep -Fxc 'repo' || true)"
assert_equal "1" "$repo_window_count" \
    "repeated forge open reuses the same Yazi repo window"

tmux kill-window -t "$repo_window"
TMUX="test" shipyard_open "$open_repo"
replacement_repo_window="$(shipyard_repo_window "$open_session")"
if [[ -z "$replacement_repo_window" || "$replacement_repo_window" == "$repo_window" ]]; then
    printf 'not ok - forge open recreates a manually closed Yazi repo window\n' >&2
    exit 1
fi
printf 'ok - forge open recreates a manually closed Yazi repo window\n'
assert_equal "$replacement_repo_window" \
    "$(tmux list-windows -t "=$open_session" -F '#{window_id}' | head -n 1)" \
    "forge open recreates the Yazi repo window at the leftmost index"

TMUX="test" shipyard_new "intent workflow"
intent_window="$(tmux list-windows -a -F '#{window_name} #{window_id}' |
    sed -n 's/^intent workflow //p')"
assert_equal "intent workflow" \
    "$(tmux display-message -p -t "$intent_window" '#{window_name}')" \
    "forge new preserves the intent as the window title"
assert_equal " 💡" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_badge)" \
    "forge new starts in planning"
assert_equal "1" \
    "$(tmux show-options -wqv -t "$intent_window" @shipyard_intent_number)" \
    "the first intent window is numbered 1"
assert_equal "bash" \
    "$(tmux display-message -p -t "$intent_window" '#{pane_current_command}')" \
    "forge new starts a shell rather than an agent"
assert_equal "2" \
    "$(tmux list-panes -t "$intent_window" | wc -l | tr -d ' ')" \
    "forge new opens a two-pane layout"
intent_main_pane="$(tmux list-panes -t "$intent_window" \
    -F '#{@shipyard_main_pane}|#{pane_id}' | sed -n 's/^1|//p')"
if [[ -z "$intent_main_pane" ]]; then
    printf 'not ok - forge new tags its main pane\n' >&2
    exit 1
fi
printf 'ok - forge new tags its main pane\n'
intent_bottom_pane="$(tmux list-panes -t "$intent_window" \
    -F '#{@shipyard_main_pane}|#{pane_id}' | sed -n 's/^|//p')"
tmux select-pane -t "$intent_bottom_pane"
assert_equal "$intent_main_pane" \
    "$(watcher_main_pane "$intent_window")" \
    "watcher resolves the main pane while the bottom pane is active"
intent_pane_heights="$(tmux list-panes -t "$intent_window" -F '#{pane_top} #{pane_height}' | sort -n)"
intent_top_height="$(awk 'NR==1{print $2}' <<<"$intent_pane_heights")"
intent_bottom_height="$(awk 'NR==2{print $2}' <<<"$intent_pane_heights")"
intent_bottom_pct=$(( intent_bottom_height * 100 / (intent_top_height + intent_bottom_height + 1) ))
if (( intent_bottom_pct >= 20 && intent_bottom_pct <= 30 )); then
    printf 'ok - bottom pane is about 25%% of the window height\n'
else
    printf 'not ok - bottom pane is about 25%% of the window height (got %s%%)\n' \
        "$intent_bottom_pct" >&2
    exit 1
fi
intent_session="$(tmux display-message -p -t "$intent_window" '#{session_name}')"
assert_equal "$(shipyard_project_root "$repo_root")" \
    "$(tmux show-options -qv -t "$intent_session" @shipyard_project_root)" \
    "session records its canonical repository"
intent_repo_window="$(shipyard_repo_window "$intent_session")"
assert_equal "repo" \
    "$(tmux show-options -wqv -t "$intent_repo_window" @shipyard_role)" \
    "forge new ensures the Yazi repo window exists"
assert_equal "$intent_repo_window" \
    "$(tmux list-windows -t "=$intent_session" -F '#{window_id}' | head -n 1)" \
    "forge new keeps the Yazi repo window leftmost"
case "$watcher_launch" in
    *" watch "*)
        printf 'ok - watcher launch is shell quoted\n'
        ;;
    *)
        printf 'not ok - watcher launch is shell quoted\n%s\n' "$watcher_launch" >&2
        exit 1
        ;;
esac

rm -f "$returned_lease_file"
fail_new_window=1
if TMUX="test" shipyard_new "setup failure"; then
    printf 'not ok - failed tmux setup returns its pending lease\n' >&2
    exit 1
fi
fail_new_window=0
assert_equal "$repo_root|lease-failure" \
    "$(cat "$returned_lease_file" 2>/dev/null)" \
    "failed tmux setup returns its pending lease"

# Multi-intent: commas split `forge new` input into one window per intent,
# each with its own Treehouse lease, and focus lands on the first created
# window. The counter lives in a file because `treehouse get` runs inside a
# $(...) subshell, so a variable increment would not survive back here.
multi_lease_counter="$test_tmp/multi-lease-counter"
: > "$multi_lease_counter"
treehouse() {
    case "$1" in
        get)
            if [[ "${5:-}" == *"lease denied"* ]]; then
                return 1
            fi
            printf 'x' >> "$multi_lease_counter"
            printf '{"path":"%s","lease_id":"lease-multi-%s"}\n' \
                "$repo_root" "$(wc -c < "$multi_lease_counter" | tr -d ' ')"
            ;;
        return)
            printf '%s|%s' "$2" "$4" > "$returned_lease_file"
            ;;
    esac
}

switch_client_target=""
TMUX="test" shipyard_new fix alpha task ,  fix beta task,fix gamma task
multi_alpha_window="$(tmux list-windows -a -F '#{window_name} #{window_id}' |
    sed -n 's/^fix alpha task //p')"
multi_beta_window="$(tmux list-windows -a -F '#{window_name} #{window_id}' |
    sed -n 's/^fix beta task //p')"
multi_gamma_window="$(tmux list-windows -a -F '#{window_name} #{window_id}' |
    sed -n 's/^fix gamma task //p')"
if [[ -z "$multi_alpha_window" || -z "$multi_beta_window" || -z "$multi_gamma_window" ]]; then
    printf 'not ok - comma-separated intents each open a trimmed-title window\n' >&2
    exit 1
fi
printf 'ok - comma-separated intents each open a trimmed-title window\n'
assert_equal "3" "$(wc -c < "$multi_lease_counter" | tr -d ' ')" \
    "each intent takes its own Treehouse lease"
assert_equal "lease-multi-1" \
    "$(tmux show-options -wqv -t "$multi_alpha_window" @shipyard_lease_id)" \
    "intents are created in the order they were listed"
assert_equal "lease-multi-3" \
    "$(tmux show-options -wqv -t "$multi_gamma_window" @shipyard_lease_id)" \
    "every intent window records its own lease id"
assert_equal "$multi_alpha_window" "$switch_client_target" \
    "multi-intent forge new focuses the first created window"

multi_window_count_before="$(tmux list-windows -a | wc -l | tr -d ' ')"
TMUX="test" shipyard_new solo comma intent , ,
multi_window_count_after="$(tmux list-windows -a | wc -l | tr -d ' ')"
assert_equal "$((multi_window_count_before + 1))" "$multi_window_count_after" \
    "empty comma segments are skipped"

multi_usage_status=0
multi_usage="$(TMUX="test" shipyard_new " , ," 2>&1)" || multi_usage_status=$?
assert_equal "2" "$multi_usage_status" \
    "an all-empty intent list fails like a missing intent"
case "$multi_usage" in
    *"usage: forge new"*)
        printf 'ok - an all-empty intent list prints usage\n'
        ;;
    *)
        printf 'not ok - an all-empty intent list prints usage\n%s\n' "$multi_usage" >&2
        exit 1
        ;;
esac

switch_client_target=""
if TMUX="test" shipyard_new first good intent, lease denied here, never created intent; then
    printf 'not ok - multi-intent stops at the first failing intent\n' >&2
    exit 1
fi
printf 'ok - multi-intent stops at the first failing intent\n'
if tmux list-windows -a -F '#{window_name}' | grep -Fxq 'never created intent'; then
    printf 'not ok - intents after a failure are not created\n' >&2
    exit 1
fi
printf 'ok - intents after a failure are not created\n'
if tmux list-windows -a -F '#{window_name}' | grep -Fxq 'first good intent'; then
    printf 'ok - windows created before a failure stay open\n'
else
    printf 'not ok - windows created before a failure stay open\n' >&2
    exit 1
fi
assert_equal "" "$switch_client_target" \
    "a failed multi-intent run does not attach"

# Drop the extra windows and their records so the later pause/restore tests
# only see the intents they stage themselves.
multi_extra_windows="$(tmux list-windows -a -F '#{window_name}|#{window_id}' |
    sed -n 's/^\(fix alpha task\|fix beta task\|fix gamma task\|solo comma intent\|first good intent\)|//p')"
for multi_window in $multi_extra_windows; do
    tmux kill-window -t "$multi_window" 2>/dev/null || true
done
rm -f "$(shipyard_state_home)/windows/lease-multi-"*.lease
rm -f "$(shipyard_state_home)/intents/lease-multi-"*.intent

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
autofix_calls_file="$test_tmp/autofix-calls"
rm -f "$autofix_calls_file"
screenshot_autofix_pr_body() {
    printf '%s %s\n' "$1" "$2" >> "$autofix_calls_file"
}
watcher_run "$intent_window" "$repo_root"
assert_equal "merged" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher observes a merged GitHub PR"
if [[ -e "$autofix_calls_file" ]]; then
    printf 'not ok - watcher skips screenshot autofix for a merged PR\n' >&2
    exit 1
fi
printf 'ok - watcher skips screenshot autofix for a merged PR\n'

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

# A running validation can coexist with a stale manual @pipeline_manual_state
# attention flag, an already-published PR, or both -- the attach pane must
# stay reachable in every case, even though the badge shown differs.
tmux set-option -w -t "$intent_window" @pipeline_manual_state attention
watch_iterations=0
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "running"\n'
}
: > "$test_tmp/split-window"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "attention" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "manual attention still wins the badge over an active run"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-h"*"no-mistakes attach")
        printf 'ok - watcher opens the attach pane for an active run under lingering manual attention\n'
        ;;
    *)
        printf 'not ok - watcher opens the attach pane for an active run under lingering manual attention\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac
tmux set-option -wu -t "$intent_window" @pipeline_manual_state

watch_iterations=0
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "running"\n'
    printf '  pr: "https://example.test/pull/2"\n'
}
gh() {
    printf 'OPEN\n'
}
: > "$test_tmp/split-window"
rm -f "$autofix_calls_file"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "published" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "an open PR still wins the badge over an active run"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-h"*"no-mistakes attach")
        printf 'ok - watcher opens the attach pane for an active run with an already-created PR\n'
        ;;
    *)
        printf 'not ok - watcher opens the attach pane for an active run with an already-created PR\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac

tmux set-option -w -t "$intent_window" @pipeline_manual_state attention
watch_iterations=0
: > "$test_tmp/split-window"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "attention" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "manual attention wins the badge over an active run with a PR"
split_window_launch="$(<"$test_tmp/split-window")"
case "$split_window_launch" in
    *"-h"*"no-mistakes attach")
        printf 'ok - watcher opens the attach pane for an active run under both lingering manual attention and an already-created PR\n'
        ;;
    *)
        printf 'not ok - watcher opens the attach pane for an active run under both lingering manual attention and an already-created PR\n%s\n' \
            "$split_window_launch" >&2
        exit 1
        ;;
esac
tmux set-option -wu -t "$intent_window" @pipeline_manual_state

watch_iterations=0
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "complete"\n'
    printf '  pr: "https://example.test/pull/3"\n'
}
gh() {
    printf 'OPEN\n'
}
rm -f "$autofix_calls_file"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "published" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher marks an open PR as published"
assert_equal "$repo_root https://example.test/pull/3" \
    "$(<"$autofix_calls_file")" \
    "watcher runs screenshot autofix against the worktree and PR for an open PR"

watch_iterations=0
gh() {
    printf 'CLOSED\n'
}
rm -f "$autofix_calls_file"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "attention" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher flags a closed PR for attention"
if [[ -e "$autofix_calls_file" ]]; then
    printf 'not ok - watcher skips screenshot autofix for a closed PR\n' >&2
    exit 1
fi
printf 'ok - watcher skips screenshot autofix for a closed PR\n'

# bin/forge runs under `set -o errexit`, and this whole test script does too
# (see the top of this file). Before watcher_poll was split out of
# watcher_run, an unguarded failure anywhere in one poll cycle (a transient
# gh/tmux/no-mistakes hiccup, or any bug not yet discovered) killed the
# entire background watcher process forever, with no log and no restart --
# freezing that window's pipeline badge and silently disabling
# screenshot_autofix_pr_body's PR-body backstop for the rest of the window's
# life. This is what actually broke PR screenshot embedding in practice: the
# autofix logic itself was fine, but the process running it had already died
# by the time a PR existed to fix.
#
# `watcher_poll ... || poll_status=$?` also means bash suspends errexit for
# watcher_poll's *entire* call -- a failure partway through no longer aborts
# the rest of that cycle either, it just proceeds like `set +e` for the
# duration of the call. So the case worth proving here is the strictest one:
# even the very last statement of a cycle failing (the one case that *does*
# still surface as watcher_poll's own exit status) costs only that cycle.
watch_iterations=0
watcher_window_exists() {
    ((watch_iterations++ < 2))
}
poll_attempts=0
watcher_apply_state() {
    poll_attempts=$((poll_attempts + 1))
    if [[ "$poll_attempts" -eq 1 ]]; then
        return 1
    fi
    tmux set-option -w -t "$1" @pipeline_state "$2"
}
watcher_no_mistakes_status() {
    printf '  branch: "feat/intent-workflow"\n'
    printf '  status: "complete"\n'
    printf '  pr: "https://example.test/pull/4"\n'
}
gh() {
    printf 'OPEN\n'
}
tmux set-option -w -t "$intent_window" @pipeline_state ""
rm -f "$autofix_calls_file"
rm -f "$(shipyard_state_home)/watcher.log"
rmdir "$(shipyard_state_home)/watch-${intent_window}.lock" 2>/dev/null || true
watcher_run "$intent_window" "$repo_root"
assert_equal "2" "$poll_attempts" \
    "a poll cycle whose last step fails doesn't abort the watcher loop -- it retries next cycle"
assert_equal "published" \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_state)" \
    "watcher applies state normally on the cycle after a failed one"
if [[ ! -s "$(shipyard_state_home)/watcher.log" ]]; then
    printf 'not ok - watcher logs a failed poll cycle for diagnosis\n' >&2
    exit 1
fi
printf 'ok - a failing poll cycle is logged and retried, not left to kill the watcher\n'

# Redefining screenshot_autofix_pr_body as a stub above overwrote the real
# function sourced at the top of this script (bash functions don't stack);
# re-source it now that the watcher-integration tests are done stubbing it out.
# shellcheck source=../lib/screenshot.sh
source "$repo_root/lib/screenshot.sh"

autofix_worktree="$test_tmp/autofix-worktree"
mkdir -p "$autofix_worktree/artifacts"
printf 'fake-png' > "$autofix_worktree/artifacts/after.png"

autofix_pr_body=""
autofix_pr_body_after_view=""
autofix_view_count_file="$test_tmp/autofix-view-count"
# screenshot_autofix_pr_body calls screenshot_publish and screenshot_edit_pr_body
# (which pipes into `gh api`) via command substitution / pipelines, both of
# which fork a subshell -- shell variables mutated in the mocks below wouldn't
# survive back to this scope, so every mock records to disk instead.
autofix_publish_calls_file="$test_tmp/autofix-publish-calls"
autofix_edit_calls_file="$test_tmp/autofix-edit-calls"
autofix_edit_body_file="$test_tmp/autofix-edit-body"
: > "$autofix_publish_calls_file"
: > "$autofix_edit_calls_file"
rm -f "$autofix_edit_body_file"
screenshot_publish() {
    printf '.' >> "$autofix_publish_calls_file"
    printf '![%s](https://example.test/hosted/%s)\n' "$(basename "$1")" "$(basename "$1")"
}
# gh pr edit is deliberately NOT mocked to succeed here: real `gh pr edit
# --body` fails unconditionally (see screenshot_edit_pr_body's comment in
# lib/screenshot.sh), so a mock that answered it would hide a regression
# back to using it. screenshot_autofix_pr_body must go through
# screenshot_edit_pr_body's REST call (`gh api -X PATCH .../pulls/N -f
# body=<value>`) instead -- and not its `-f body=@-`/`@file` form, which this
# tool's actual gh version silently takes as a literal string instead of
# reading a file/stdin (see the same comment).
gh() {
    if [[ "$1" == "pr" && "$2" == "view" ]]; then
        autofix_view_count="$(($(<"$autofix_view_count_file") + 1))"
        printf '%s' "$autofix_view_count" > "$autofix_view_count_file"
        if [[ "$autofix_view_count" -gt 1 && -n "$autofix_pr_body_after_view" ]]; then
            printf '%s' "$autofix_pr_body_after_view"
        else
            printf '%s' "$autofix_pr_body"
        fi
        return 0
    fi
    if [[ "$1" == "repo" && "$2" == "view" ]]; then
        printf 'example/repo'
        return 0
    fi
    if [[ "$1" == "api" && "$2" == "-X" && "$3" == "PATCH" ]]; then
        printf '.' >> "$autofix_edit_calls_file"
        case "$4" in
            repos/example/repo/pulls/42) ;;
            *)
                printf 'not ok - autofix PATCHes the resolved repo and PR number\n%s\n' "$4" >&2
                exit 1
                ;;
        esac
        case "$5" in
            -f) ;;
            *)
                printf 'not ok - autofix passes the new body via -f\n%s\n' "$5" >&2
                exit 1
                ;;
        esac
        case "$6" in
            body=*) ;;
            *)
                printf 'not ok - autofix passes the new body as a literal -f value, not @file/@-\n%s\n' "$6" >&2
                exit 1
                ;;
        esac
        printf '%s' "${6#body=}" > "$autofix_edit_body_file"
        return 0
    fi
    if [[ "$1" == "pr" && "$2" == "edit" ]]; then
        printf 'not ok - autofix must not call gh pr edit (its GraphQL query always fails, see lib/screenshot.sh)\n' >&2
        exit 1
    fi
    return 0
}

printf '0' > "$autofix_view_count_file"
autofix_pr_body='![before](artifacts/before.png) ![after](artifacts/after.png) ![live](https://example.test/already.png)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal \
    '![before](artifacts/before.png) ![after](https://example.test/hosted/after.png) ![live](https://example.test/already.png)' \
    "$(<"$autofix_edit_body_file")" \
    "autofix rewrites only local links that resolve to a real file"
assert_equal "1" "$(wc -c < "$autofix_edit_calls_file")" \
    "autofix edits the PR body once a local link is found"

: > "$autofix_edit_calls_file"
rm -f "$autofix_edit_body_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='![missing](artifacts/missing.png) ![live](https://example.test/already.png)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "0" "$(wc -c < "$autofix_edit_calls_file")" \
    "autofix leaves the PR alone when no local link resolves to a file"

: > "$autofix_publish_calls_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='![a](artifacts/after.png) ![b](artifacts/after.png)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "1" "$(wc -c < "$autofix_publish_calls_file")" \
    "autofix uploads a repeated local file only once"

rm -f "$autofix_edit_body_file"
: > "$autofix_publish_calls_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='- Evidence: Rendered page (local file: <code>artifacts/after.png</code>)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal \
    '- Evidence: Rendered page ![after.png](https://example.test/hosted/after.png)' \
    "$(<"$autofix_edit_body_file")" \
    "autofix embeds no-mistakes local-file evidence annotations"

rm -f "$autofix_edit_body_file"
: > "$autofix_publish_calls_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='![after](artifacts/after.png) (local file: <code>artifacts/after.png</code>)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "1" "$(wc -c < "$autofix_publish_calls_file")" \
    "autofix publishes a file shared by Markdown and evidence annotation once"

rm -f "$autofix_edit_body_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body="![file-uri](file://$autofix_worktree/artifacts/after.png)"
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "https://example.test/hosted/after.png" \
    "$(sed -E 's/.*\(([^)]+)\)/\1/' <"$autofix_edit_body_file")" \
    "autofix strips a file:// prefix before checking the filesystem"

: > "$autofix_edit_calls_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='[download](artifacts/after.png)'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "0" "$(wc -c < "$autofix_edit_calls_file")" \
    "autofix ignores ordinary markdown links to image files"

: > "$autofix_edit_calls_file"
printf '0' > "$autofix_view_count_file"
autofix_pr_body='![after](artifacts/after.png)'
autofix_pr_body_after_view='A concurrently updated body'
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "0" "$(wc -c < "$autofix_edit_calls_file")" \
    "autofix preserves a PR body changed during publication"
autofix_pr_body_after_view=""

: > "$autofix_edit_calls_file"
printf '0' > "$autofix_view_count_file"
screenshot_publish() {
    return 1
}
screenshot_autofix_pr_body "$autofix_worktree" "42"
assert_equal "0" "$(wc -c < "$autofix_edit_calls_file")" \
    "autofix leaves local links intact when publication fails"

shipyard_record_intent "lease-manifest" "/projects/app" "app" "restore work" \
    "/trees/app-2" "shipyard:app:restore work" "abc123" "development" "cursor-agent"
assert_equal \
    $'lease-manifest\t/projects/app\tapp\trestore work\t/trees/app-2\tshipyard:app:restore work\tabc123\tdevelopment\tcursor-agent' \
    "$(cat "$(shipyard_intent_file lease-manifest)")" \
    "intent manifests preserve the state needed to rebuild a window"
assert_equal "codex resume" "$(shipyard_resume_hint codex)" \
    "Codex restore uses its session picker"
assert_equal "claude --continue" "$(shipyard_resume_hint claude)" \
    "Claude restore continues the worktree's last conversation"
assert_equal "cursor-agent --resume" "$(shipyard_resume_hint cursor-agent)" \
    "Cursor restore uses its thread picker"
shipyard_forget_intent lease-manifest
if [[ -e "$(shipyard_intent_file lease-manifest)" ]]; then
    printf 'not ok - forgetting an intent removes its durable manifest\n' >&2
    exit 1
fi
printf 'ok - forgetting an intent removes its durable manifest\n'

treehouse() {
    if [[ "$1" == "status" && "$2" == "--json" ]]; then
        printf '[{"path":"%s","status":"leased","lease_id":"lease-restore"}]\n' "$test_tmp"
    fi
}
shipyard_record_intent "lease-restore" "$test_tmp" "restore-test" "recovered intent" \
    "$test_tmp" "shipyard:restore-test:recovered intent" "base123" "development" "cursor-agent"
shipyard_restore_intent "$(shipyard_intent_file lease-restore)"
restored_window="$(tmux list-windows -t restore-test -F '#{window_id}' | head -n 1)"
assert_equal "lease-restore" \
    "$(tmux show-options -wqv -t "$restored_window" @shipyard_lease_id)" \
    "restore recreates a window for the exact active lease"
assert_equal "2" "$(tmux list-panes -t "$restored_window" | wc -l)" \
    "restore recreates the standard two-pane layout"
assert_equal "1" \
    "$(tmux list-panes -t "$restored_window" -F '#{@shipyard_main_pane}' | grep -c '^1$')" \
    "restore tags the main pane for watcher and agent snapshots"
tmux kill-session -t restore-test
shipyard_forget_lease "$restored_window"
if [[ -e "$(shipyard_intent_file lease-restore)" ]]; then
    printf 'not ok - forgetting a lease also clears its paired intent manifest\n' >&2
    exit 1
fi
printf 'ok - forgetting a lease also clears its paired intent manifest\n'

shipyard_record_intent "lease-dead" "$test_tmp" "dead-restore" "gone intent" \
    "/tmp/shipyard-missing-worktree-$$" "shipyard:dead-restore:gone intent" "base" "development"
shipyard_record_lease "@dead-restore" "/tmp/shipyard-missing-worktree-$$" "lease-dead" \
    "shipyard:dead-restore:gone intent"
if shipyard_restore_intent "$(shipyard_intent_file lease-dead)" 2>/dev/null; then
    printf 'not ok - restore rejects a lease that is no longer restorable\n' >&2
    exit 1
fi
printf 'ok - restore rejects a lease that is no longer restorable\n'
if [[ -e "$(shipyard_intent_file lease-dead)" || -e "$(shipyard_state_home)/windows/lease-dead.lease" ]]; then
    printf 'not ok - restore forgets dead intents and stale lease records\n' >&2
    exit 1
fi
printf 'ok - restore forgets dead intents and stale lease records\n'

treehouse() {
    if [[ "$1" == "status" && "$2" == "--json" ]]; then
        return 1
    fi
}
shipyard_record_intent "lease-unknown" "$test_tmp" "unknown-restore" "unclear intent" \
    "$test_tmp" "shipyard:unknown-restore:unclear intent" "base" "development"
shipyard_record_lease "@unknown-restore" "$test_tmp" "lease-unknown" \
    "shipyard:unknown-restore:unclear intent"
if shipyard_restore_intent "$(shipyard_intent_file lease-unknown)" 2>/dev/null; then
    printf 'not ok - restore does not proceed when the lease probe itself fails\n' >&2
    exit 1
fi
printf 'ok - restore does not proceed when the lease probe itself fails\n'
if [[ ! -e "$(shipyard_intent_file lease-unknown)" || ! -e "$(shipyard_state_home)/windows/lease-unknown.lease" ]]; then
    printf 'not ok - restore preserves manifest and lease record when the probe fails transiently\n' >&2
    exit 1
fi
printf 'ok - restore preserves manifest and lease record when the probe fails transiently\n'
rm -f "$(shipyard_intent_file lease-unknown)" "$(shipyard_state_home)/windows/lease-unknown.lease"

# treehouse resolves its pool from the working directory (git rev-parse
# --show-toplevel), so bare `forge open` -- run wherever the shell happens to
# land after a reboot, not necessarily inside any restored project -- must
# probe each lease from that intent's own project root.
treehouse() {
    if [[ "$1" == "status" && "$2" == "--json" ]]; then
        if [[ "$PWD" == "$test_tmp" ]]; then
            printf '[{"path":"%s","status":"leased","lease_id":"lease-cwd"}]\n' "$test_tmp"
        else
            return 1
        fi
    fi
}
shipyard_record_intent "lease-cwd" "$test_tmp" "cwd-restore" "cwd intent" \
    "$test_tmp" "shipyard:cwd-restore:cwd intent" "base" "development"
shipyard_record_lease "@cwd-restore" "$test_tmp" "lease-cwd" \
    "shipyard:cwd-restore:cwd intent"
cwd_restore_status=0
( cd /tmp && shipyard_restore_intent "$(shipyard_intent_file lease-cwd)" ) || cwd_restore_status=$?
if [[ "$cwd_restore_status" -ne 0 ]]; then
    printf 'not ok - restore probes the lease from the intent'"'"'s own project root, not the caller'"'"'s cwd\n' >&2
    exit 1
fi
printf 'ok - restore probes the lease from the intent'"'"'s own project root, not the caller'"'"'s cwd\n'
tmux kill-session -t cwd-restore 2>/dev/null || true
rm -f "$(shipyard_intent_file lease-cwd)" "$(shipyard_state_home)/windows/lease-cwd.lease"

tmux new-session -d -s legacy-restore -n legacy -c "$test_tmp"
legacy_window="$(tmux display-message -p -t legacy-restore '#{window_id}')"
tmux set-option -t legacy-restore @shipyard_project_root "$test_tmp"
tmux set-option -w -t "$legacy_window" @shipyard_intent "legacy intent"
tmux set-option -w -t "$legacy_window" @shipyard_lease_id "lease-legacy"
tmux set-option -w -t "$legacy_window" @shipyard_base_head "legacy-base"
tmux set-option -w -t "$legacy_window" @shipyard_base_branch "development"
shipyard_record_lease "$legacy_window" "$test_tmp" "lease-legacy" "shipyard:legacy-restore:legacy intent"
main_pane_list='1|codex'
shipyard_snapshot_agent "$legacy_window"
unset main_pane_list
case "$(cat "$(shipyard_intent_file lease-legacy)")" in
    *$'\tlegacy intent\t'*$'\tcodex')
        printf 'ok - watcher backfills manifests and agent kind for legacy windows\n'
        ;;
    *)
        printf 'not ok - watcher backfills manifests and agent kind for legacy windows\n' >&2
        exit 1
        ;;
esac
tmux kill-session -t legacy-restore
shipyard_forget_lease "$legacy_window"
shipyard_forget_intent lease-legacy

tmux kill-server 2>/dev/null || true
rm -f "$(shipyard_state_home)"/intents/*.intent 2>/dev/null || true
restore_empty_output="$(shipyard_restore)"
restore_empty_status=$?
if [[ "$restore_empty_status" -ne 0 ]]; then
    printf 'not ok - forge open with nothing to restore still exits successfully\n' >&2
    exit 1
fi
printf 'ok - forge open with nothing to restore still exits successfully\n'
case "$restore_empty_output" in
    *"no prior sessions"*)
        printf 'ok - forge open with nothing to restore explains itself instead of exiting silently\n'
        ;;
    *)
        printf 'not ok - forge open with nothing to restore explains itself instead of exiting silently\n' >&2
        exit 1
        ;;
esac

pause_no_sessions_output="$(shipyard_pause)"
assert_equal "forge: no open shipyard sessions to pause" "$pause_no_sessions_output" \
    "forge pause reports when there is nothing open"

pause_repo="$test_tmp/pause-repo"
git init -q "$pause_repo"
git -C "$pause_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause_repo"
pause_session="$(shipyard_session_name "$(shipyard_project_root "$pause_repo")")"

treehouse() {
    case "$1" in
        status)
            printf '[{"path":"%s","status":"leased","lease_id":"lease-pause"}]\n' "$pause_repo"
            ;;
        return)
            printf 'unexpected treehouse return during pause test\n' > "$test_tmp/pause-return-called"
            ;;
    esac
}

pause_intent_window="$(tmux new-window -d -P -F '#{window_id}' \
    -t "=$pause_session:" -n "pause work" -c "$pause_repo")"
tmux set-option -w -t "$pause_intent_window" @shipyard_worktree "$pause_repo"
tmux set-option -w -t "$pause_intent_window" @shipyard_lease_id "lease-pause"
tmux set-option -w -t "$pause_intent_window" @shipyard_base_head "abc123"
tmux set-option -w -t "$pause_intent_window" @shipyard_base_branch "main"
shipyard_record_lease "$pause_intent_window" "$pause_repo" "lease-pause" \
    "shipyard:$pause_session:pause work"
shipyard_record_intent "lease-pause" "$pause_repo" "$pause_session" "pause work" \
    "$pause_repo" "shipyard:$pause_session:pause work" "abc123" "main"

pause_output="$(shipyard_pause)"
case "$pause_output" in
    *"paused 1 shipyard session"*)
        printf 'ok - forge pause reports how many sessions it paused\n'
        ;;
    *)
        printf 'not ok - forge pause reports how many sessions it paused\n%s\n' "$pause_output" >&2
        exit 1
        ;;
esac

if tmux has-session -t "=$pause_session" 2>/dev/null; then
    printf 'not ok - forge pause closes the session\n' >&2
    exit 1
fi
printf 'ok - forge pause closes the session\n'

if [[ -e "$(shipyard_state_home)/windows/lease-pause.lease" ]]; then
    printf "not ok - forge pause disarms the intent window's lease record\n" >&2
    exit 1
fi
printf "ok - forge pause disarms the intent window's lease record\n"

if [[ ! -e "$(shipyard_intent_file lease-pause)" ]]; then
    printf 'not ok - forge pause preserves the intent manifest\n' >&2
    exit 1
fi
printf 'ok - forge pause preserves the intent manifest\n'

if [[ ! -e "$(shipyard_project_file "$pause_session")" ]]; then
    printf 'not ok - forge pause records the repository even for a session with intents\n' >&2
    exit 1
fi
printf 'ok - forge pause records the repository even for a session with intents\n'

shipyard_reap "$pause_intent_window"
if [[ -e "$test_tmp/pause-return-called" ]]; then
    printf 'not ok - a reap queued against a paused window never returns its still-active lease\n' >&2
    exit 1
fi
printf 'ok - a reap queued against a paused window never returns its still-active lease\n'

shipyard_restore >/dev/null
restored_pause_window="$(tmux list-windows -t "=$pause_session" \
    -F '#{@shipyard_lease_id} #{window_id}' 2>/dev/null |
    awk '$1 == "lease-pause" {print $2; exit}')"
if [[ -z "$restored_pause_window" ]]; then
    printf 'not ok - forge open restores a paused intent window\n' >&2
    exit 1
fi
printf 'ok - forge open restores a paused intent window\n'

if [[ -z "$(shipyard_command_window "$pause_session")" ||
    -z "$(shipyard_repo_window "$pause_session")" ]]; then
    printf "not ok - forge open restores the paused repository's repo and command windows too\n" >&2
    exit 1
fi
printf "ok - forge open restores the paused repository's repo and command windows too\n"

if [[ -e "$(shipyard_project_file "$pause_session")" ]]; then
    printf 'not ok - forge open consumes the project manifest once a session is restored\n' >&2
    exit 1
fi
printf 'ok - forge open consumes the project manifest once a session is restored\n'

tmux kill-session -t "=$pause_session" 2>/dev/null || true
shipyard_forget_lease "$restored_pause_window"
rm -f "$test_tmp/pause-return-called"

pause2_repo="$test_tmp/pause-repo-2"
git init -q "$pause2_repo"
git -C "$pause2_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause2_repo"
pause2_session="$(shipyard_session_name "$(shipyard_project_root "$pause2_repo")")"

shipyard_pause >/dev/null

if tmux has-session -t "=$pause2_session" 2>/dev/null; then
    printf 'not ok - forge pause closes a repo/command-only session too\n' >&2
    exit 1
fi
printf 'ok - forge pause closes a repo/command-only session too\n'

if [[ ! -e "$(shipyard_project_file "$pause2_session")" ]]; then
    printf 'not ok - forge pause records a repo/command-only session for later restore\n' >&2
    exit 1
fi
printf 'ok - forge pause records a repo/command-only session for later restore\n'

shipyard_restore >/dev/null

if ! tmux has-session -t "=$pause2_session" 2>/dev/null; then
    printf 'not ok - forge open recreates a paused repo/command-only session\n' >&2
    exit 1
fi
printf 'ok - forge open recreates a paused repo/command-only session\n'

if [[ -z "$(shipyard_command_window "$pause2_session")" ||
    -z "$(shipyard_repo_window "$pause2_session")" ]]; then
    printf 'not ok - forge open recreates both windows of a paused repo/command-only session\n' >&2
    exit 1
fi
printf 'ok - forge open recreates both windows of a paused repo/command-only session\n'

if [[ -e "$(shipyard_project_file "$pause2_session")" ]]; then
    printf 'not ok - forge open consumes the repo/command-only project manifest\n' >&2
    exit 1
fi
printf 'ok - forge open consumes the repo/command-only project manifest\n'

tmux kill-session -t "=$pause2_session" 2>/dev/null || true

pause_a_repo="$test_tmp/pause-aaa"
pause_b_repo="$test_tmp/pause-bbb"
git init -q "$pause_a_repo"
git -C "$pause_a_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$pause_b_repo"
git -C "$pause_b_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause_a_repo"
TMUX="test" shipyard_open "$pause_b_repo"
pause_a_session="$(shipyard_session_name "$(shipyard_project_root "$pause_a_repo")")"
pause_b_session="$(shipyard_session_name "$(shipyard_project_root "$pause_b_repo")")"
pause_a_pane="$(tmux list-panes -t "=$pause_a_session" -F '#{pane_id}' | head -n1)"

TMUX_PANE="$pause_a_pane" shipyard_pause >/dev/null

if tmux has-session -t "=$pause_a_session" 2>/dev/null; then
    printf 'not ok - forge pause from inside a session still closes that session\n' >&2
    exit 1
fi
if tmux has-session -t "=$pause_b_session" 2>/dev/null; then
    printf 'not ok - forge pause from inside one session still closes later siblings\n' >&2
    exit 1
fi
printf 'ok - forge pause from inside one session closes every shipyard session\n'

if [[ ! -e "$(shipyard_project_file "$pause_a_session")" ||
    ! -e "$(shipyard_project_file "$pause_b_session")" ]]; then
    printf 'not ok - forge pause records every session before deferred self-kill\n' >&2
    exit 1
fi
printf 'ok - forge pause records every session before deferred self-kill\n'

rm -f "$(shipyard_project_file "$pause_a_session")" \
    "$(shipyard_project_file "$pause_b_session")"

rm -f "$(shipyard_state_home)"/intents/*.intent 2>/dev/null || true
pause_fail_repo="$test_tmp/pause-ensure-fail"
git init -q "$pause_fail_repo"
git -C "$pause_fail_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
pause_fail_session="$(shipyard_session_name "$(shipyard_project_root "$pause_fail_repo")")"
shipyard_record_project "$pause_fail_session" "$(shipyard_project_root "$pause_fail_repo")"
fail_new_session=1
restore_fail_status=0
shipyard_restore >/dev/null || restore_fail_status=$?
fail_new_session=0
if [[ "$restore_fail_status" -eq 0 ]]; then
    printf 'not ok - forge open reports failure when a paused project cannot be ensured\n' >&2
    exit 1
fi
if [[ ! -e "$(shipyard_project_file "$pause_fail_session")" ]]; then
    printf 'not ok - forge open keeps the project manifest when ensure fails\n' >&2
    exit 1
fi
printf 'ok - forge open keeps the project manifest when ensure fails\n'
rm -f "$(shipyard_project_file "$pause_fail_session")"

pause_collide_a="$test_tmp/pause-collide/a/app"
pause_collide_b="$test_tmp/pause-collide/b/app"
mkdir -p "$(dirname "$pause_collide_a")" "$(dirname "$pause_collide_b")"
git init -q "$pause_collide_a"
git -C "$pause_collide_a" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$pause_collide_b"
git -C "$pause_collide_b" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause_collide_a"
pause_collide_session="$(shipyard_session_name "$(shipyard_project_root "$pause_collide_a")")"
shipyard_pause >/dev/null
pause_collide_b_session="$(shipyard_session_for_project "$(shipyard_project_root "$pause_collide_b")")"
case "$pause_collide_b_session" in
    "$pause_collide_session"-*)
        ;;
    *)
        printf 'not ok - open of a same-basename project must digest away from a paused short name\n' >&2
        exit 1
        ;;
esac
TMUX="test" shipyard_open "$pause_collide_b"
assert_equal "$(shipyard_project_root "$pause_collide_b")" \
    "$(tmux show-options -qv -t "$pause_collide_b_session" @shipyard_project_root)" \
    "a later open of a same-basename project lands in a digested session"
if [[ ! -e "$(shipyard_project_file "$pause_collide_session")" ]]; then
    printf 'not ok - opening another same-basename project must leave the paused manifest alone\n' >&2
    exit 1
fi
IFS=$'\t' read -r _ pause_collide_recorded_root \
    < "$(shipyard_project_file "$pause_collide_session")"
assert_equal "$(shipyard_project_root "$pause_collide_a")" "$pause_collide_recorded_root" \
    "paused short-name manifest still records the original project root after a colliding open"
shipyard_pause >/dev/null
if [[ ! -e "$(shipyard_project_file "$pause_collide_session")" ]]; then
    printf 'not ok - pausing the digested session must not destroy the paused short-name manifest\n' >&2
    exit 1
fi
IFS=$'\t' read -r _ pause_collide_recorded_root \
    < "$(shipyard_project_file "$pause_collide_session")"
assert_equal "$(shipyard_project_root "$pause_collide_a")" "$pause_collide_recorded_root" \
    "pausing a digested same-basename session does not overwrite the paused short-name manifest"
printf 'ok - paused short names are reserved so later open/pause cannot clobber them\n'
tmux kill-session -t "=$pause_collide_b_session" 2>/dev/null || true
tmux kill-session -t "=$pause_collide_session" 2>/dev/null || true
rm -f "$(shipyard_project_file "$pause_collide_session")" \
    "$(shipyard_project_file "$pause_collide_b_session")"

rm -f "$(shipyard_state_home)"/intents/*.intent 2>/dev/null || true
pause_intent_collide_a="$test_tmp/pause-intent-collide/a/app"
pause_intent_collide_b="$test_tmp/pause-intent-collide/b/app"
mkdir -p "$(dirname "$pause_intent_collide_a")" "$(dirname "$pause_intent_collide_b")"
git init -q "$pause_intent_collide_a"
git -C "$pause_intent_collide_a" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$pause_intent_collide_b"
git -C "$pause_intent_collide_b" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause_intent_collide_a"
pause_intent_collide_session="$(shipyard_session_name "$(shipyard_project_root "$pause_intent_collide_a")")"
pause_intent_collide_window="$(tmux new-window -d -P -F '#{window_id}' \
    -t "=$pause_intent_collide_session:" -n "collide work" -c "$pause_intent_collide_a")"
tmux set-option -w -t "$pause_intent_collide_window" @shipyard_worktree "$pause_intent_collide_a"
tmux set-option -w -t "$pause_intent_collide_window" @shipyard_lease_id "lease-intent-collide"
tmux set-option -w -t "$pause_intent_collide_window" @shipyard_base_head "abc123"
tmux set-option -w -t "$pause_intent_collide_window" @shipyard_base_branch "main"
shipyard_record_lease "$pause_intent_collide_window" "$pause_intent_collide_a" \
    "lease-intent-collide" "shipyard:$pause_intent_collide_session:collide work"
shipyard_record_intent "lease-intent-collide" \
    "$(shipyard_project_root "$pause_intent_collide_a")" \
    "$pause_intent_collide_session" "collide work" \
    "$pause_intent_collide_a" "shipyard:$pause_intent_collide_session:collide work" \
    "abc123" "main"
treehouse() {
    case "$1" in
        status)
            printf '[{"path":"%s","status":"leased","lease_id":"lease-intent-collide"}]\n' \
                "$pause_intent_collide_a"
            ;;
        return)
            printf 'unexpected treehouse return during intent collision restore\n' \
                > "$test_tmp/intent-collide-return-called"
            ;;
    esac
}
shipyard_pause >/dev/null
pause_intent_collide_b_session="$(shipyard_session_for_project "$(shipyard_project_root "$pause_intent_collide_b")")"
case "$pause_intent_collide_b_session" in
    "$pause_intent_collide_session"-*)
        ;;
    *)
        printf 'not ok - open must digest away from a paused short name before intent restore\n' >&2
        exit 1
        ;;
esac
TMUX="test" shipyard_open "$pause_intent_collide_b"
assert_equal "$(shipyard_project_root "$pause_intent_collide_b")" \
    "$(tmux show-options -qv -t "$pause_intent_collide_b_session" @shipyard_project_root)" \
    "a later open of a same-basename project lands in a digested session for intent collision"
restore_intent_collide_status=0
TMUX="test" shipyard_restore >/dev/null || restore_intent_collide_status=$?
if [[ "$restore_intent_collide_status" -ne 0 ]]; then
    printf 'not ok - forge open should restore paused intents into their reserved short-name session\n' >&2
    exit 1
fi
misplaced_intent="$(tmux list-windows -t "=$pause_intent_collide_b_session" \
    -F '#{@shipyard_lease_id}' 2>/dev/null | grep -c '^lease-intent-collide$' || true)"
if [[ "$misplaced_intent" -ne 0 ]]; then
    printf 'not ok - forge open must not restore a paused intent into another project session\n' >&2
    exit 1
fi
assert_equal "$(shipyard_project_root "$pause_intent_collide_a")" \
    "$(tmux show-options -qv -t "$pause_intent_collide_session" @shipyard_project_root)" \
    "paused intent restore recreates the original short-name session"
restored_intent="$(tmux list-windows -t "=$pause_intent_collide_session" \
    -F '#{@shipyard_lease_id}' 2>/dev/null | grep -c '^lease-intent-collide$' || true)"
if [[ "$restored_intent" -ne 1 ]]; then
    printf 'not ok - forge open must restore the paused intent into its own session\n' >&2
    exit 1
fi
printf 'ok - forge open restores paused intents beside a digested same-basename session\n'
tmux kill-session -t "=$pause_intent_collide_session" 2>/dev/null || true
tmux kill-session -t "=$pause_intent_collide_b_session" 2>/dev/null || true
rm -f "$(shipyard_project_file "$pause_intent_collide_session")" \
    "$(shipyard_project_file "$pause_intent_collide_b_session")"
shipyard_forget_intent lease-intent-collide

pause_close_collide_a="$test_tmp/pause-close-collide/a/app"
pause_close_collide_b="$test_tmp/pause-close-collide/b/app"
mkdir -p "$(dirname "$pause_close_collide_a")" "$(dirname "$pause_close_collide_b")"
git init -q "$pause_close_collide_a"
git -C "$pause_close_collide_a" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$pause_close_collide_b"
git -C "$pause_close_collide_b" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$pause_close_collide_a"
pause_close_collide_session="$(shipyard_session_name "$(shipyard_project_root "$pause_close_collide_a")")"
shipyard_pause >/dev/null
tmux new-session -d -s "$pause_close_collide_session" -n command -c "$pause_close_collide_b"
tmux set-option -t "$pause_close_collide_session" @shipyard_project_root \
    "$(shipyard_project_root "$pause_close_collide_b")"
tmux set-option -w -t "=$pause_close_collide_session:" @shipyard_role command
pause_close_collide_command="$(shipyard_command_window "$pause_close_collide_session")"
shipyard_close_command_window "$pause_close_collide_command"
if [[ ! -e "$(shipyard_project_file "$pause_close_collide_session")" ]]; then
    printf 'not ok - forge close keeps a paused project manifest belonging to another root\n' >&2
    exit 1
fi
printf 'ok - forge close keeps a paused project manifest belonging to another root\n'
rm -f "$(shipyard_project_file "$pause_close_collide_session")"

rm -f "$(shipyard_state_home)"/intents/*.intent 2>/dev/null || true
pause_intent_steal_a="$test_tmp/pause-intent-steal/a/app"
pause_intent_steal_b="$test_tmp/pause-intent-steal/b/app"
mkdir -p "$(dirname "$pause_intent_steal_a")" "$(dirname "$pause_intent_steal_b")"
git init -q "$pause_intent_steal_a"
git -C "$pause_intent_steal_a" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$pause_intent_steal_b"
git -C "$pause_intent_steal_b" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
pause_intent_steal_session="$(shipyard_session_name "$(shipyard_project_root "$pause_intent_steal_a")")"
# Durable intent for B still naming the short session (tmux loss without pause).
shipyard_record_intent "lease-intent-steal" \
    "$(shipyard_project_root "$pause_intent_steal_b")" \
    "$pause_intent_steal_session" "steal work" \
    "$pause_intent_steal_b" "shipyard:$pause_intent_steal_session:steal work" \
    "abc123" "main"
treehouse() {
    case "$1" in
        status)
            printf '[{"path":"%s","status":"leased","lease_id":"lease-intent-steal"}]\n' \
                "$pause_intent_steal_b"
            ;;
        return)
            printf 'unexpected treehouse return during intent steal restore\n' \
                > "$test_tmp/intent-steal-return-called"
            ;;
    esac
}
TMUX="test" shipyard_open "$pause_intent_steal_a"
shipyard_pause >/dev/null
if [[ ! -e "$(shipyard_project_file "$pause_intent_steal_session")" ]]; then
    printf 'not ok - pause must record the short-name project before intent steal restore\n' >&2
    exit 1
fi
restore_intent_steal_status=0
if shipyard_restore_intent "$(shipyard_intent_file lease-intent-steal)" 2>/dev/null; then
    printf 'not ok - intent restore must not mint a session reserved by a paused project\n' >&2
    exit 1
else
    restore_intent_steal_status=$?
fi
if [[ "$restore_intent_steal_status" -eq 0 ]]; then
    printf 'not ok - intent restore must fail closed when a paused project owns the name\n' >&2
    exit 1
fi
if tmux has-session -t "=$pause_intent_steal_session" 2>/dev/null; then
    printf 'not ok - intent restore must leave the paused short name free for its owner\n' >&2
    exit 1
fi
if [[ ! -e "$(shipyard_intent_file lease-intent-steal)" ]]; then
    printf 'not ok - intent restore must keep the colliding intent for a later retry\n' >&2
    exit 1
fi
if [[ ! -e "$(shipyard_project_file "$pause_intent_steal_session")" ]]; then
    printf 'not ok - intent restore must leave the paused project manifest alone\n' >&2
    exit 1
fi
# A foreign live session must not be joinable via ensure for another root.
tmux new-session -d -s "$pause_intent_steal_session" -n command -c "$pause_intent_steal_b"
tmux set-option -t "$pause_intent_steal_session" @shipyard_project_root \
    "$(shipyard_project_root "$pause_intent_steal_b")"
if shipyard_ensure_project_session \
    "$(shipyard_project_root "$pause_intent_steal_a")" \
    "$pause_intent_steal_session" >/dev/null 2>&1; then
    printf 'not ok - ensure must refuse a live session owned by a different project root\n' >&2
    exit 1
fi
assert_equal "$(shipyard_project_root "$pause_intent_steal_b")" \
    "$(tmux show-options -qv -t "$pause_intent_steal_session" @shipyard_project_root)" \
    "ensure leaves a foreign session root unchanged when refusing to join"
printf 'ok - intent restore and ensure refuse paused/foreign short-name ownership\n'
tmux kill-session -t "=$pause_intent_steal_session" 2>/dev/null || true
rm -f "$(shipyard_project_file "$pause_intent_steal_session")"
shipyard_forget_intent lease-intent-steal

# Session names where one is a prefix of another (demo-repo vs demo-repo-only)
# must not confuse tmux's default prefix matching during pause/restore.
rm -f "$(shipyard_state_home)"/intents/*.intent 2>/dev/null || true
rm -f "$(shipyard_state_home)"/projects/*.project 2>/dev/null || true
prefix_short_repo="$test_tmp/prefix-short"
prefix_long_repo="$test_tmp/prefix-short-extra"
git init -q "$prefix_short_repo"
git -C "$prefix_short_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
git init -q "$prefix_long_repo"
git -C "$prefix_long_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
TMUX="test" shipyard_open "$prefix_short_repo"
TMUX="test" shipyard_open "$prefix_long_repo"
prefix_short_session="$(shipyard_session_name "$(shipyard_project_root "$prefix_short_repo")")"
prefix_long_session="$(shipyard_session_name "$(shipyard_project_root "$prefix_long_repo")")"
case "$prefix_long_session" in
    "$prefix_short_session"*)
        ;;
    *)
        printf 'not ok - fixture needs a session name that prefixes another\n' >&2
        exit 1
        ;;
esac
assert_equal "$(shipyard_project_root "$prefix_short_repo")" \
    "$(shipyard_session_option "$prefix_short_session" @shipyard_project_root)" \
    "short-name session keeps its own project root beside a longer-named sibling"
assert_equal "$(shipyard_project_root "$prefix_long_repo")" \
    "$(shipyard_session_option "$prefix_long_session" @shipyard_project_root)" \
    "longer-named session keeps its own project root beside its short-name prefix"
shipyard_pause >/dev/null
restore_prefix_status=0
shipyard_restore >/dev/null || restore_prefix_status=$?
if [[ "$restore_prefix_status" -ne 0 ]]; then
    printf 'not ok - forge open must restore prefix-colliding paused sessions without failing\n' >&2
    exit 1
fi
assert_equal "$(shipyard_project_root "$prefix_short_repo")" \
    "$(shipyard_session_option "$prefix_short_session" @shipyard_project_root)" \
    "restore keeps the short-name session pointed at its own root"
assert_equal "$(shipyard_project_root "$prefix_long_repo")" \
    "$(shipyard_session_option "$prefix_long_session" @shipyard_project_root)" \
    "restore keeps the longer-named session pointed at its own root"
if [[ -z "$(shipyard_command_window "$prefix_short_session")" ||
    -z "$(shipyard_repo_window "$prefix_short_session")" ||
    -z "$(shipyard_command_window "$prefix_long_session")" ||
    -z "$(shipyard_repo_window "$prefix_long_session")" ]]; then
    printf 'not ok - forge open must rebuild repo/command windows for both prefix-colliding sessions\n' >&2
    exit 1
fi
printf 'ok - pause/restore keeps prefix-colliding session names distinct\n'
tmux kill-session -t "=$prefix_short_session" 2>/dev/null || true
tmux kill-session -t "=$prefix_long_session" 2>/dev/null || true

# --- commit-msg trailer normalization ---
trailer_msg="$(mktemp -p "$test_tmp")"
printf '%s\n' 'Subject line' '' 'Body.' '' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' \
    'Co-Authored-By: Cursor Composer <cursoragent@cursor.com>' > "$trailer_msg"
"$repo_root/githooks/commit-msg" "$trailer_msg"
assert_equal "$(cat "$trailer_msg")" \
"$(printf '%s\n' 'Subject line' '' 'Body.' '' 'Co-Authored-By: Cursor Composer <cursoragent@cursor.com>')" \
    "commit-msg drops generic injector when ToolName Model present"
human_trailer_msg="$(mktemp -p "$test_tmp")"
printf '%s\n' 'Subject line' '' \
    'Co-authored-by: Ada Lovelace <ada@example.com>' \
    'Co-authored-by: Alan Turing <alan@example.com>' > "$human_trailer_msg"
"$repo_root/githooks/commit-msg" "$human_trailer_msg"
assert_equal "$(cat "$human_trailer_msg")" \
"$(printf '%s\n' 'Subject line' '' \
    'Co-authored-by: Ada Lovelace <ada@example.com>' \
    'Co-authored-by: Alan Turing <alan@example.com>')" \
    "commit-msg leaves multi-human Co-Authored-By trailers intact"
ai_plus_human_msg="$(mktemp -p "$test_tmp")"
printf '%s\n' 'Subject line' '' \
    'Co-authored-by: Ada Lovelace <ada@example.com>' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' \
    'Co-Authored-By: Cursor Composer <cursoragent@cursor.com>' > "$ai_plus_human_msg"
"$repo_root/githooks/commit-msg" "$ai_plus_human_msg"
assert_equal "$(cat "$ai_plus_human_msg")" \
"$(printf '%s\n' 'Subject line' '' \
    'Co-authored-by: Ada Lovelace <ada@example.com>' \
    'Co-Authored-By: Cursor Composer <cursoragent@cursor.com>')" \
    "commit-msg keeps human trailer while dropping Cursor injector"
bot_trailer_msg="$(mktemp -p "$test_tmp")"
printf '%s\n' 'Subject' '' 'Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' > "$bot_trailer_msg"
"$repo_root/githooks/commit-msg" "$bot_trailer_msg"
assert_equal "$(cat "$bot_trailer_msg")" \
"$(printf '%s\n' 'Subject' '' 'Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>')" \
    "commit-msg leaves single-token bot trailers intact"

# --- shipyard_install_git_hooks ---
hooks_repo="$test_tmp/hooks-repo"
mkdir -p "$hooks_repo"
git init -q "$hooks_repo"
git -C "$hooks_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
# Existing product hook must keep running after install
product_hook="$hooks_repo/.git/hooks/commit-msg"
mkdir -p "$(dirname "$product_hook")"
printf '%s\n' '#!/bin/sh' 'echo product-hook-ran >> "$1"' > "$product_hook"
chmod +x "$product_hook"
shipyard_install_git_hooks "$hooks_repo"
if git -C "$hooks_repo" config --get core.hooksPath >/dev/null 2>&1; then
    printf 'not ok - shipyard_install_git_hooks must not set exclusive core.hooksPath\n' >&2
    exit 1
fi
printf 'ok - shipyard_install_git_hooks leaves core.hooksPath unset\n'
common_hooks="$(git -C "$hooks_repo" rev-parse --git-common-dir)/hooks"
if [[ "$common_hooks" != /* ]]; then
    common_hooks="$hooks_repo/$common_hooks"
fi
[[ -x "$common_hooks/commit-msg" ]] || {
    printf 'not ok - expected commit-msg wrapper in common hooks dir\n' >&2
    exit 1
}
grep -q 'shipyard-managed-commit-msg' "$common_hooks/commit-msg" || {
    printf 'not ok - expected shipyard-managed commit-msg wrapper\n' >&2
    exit 1
}
[[ -e "$common_hooks/commit-msg.shipyard-wrapped" ]] || {
    printf 'not ok - expected previous commit-msg to be wrapped\n' >&2
    exit 1
}
chain_msg="$(mktemp -p "$test_tmp")"
printf '%s\n' 'Subject' '' \
    'Co-authored-by: Cursor <cursoragent@cursor.com>' \
    'Co-Authored-By: Cursor Composer <cursoragent@cursor.com>' > "$chain_msg"
"$common_hooks/commit-msg" "$chain_msg"
grep -q 'product-hook-ran' "$chain_msg" || {
    printf 'not ok - chained product commit-msg did not run\n' >&2
    exit 1
}
assert_equal "$(grep -c 'Co-Authored-By: Cursor Composer' "$chain_msg" || true)" "1" \
    "wrapper runs shipyard normalizer after product hook"
# Migrate off a prior exclusive Shipyard hooksPath
exclusive_repo="$test_tmp/hooks-exclusive"
mkdir -p "$exclusive_repo"
git init -q "$exclusive_repo"
git -C "$exclusive_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
shipyard_hooks="$(cd "$repo_root/githooks" && pwd -P)"
git -C "$exclusive_repo" config core.hooksPath "$shipyard_hooks"
shipyard_install_git_hooks "$exclusive_repo"
if git -C "$exclusive_repo" config --get core.hooksPath >/dev/null 2>&1; then
    printf 'not ok - install should unset exclusive Shipyard core.hooksPath\n' >&2
    exit 1
fi
printf 'ok - shipyard_install_git_hooks migrates exclusive core.hooksPath\n'
excl_common="$(git -C "$exclusive_repo" rev-parse --git-common-dir)/hooks"
if [[ "$excl_common" != /* ]]; then
    excl_common="$exclusive_repo/$excl_common"
fi
[[ -x "$excl_common/commit-msg" ]] || {
    printf 'not ok - expected commit-msg after exclusive hooksPath migration\n' >&2
    exit 1
}
printf 'ok - shipyard_install_git_hooks installs into common hooks dir\n'

# --- bin/browser ---
browser_bin="$repo_root/bin/browser"
browser_help="$("$browser_bin" --help)"
[[ "$browser_help" == *"Usage:"$'\n'"  browser "* ]] || {
    printf 'not ok - browser --help should document the bare command\n' >&2
    exit 1
}
[[ "$browser_help" != *"./scripts/browser"* ]] || {
    printf 'not ok - browser --help still mentions ./scripts/browser\n' >&2
    exit 1
}
printf 'ok - browser --help documents the bare command\n'

non_git="$test_tmp/not-a-repo"
mkdir -p "$non_git"
if (cd "$non_git" && "$browser_bin" snapshot) >"$test_tmp/browser-out" 2>"$test_tmp/browser-err"; then
    printf 'not ok - browser should fail outside a git repository\n' >&2
    exit 1
fi
grep -q 'Not inside a git repository' "$test_tmp/browser-err" || {
    printf 'not ok - expected git-repo error from browser\n%s\n' \
        "$(cat "$test_tmp/browser-err")" >&2
    exit 1
}
printf 'ok - browser fails outside a git repository\n'

empty_repo="$test_tmp/empty-repo"
mkdir -p "$empty_repo"
git init -q "$empty_repo"
if (cd "$empty_repo" && "$browser_bin" snapshot) >"$test_tmp/browser-out" 2>"$test_tmp/browser-err"; then
    printf 'not ok - browser should fail without Playwright CLI\n' >&2
    exit 1
fi
grep -q 'Playwright CLI was not found' "$test_tmp/browser-err" || {
    printf 'not ok - expected missing Playwright CLI error\n%s\n' \
        "$(cat "$test_tmp/browser-err")" >&2
    exit 1
}
printf 'ok - browser fails when Playwright CLI is missing\n'

product_repo="$test_tmp/product-repo"
playwright_log="$test_tmp/playwright.log"
mkdir -p \
    "$product_repo/node_modules/.bin" \
    "$product_repo/.playwright" \
    "$product_repo/subdir"
git init -q "$product_repo"
product_root="$(git -C "$product_repo" rev-parse --show-toplevel)"
cat > "$product_repo/node_modules/.bin/playwright-cli" <<EOF
#!/usr/bin/env bash
{
    printf 'cwd=%s\n' "\$PWD"
    printf 'args=%s\n' "\$*"
} > "$playwright_log"
EOF
chmod +x "$product_repo/node_modules/.bin/playwright-cli"
printf '{}\n' > "$product_repo/.playwright/cli.config.json"

if (cd "$product_repo" && "$browser_bin" snapshot) >"$test_tmp/browser-out" 2>"$test_tmp/browser-err"; then
    :
else
    printf 'not ok - browser snapshot should invoke Playwright CLI\n%s\n' \
        "$(cat "$test_tmp/browser-err")" >&2
    exit 1
fi
assert_equal "$(grep '^cwd=' "$playwright_log")" "cwd=$product_root" \
    "browser invokes Playwright under the product repo root"
assert_equal "$(grep '^args=' "$playwright_log")" "args=snapshot" \
    "browser snapshot forwards the command without --config"

rm -f "$playwright_log"
(cd "$product_repo/subdir" && "$browser_bin" open http://localhost:3000)
assert_equal "$(grep '^cwd=' "$playwright_log")" "cwd=$product_root" \
    "browser resolves the product repo from a subdirectory"
assert_equal "$(grep '^args=' "$playwright_log")" \
    "args=--config $product_root/.playwright/cli.config.json open http://localhost:3000" \
    "browser open passes the product-repo Playwright config"

rm -f "$playwright_log"
(cd "$product_repo" && "$browser_bin" screenshot homepage --full-page)
[[ -d "$product_root/artifacts/browser/screenshots" ]] || {
    printf 'not ok - browser screenshot should create artifact directories\n' >&2
    exit 1
}
assert_equal "$(grep '^args=' "$playwright_log")" \
    "args=screenshot --filename $product_root/artifacts/browser/screenshots/homepage.png --full-page" \
    "browser screenshot writes under the product repo artifact root"

if (cd "$product_repo" && "$browser_bin" screenshot ../escape) \
    >"$test_tmp/browser-out" 2>"$test_tmp/browser-err"; then
    printf 'not ok - browser screenshot should reject path names\n' >&2
    exit 1
fi
grep -q 'must not contain directory paths' "$test_tmp/browser-err" || {
    printf 'not ok - expected path-rejection error from browser screenshot\n%s\n' \
        "$(cat "$test_tmp/browser-err")" >&2
    exit 1
}
printf 'ok - browser screenshot rejects directory paths in names\n'

printf 'all tests passed\n'
