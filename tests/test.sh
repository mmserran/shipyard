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
    if [[ "$1" == "split-window" && "$*" == *" -h "* ]]; then
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

assert_equal " 💡 " "$(pipeline_badge_for planning)" "planning uses lightbulb"
assert_equal " ● " "$(pipeline_badge_for building)" "building uses dot"
assert_equal " 🔍 " "$(pipeline_badge_for validating)" "validating uses magnifying glass"
assert_equal " 🚢 " "$(pipeline_badge_for merged)" "merged uses cargo ship"

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

nm_root="$test_tmp/nm-root"
git init -q "$nm_root"
git -C "$nm_root" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
mkdir -p "$nm_root/node_modules"
: > "$nm_root/node_modules/marker"
printf '{"name":"nm-root"}\n' > "$nm_root/package.json"
printf '{"lockfileVersion":3}\n' > "$nm_root/package-lock.json"
nm_root_canonical="$(cd "$nm_root" && pwd -P)"

nm_worktree="$test_tmp/nm-worktree"
git -C "$nm_root" worktree add -q --detach "$nm_worktree"

shipyard_link_node_modules "$nm_worktree"
if [[ -L "$nm_worktree/node_modules" ]] \
    && [[ "$(readlink "$nm_worktree/node_modules")" == "$nm_root_canonical/node_modules" ]]; then
    printf 'ok - no-new-deps symlinks the worktree'"'"'s node_modules to the root checkout\n'
else
    printf 'not ok - no-new-deps symlinks the worktree'"'"'s node_modules to the root checkout\n' >&2
    exit 1
fi

shipyard_link_node_modules "$nm_worktree"
assert_equal "$nm_root_canonical/node_modules" "$(readlink "$nm_worktree/node_modules")" \
    "no-new-deps is idempotent once already linked"

printf '{"lockfileVersion":3,"changed":true}\n' > "$nm_worktree/package-lock.json"
linked_mismatch_warning="$(shipyard_link_node_modules "$nm_worktree" 2>&1 1>/dev/null)"
case "$linked_mismatch_warning" in
    *"package-lock.json"*"differs"*)
        printf 'ok - no-new-deps warns on a mismatch when already linked\n'
        ;;
    *)
        printf 'not ok - no-new-deps warns on a mismatch when already linked\n%s\n' \
            "$linked_mismatch_warning" >&2
        exit 1
        ;;
esac
printf '{"lockfileVersion":3}\n' > "$nm_worktree/package-lock.json"

shipyard_unlink_node_modules "$nm_worktree"
if [[ -d "$nm_worktree/node_modules" && ! -L "$nm_worktree/node_modules" ]]; then
    printf 'ok - new-deps restores a real, independent node_modules directory\n'
else
    printf 'not ok - new-deps restores a real, independent node_modules directory\n' >&2
    exit 1
fi

: > "$nm_worktree/node_modules/leftover"
shipyard_link_node_modules "$nm_worktree"
if [[ -L "$nm_worktree/node_modules" ]] \
    && compgen -G "$nm_worktree/node_modules.pre-link.*" > /dev/null; then
    printf 'ok - no-new-deps preserves a pre-existing real node_modules instead of deleting it\n'
else
    printf 'not ok - no-new-deps preserves a pre-existing real node_modules instead of deleting it\n' >&2
    exit 1
fi
rm -rf "$nm_worktree"/node_modules.pre-link.*

nm_no_pkg_root="$test_tmp/nm-no-pkg-root"
git init -q "$nm_no_pkg_root"
git -C "$nm_no_pkg_root" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m initial
nm_no_pkg_worktree="$test_tmp/nm-no-pkg-worktree"
git -C "$nm_no_pkg_root" worktree add -q --detach "$nm_no_pkg_worktree"
shipyard_link_node_modules "$nm_no_pkg_worktree"
if [[ -e "$nm_no_pkg_worktree/node_modules" ]]; then
    printf 'not ok - no-new-deps is a no-op for a non-Node project\n' >&2
    exit 1
fi
printf 'ok - no-new-deps is a no-op for a non-Node project\n'

nm_mismatch_worktree="$test_tmp/nm-mismatch-worktree"
git -C "$nm_root" worktree add -q --detach "$nm_mismatch_worktree"
printf '{"lockfileVersion":3,"different":true}\n' > "$nm_mismatch_worktree/package-lock.json"
mismatch_warning="$(shipyard_link_node_modules "$nm_mismatch_worktree" 2>&1 1>/dev/null)"
case "$mismatch_warning" in
    *"package-lock.json"*"differs"*)
        printf 'ok - no-new-deps warns (but does not block) on a package-lock.json mismatch\n'
        ;;
    *)
        printf 'not ok - no-new-deps warns (but does not block) on a package-lock.json mismatch\n%s\n' \
            "$mismatch_warning" >&2
        exit 1
        ;;
esac
if [[ -L "$nm_mismatch_worktree/node_modules" ]]; then
    printf 'ok - lockfile mismatch warning does not block linking\n'
else
    printf 'not ok - lockfile mismatch warning does not block linking\n' >&2
    exit 1
fi

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
assert_equal " 💡 " \
    "$(tmux show-options -wqv -t "$intent_window" @pipeline_badge)" \
    "forge new starts in planning"
assert_equal "bash" \
    "$(tmux display-message -p -t "$intent_window" '#{pane_current_command}')" \
    "forge new starts a shell rather than an agent"
assert_equal "2" \
    "$(tmux list-panes -t "$intent_window" | wc -l | tr -d ' ')" \
    "forge new opens a two-pane layout"
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

nm_worktree_new_deps_flag="$test_tmp/nm-worktree-new-deps-flag"
git -C "$nm_root" worktree add -q --detach "$nm_worktree_new_deps_flag"
nm_worktree_shared_flag="$test_tmp/nm-worktree-shared-flag"
git -C "$nm_root" worktree add -q --detach "$nm_worktree_shared_flag"

nm_flag_target_worktree=""
treehouse() {
    case "$1" in
        get)
            printf '{"path":"%s","lease_id":"lease-nm-flag"}\n' "$nm_flag_target_worktree"
            ;;
        return)
            :
            ;;
    esac
}

nm_flag_target_worktree="$nm_worktree_new_deps_flag"
TMUX="test" shipyard_new --new-deps "flag test new deps"
if [[ ! -L "$nm_worktree_new_deps_flag/node_modules" ]]; then
    printf 'ok - forge new --new-deps leaves node_modules independent\n'
else
    printf 'not ok - forge new --new-deps leaves node_modules independent\n' >&2
    exit 1
fi

nm_flag_target_worktree="$nm_worktree_shared_flag"
TMUX="test" shipyard_new "flag test shared deps"
if [[ -L "$nm_worktree_shared_flag/node_modules" ]]; then
    printf 'ok - forge new links node_modules to root by default\n'
else
    printf 'not ok - forge new links node_modules to root by default\n' >&2
    exit 1
fi

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

npm_stub_dir="$test_tmp/npm-stub"
mkdir -p "$npm_stub_dir"
cat > "$npm_stub_dir/npm" <<'EOF'
#!/usr/bin/env bash
printf 'real-npm-called %s\n' "$*"
EOF
chmod +x "$npm_stub_dir/npm"
npm_path="$SHIPYARD_HOME/bin:$npm_stub_dir:$PATH"

npm_scenario_dir="$test_tmp/npm-scenario"
mkdir -p "$npm_scenario_dir/node_modules"
npm_out="$(cd "$npm_scenario_dir" && PATH="$npm_path" "$repo_root/bin/npm" install)"
assert_equal "real-npm-called install" "$npm_out" \
    "npm shim passes install through when node_modules is a real directory"

rm -rf "$npm_scenario_dir/node_modules"
mkdir -p "$test_tmp/npm-scenario-shared-nm"
ln -s "$test_tmp/npm-scenario-shared-nm" "$npm_scenario_dir/node_modules"

if npm_err="$(cd "$npm_scenario_dir" && PATH="$npm_path" "$repo_root/bin/npm" install 2>&1 1>/dev/null)"; then
    printf 'not ok - npm shim blocks install against a symlinked node_modules\n' >&2
    exit 1
fi
case "$npm_err" in
    *"symlinked to the root checkout"*)
        printf 'ok - npm shim blocks install against a symlinked node_modules\n'
        ;;
    *)
        printf 'not ok - npm shim blocks install against a symlinked node_modules\n%s\n' \
            "$npm_err" >&2
        exit 1
        ;;
esac

for npm_guard_args in "--silent install" "--prefix . install" "-C . ci"; do
    read -r -a npm_guard_argv <<<"$npm_guard_args"
    if npm_err="$(cd "$npm_scenario_dir" && PATH="$npm_path" "$repo_root/bin/npm" "${npm_guard_argv[@]}" 2>&1 1>/dev/null)"; then
        printf 'not ok - npm shim blocks mutating commands after global options: %s\n' \
            "$npm_guard_args" >&2
        exit 1
    fi
    case "$npm_err" in
        *"disabled in this worktree"*) ;;
        *)
            printf 'not ok - npm shim blocks mutating commands after global options: %s\n%s\n' \
                "$npm_guard_args" "$npm_err" >&2
            exit 1
            ;;
    esac
done
printf 'ok - npm shim finds mutating commands after global options\n'

npm_out2="$(cd "$npm_scenario_dir" && PATH="$npm_path" "$repo_root/bin/npm" run build)"
assert_equal "real-npm-called run build" "$npm_out2" \
    "npm shim passes non-mutating subcommands through even when node_modules is symlinked"

for npm_blocked_cmd in ci add update rm dedupe; do
    if npm_err="$(cd "$npm_scenario_dir" && PATH="$npm_path" "$repo_root/bin/npm" "$npm_blocked_cmd" 2>&1 1>/dev/null)"; then
        printf 'not ok - npm shim blocks npm %s against a symlinked node_modules\n' \
            "$npm_blocked_cmd" >&2
        exit 1
    fi
    case "$npm_err" in
        *"disabled in this worktree"*) ;;
        *)
            printf 'not ok - npm shim blocks npm %s against a symlinked node_modules\n%s\n' \
                "$npm_blocked_cmd" "$npm_err" >&2
            exit 1
            ;;
    esac
done
printf 'ok - npm shim blocks all configured mutating subcommands\n'

npm_none_dir="$test_tmp/npm-scenario-none"
mkdir -p "$npm_none_dir"
npm_out3="$(cd "$npm_none_dir" && PATH="$npm_path" "$repo_root/bin/npm" install)"
assert_equal "real-npm-called install" "$npm_out3" \
    "npm shim passes install through in a non-Node directory tree"

printf 'all tests passed\n'
