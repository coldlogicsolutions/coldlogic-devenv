#!/usr/bin/env bash
# Tests for prune-worktrees.sh, run when packages/prune-worktrees.nix builds:
#
#   bash packages/prune-worktrees-test.sh packages/prune-worktrees.sh
#
# Each case builds a throwaway repository: a bare `origin`, a main checkout
# `m` cloned from it, and worktrees in `m.worktrees/` and `m/.claude/
# worktrees/`. Activity is backdated with `touch -d`. Stubs on PATH stand in
# for gh-app (every PR in the case's stub/gh-prs, `<headRefName>
# <headRefOid> [<baseRefName>, main by default]` lines, whatever the
# arguments, so the script's own filtering is what's tested; failing when
# stub/gh-fail exists; running stub/gh-hook first when it exists; each call
# logged to stub/gh-calls), lsof (the cwds in stub/lsof-cwds; failing when
# stub/lsof-fail exists; running stub/lsof-hook <call number> first when it
# exists) and ps (a process's start time: stub/ps-<pid>, else start-<pid>;
# running stub/ps-hook first when it exists; COLDLOGIC_PRUNE_PROC points the
# script at a missing /proc so it asks ps, except in the /proc case). Needs
# git and GNU coreutils on PATH, and no network, session or credentials.
# The cases that rely on a file mode to deny access (s5, A4) are skipped
# when run as root, which ignores file modes.
set -eu

script="$(cd "$(dirname "${1:?usage: prune-worktrees-test.sh <prune-worktrees.sh>}")" && pwd)/$(basename "$1")"
if ! realpath -ms / >/dev/null 2>&1; then
  echo "prune-worktrees-test: needs GNU coreutils on PATH" >&2
  exit 1
fi
root="$(realpath -e "$(mktemp -d)")"
# $live: a `sleep` standing for a live lock owner. stop_live ends it; the
# exit trap does too, so a case that fails or aborts leaks neither it nor
# (with $root) its lock.
live=""
stop_live() {
  if [ -n "$live" ]; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
  fi
  live=""
}
cleanup() {
  stop_live
  rm -rf "$root"
}
trap cleanup EXIT

export HOME="$root/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR CLAUDECODE

stubs="$root/stubs"
mkdir -p "$stubs"
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
echo "$*" >>"$STUB_DIR/gh-calls"
[ ! -e "$STUB_DIR/gh-fail" ] || exit 1
[ ! -e "$STUB_DIR/gh-hook" ] || bash "$STUB_DIR/gh-hook"
sep=""
printf '['
while read -r name oid base; do
  printf '%s{"headRefName":"%s","headRefOid":"%s","baseRefName":"%s"}' "$sep" "$name" "$oid" "${base:-main}"
  sep=,
done <"$STUB_DIR/gh-prs"
printf ']\n'
EOF
} >"$stubs/gh-app"
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
echo "$*" >>"$STUB_DIR/lsof-args"
[ ! -e "$STUB_DIR/lsof-fail" ] || exit 1
n=$(($(cat "$STUB_DIR/lsof-count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$STUB_DIR/lsof-count"
[ ! -e "$STUB_DIR/lsof-hook" ] || bash "$STUB_DIR/lsof-hook" "$n"
printf 'p1\nfcwd\nn/\n'
if [ -f "$STUB_DIR/lsof-cwds" ]; then
  while IFS= read -r d; do printf 'p2\nfcwd\nn%s\n' "$d"; done <"$STUB_DIR/lsof-cwds"
fi
EOF
} >"$stubs/lsof"
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
pid="${!#}"
[ ! -f "$STUB_DIR/ps-hook" ] || bash "$STUB_DIR/ps-hook" >/dev/null 2>&1
if [ -f "$STUB_DIR/ps-$pid" ]; then cat "$STUB_DIR/ps-$pid"; else echo "start-$pid"; fi
EOF
} >"$stubs/ps"
chmod +x "$stubs/gh-app" "$stubs/lsof" "$stubs/ps"
# git and jq that log each call to stub/calls, for the fast path's case;
# on PATH only where a case sets $extra_path to $spies.
spies="$root/spies"
mkdir -p "$spies"
for tool in git jq; do
  real_tool="$(command -v "$tool")"
  # shellcheck disable=SC2016 # $* and $@ are the spy's own, expanded when it runs
  printf '#!%s\necho "%s $*" >>"$STUB_DIR/calls"\nexec %q "$@"\n' "$BASH" "$tool" "$real_tool" >"$spies/$tool"
  chmod +x "$spies/$tool"
done
extra_path=""
# A stat that reports another device for the path in stub/other-dev, for
# the missing-volume case; on PATH only where a case sets $extra_path.
devspy="$root/devspy"
mkdir -p "$devspy"
{
  printf '#!%s\nreal_stat=%q\n' "$BASH" "$(command -v stat)"
  cat <<'EOF'
case " $* " in
  *" %d "*)
    if [ "${!#}" = "$(cat "$STUB_DIR/other-dev" 2>/dev/null)" ]; then
      echo 999999
      exit 0
    fi
    ;;
esac
exec "$real_stat" "$@"
EOF
} >"$devspy/stat"
chmod +x "$devspy/stat"
# /proc stand-in: none, so the lock's start times come from the ps stub,
# except where a case points it at a directory of its own.
export COLDLOGIC_PRUNE_PROC="$root/no-proc"

passed=0
failed=0
n=0
code=0
out=""
err=""

# A process that has exited, for a stale lock's PID.
sh -c 'exit 0' &
dead=$!
wait "$dead"

# A new case: origin, the main checkout $main with one commit pushed, and
# origin/HEAD set. Runs go from $run_dir ($main unless a case changes it).
fresh() {
  n=$((n + 1))
  case_dir="$root/case$n"
  stub="$case_dir/stub"
  mkdir -p "$stub"
  : >"$stub/gh-prs"
  git init -q --bare -b main "$case_dir/origin.git"
  main="$case_dir/m"
  git clone -q "$case_dir/origin.git" "$main" 2>/dev/null
  printf '%s\n' '.devenv*' /.claude/worktrees/ /.claude/settings.json .mcp.json \
    node_modules/ target/ result 'result-*' '.env' .dev.vars devenv.local.nix \
    '/.claude/skills/openspec-*/' /.claude/commands/opsx >"$main/.gitignore"
  echo base >"$main/file"
  git -C "$main" add -A
  git -C "$main" commit -qm base
  git -C "$main" push -q origin main
  git -C "$main" remote set-head origin main >/dev/null
  run_dir="$main"
  stdin_file=/dev/null
}

# wt <side|claude|out> <dir name> [<branch> | --detach]: a worktree at
# origin/main, in m.worktrees/, m/.claude/worktrees/ or elsewhere; sets $w.
# The branch has no upstream, as a session's (--no-track), but a config
# section (a description).
wt() {
  case "$1" in
    side) w="$main.worktrees/$2" ;;
    claude) w="$main/.claude/worktrees/$2" ;;
    out) w="$case_dir/elsewhere/$2" ;;
  esac
  if [ "${3:-}" = --detach ]; then
    git -C "$main" worktree add -q --detach "$w" origin/main
  else
    git -C "$main" worktree add -q --no-track -b "${3:-$2}" "$w" origin/main 2>/dev/null
    git -C "$main" config "branch.${3:-$2}.description" test
  fi
}
# on_recheck <command>: runs <command> at the second lsof call, the re-check
# just before a removal, after every other check.
on_recheck() {
  # shellcheck disable=SC2016 # $1 is the hook's own
  printf '[ "$1" != 2 ] || %s\n' "$1" >"$stub/lsof-hook"
}
commit_in() {
  echo "$2" >>"$1/file"
  git -C "$1" commit -qam "$2"
}
head_of() { git -C "$1" rev-parse HEAD; }
# Merges worktree $1's HEAD into origin's main by fast-forward, and fetches.
merge_ff() {
  git -C "$1" push -q origin HEAD:main
  git -C "$main" fetch -q origin
}
# Records a merged PR: `pr <head branch> <head sha> [<base branch>]`.
pr() { echo "$1 $2 ${3:-main}" >>"$stub/gh-prs"; }
calls() { [ "$(wc -l <"$stub/gh-calls")" -eq "$1" ]; }
backdate() {
  local x gd
  for x in "$@"; do
    gd="$(git -C "$x" rev-parse --absolute-git-dir)"
    find "$gd" -exec touch -h -d '1 day ago' {} +
    if [ -d "$x/.devenv" ]; then
      find "$x/.devenv" -exec touch -h -d '1 day ago' {} +
    fi
    touch -d '1 day ago' "$x"
  done
}
backdate_branch() {
  local f
  for f in "$main/.git/logs/refs/heads/$1" "$main/.git/refs/heads/$1" "$main/.git/packed-refs"; do
    [ ! -e "$f" ] || touch -h -d '1 day ago' "$f"
  done
}

# prune [args...]: runs the script from $run_dir with the stubs, stdin from
# $stdin_file; sets $code, $out (stdout) and $err (stderr).
prune() {
  code=0
  out="$(cd "$run_dir" && PATH="${extra_path:+$extra_path:}$stubs:$PATH" STUB_DIR="$stub" bash "$script" "$@" <"$stdin_file" 2>"$case_dir/stderr")" || code=$?
  err="$(cat "$case_dir/stderr")"
}

check() {
  name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name (exit $code; out '$out'; err '$err'; worktrees: $(git -C "$main" worktree list 2>&1 | tr '\n' ';'); log: $(tr '\n' ';' <"$main/.git/coldlogic-prune.log" 2>/dev/null))"
  fi
}

not() { ! "$@"; }
listed() { git -C "$main" worktree list --porcelain | grep -qxF "worktree $1"; }
kept() { [ -d "$1" ] && listed "$1"; }
gone() { [ ! -e "$1" ] && ! listed "$1"; }
has_ref() { git -C "$main" rev-parse -q --verify "$1" >/dev/null; }
has_branch() { has_ref "refs/heads/$1"; }
has_config() { [ -n "$(git -C "$main" config --get-regexp "^branch\.$1\." 2>/dev/null || true)" ]; }
logged() { grep -qF -- "$1" "$main/.git/coldlogic-prune.log" 2>/dev/null; }
exits() { [ "$code" = "$1" ]; }
# wait_until <what> <command...>: polls for up to 30 seconds; on a timeout,
# fails with a line saying what it waited for.
wait_until() {
  local what="$1"
  shift
  for _ in $(seq 1 60); do
    ! "$@" || return 0
    sleep 0.5
  done
  failed=$((failed + 1))
  echo "FAIL timed out after 30s waiting until $what"
}
unlocked() { [ ! -e "$main/.git/coldlogic-prune.lock" ]; }
quiet() { [ -z "$out" ] && [ -z "$err" ]; }

# --- Only the project's own linked worktrees are candidates

fresh
wt out x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
prune
check "(a) outside the known locations: kept" kept "$w"
check "(a) ... exit 0, nothing printed" quiet

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
git -C "$main" worktree lock "$w"
backdate "$w"
prune
check "(b) locked: kept" kept "$w"

fresh
wt side a
wt claude b
commit_in "$w" one
merge_ff "$w"
backdate "$main.worktrees/a" "$w"
run_dir="$main.worktrees/a"
prune
check "(c) run from a linked worktree: the merged one goes" gone "$w"
check "(c) ... the run's own worktree stays" kept "$main.worktrees/a"
check "(c) ... and the main checkout stays" [ -d "$main/.git" ]

# --- A dirty worktree is never removed

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
echo new >"$w/untracked"
backdate "$w"
prune
check "(d) untracked file: kept" kept "$w"
check "(d) ... and the file survives" [ -f "$w/untracked" ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
mkdir -p "$w/.devenv/state" "$w/.devenv/profiles/developer/state/prek" "$w/node_modules/a" \
  "$w/target/debug" "$w/.claude"
echo x >"$w/.devenv/state/files.json"
echo x >"$w/.devenv/profiles/developer/state/tasks.db"
echo x >"$w/.devenv/profiles/developer/state/prek/f"
echo x >"$w/.devenv/profiles/developer/shell-x.sh"
echo x >"$w/node_modules/a/f"
echo x >"$w/target/debug/f"
echo x >"$w/.claude/settings.json"
echo x >"$w/.mcp.json"
echo x >"$w/.devenv.flake.nix"
ln -s /nix/store/00000000000000000000000000000000-x "$w/result"
ln -s /nix/store/00000000000000000000000000000000-y "$w/result-dev"
mkdir -p "$w/.claude/skills/openspec-explore" "$w/.claude/commands/opsx"
echo x >"$w/.claude/skills/openspec-explore/SKILL.md"
echo x >"$w/.claude/commands/opsx/explore.md"
backdate "$w"
prune
check "(e) only regenerable and generated ignored files, devenv's bookkeeping: removed" gone "$w"

# Nix's out-links are links into the store, and openspec writes only
# SKILL.md and command files: anything else by those names keeps it.
for f in real-result-dir real-result-x link-result link-opsx skill-other opsx-other; do
  fresh
  wt side x
  commit_in "$w" one
  merge_ff "$w"
  case "$f" in
    real-result-dir) mkdir "$w/result-2026-q3" && echo x >"$w/result-2026-q3/report" ;;
    real-result-x) echo x >"$w/result" ;;
    link-result) ln -s /home/me/data "$w/result" ;;
    link-opsx)
      mkdir -p "$w/.claude/commands" "$case_dir/mine"
      ln -s "$case_dir/mine" "$w/.claude/commands/opsx"
      ;;
    skill-other)
      mkdir -p "$w/.claude/skills/openspec-mine"
      echo x >"$w/.claude/skills/openspec-mine/SKILL.md"
      echo x >"$w/.claude/skills/openspec-mine/notes.txt"
      ;;
    opsx-other) mkdir -p "$w/.claude/commands/opsx" && echo x >"$w/.claude/commands/opsx/notes.txt" ;;
  esac
  backdate "$w"
  prune
  check "(e5) $f: kept" kept "$w"
  check "(e5) ... and why" logged "ignored files that would be lost ("
done

for f in .devenv/state/postgres/PG_VERSION .devenv/profiles/developer/state/postgres/PG_VERSION \
  sub/node_modules/a/f sub/target/f sub/result sub/.devenv.flake.nix .devenv.other \
  result-data/.dev.vars .claude/skills/openspec-x/.dev.vars; do
  fresh
  wt side x
  commit_in "$w" one
  merge_ff "$w"
  mkdir -p "$(dirname "$w/$f")"
  echo x >"$w/$f"
  backdate "$w"
  prune
  check "(e3) an ignored $f: kept" kept "$w"
  check "(e3) ... with the file" [ -f "$w/$f" ]
  check "(e3) ... and why" logged "ignored files that would be lost ("
done

for flag in --skip-worktree --assume-unchanged; do
  fresh
  wt side x
  commit_in "$w" one
  merge_ff "$w"
  git -C "$w" update-index "$flag" file
  echo hidden >>"$w/file"
  backdate "$w"
  prune
  check "(e4) a $flag file: kept" kept "$w"
  check "(e4) ... with its change" grep -qx hidden "$w/file"
  check "(e4) ... and why" logged "skip-worktree or assume-unchanged"
done

for f in .env .dev.vars devenv.local.nix; do
  fresh
  wt side x
  commit_in "$w" one
  merge_ff "$w"
  echo secret >"$w/$f"
  backdate "$w"
  prune
  check "(e2) an ignored $f: kept" kept "$w"
  check "(e2) ... with the file" [ -f "$w/$f" ]
  check "(e2) ... and why" logged "ignored files that would be lost ($f)"
done

fresh
wt side x
commit_in "$w" one
commit_in "$w" two
merge_ff "$w"
GIT_SEQUENCE_EDITOR=true git -C "$w" rebase -q -i --exec false HEAD~1 >/dev/null 2>&1 || true
backdate "$w"
backdate_branch x
prune
check "(f) rebase stopped partway, clean tree: kept" kept "$w"
check "(f) ... for the rebase" logged "rebase-merge"
check "(f) ... and the branch being rebased stays" has_branch x

fresh
wt side x
commit_in "$w" one
touch "$w/file"
backdate "$w"
gd="$(git -C "$w" rev-parse --absolute-git-dir)"
prune
check "(g) unmerged: kept" kept "$w"
check "(g) ... and its index wasn't written" [ "$(stat -c %Y "$gd/index")" -lt "$(($(date +%s) - 3600))" ]

fresh
wt side x
commit_in "$w" one
backdate "$w"
extra_path="$spies"
prune
extra_path=""
check "(g2) unmerged: kept" kept "$w"
check "(g2) ... without a status scan" not grep -qF " status " "$stub/calls"
check "(g2) ... or an ls-files one" not grep -qF " ls-files " "$stub/calls"

# --- A worktree is removed only when its work is in main

fresh
wt claude x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
sha="$(head_of "$w")"
pr x "$sha"
prune
check "(h) ancestor of origin/main, its branch a merged PR's head: removed" gone "$w"
check "(h) ... with its branch" not has_branch x
check "(h) ... logged with its commit" logged "removed worktree $w (x) at $sha; to restore: git worktree add $w $sha"
check "(h) ... and the branch's" logged "deleted branch x (was $sha); to restore: git branch x $sha"
check "(h) ... exit 0, nothing printed" quiet

fresh
wt claude x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
backdate_branch x
prune
check "(h2) ancestor of origin/main, no PR: removed" gone "$w"
check "(h2) ... but its branch stays" has_branch x
check "(h2) ... and why" logged "kept branch x: no PR merged into main has it as its head"
# Kept after the removal and again by the sweep of branches with no worktree.
check "(h2) ... once in the run" [ "$(grep -c "kept branch x:" "$main/.git/coldlogic-prune.log")" = 1 ]

# Restore commands paste safely: a path with a space, a branch with $( ).
fresh
# shellcheck disable=SC2016 # a branch name, never expanded
b='x$(touch${IFS}pwned)'
wt claude 'a b' "$b"
commit_in "$w" one
merge_ff "$w"
backdate "$w"
sha="$(head_of "$w")"
pr "$b" "$sha"
# And one kept, unmerged, at a path with $( ) too, and a branch with no
# worktree: every line naming them quotes the names (#82).
w_removed="$w"
# shellcheck disable=SC2016 # names, never expanded
b2='k$(touch${IFS}pwned2)' d2='c$(touch${IFS}pwned3)'
wt claude "$d2" "$b2"
commit_in "$w" two
w_kept="$w"
w="$w_removed"
# shellcheck disable=SC2016 # a branch name, never expanded
b3='o`touch${IFS}pwned4`'
git -C "$main" branch -q --no-track "$b3" origin/main
prune
check "(h3) a worktree and branch with shell characters: removed" gone "$w"
check "(h3) ... the kept one's line quotes its path and branch" \
  logged "kept worktree $(printf '%q (%q)' "$w_kept" "$b2"): not in"
check "(h3) ... as the branch's with no worktree" logged "kept branch $(printf %q "$b3"): moved"
check "(h3) ... and the removed one's" logged "removed worktree $(printf '%q (%q)' "$w" "$b") at $sha"
check "(h3) ... no log line has an unquoted \$( or backquote" not grep -qE '(^|[^\\])(\$\(|`)' "$main/.git/coldlogic-prune.log"
check "(h3) ... with its branch" not has_branch "$b"
check "(h3) ... the worktree's restore command quoted" \
  logged "to restore: $(printf 'git worktree add %q %q' "$w" "$sha")"
check "(h3) ... and the branch's" logged "to restore: $(printf 'git branch %q %q' "$b" "$sha")"
for l in "deleted branch" "removed worktree"; do
  cmd="$(grep -F "$l" "$main/.git/coldlogic-prune.log")"
  (cd "$main" && eval "${cmd#*to restore: }" >/dev/null 2>&1)
done
check "(h3) ... the pasted commands restore the branch" has_branch "$b"
check "(h3) ... and the worktree" listed "$w"
check "(h3) ... and run nothing else" [ ! -e "$main/pwned" ]

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
prune
check "(i) squash-merged (PR head = HEAD): removed" gone "$w"
check "(i) ... with its branch" not has_branch x
check "(i) ... asking gh-app for PRs merged into main" grep -qF -- "--state merged --base main" "$stub/gh-calls"

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")" staging
backdate "$w"
prune
check "(i2) its PR merged into another branch: kept" kept "$w"
check "(i2) ... with its branch" has_branch x

fresh
wt side x
commit_in "$w" one
pr y "$(head_of "$w")"
backdate "$w"
prune
check "(i3) a merged PR with its commit but another branch: kept" kept "$w"

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
commit_in "$w" two
backdate "$w"
prune
check "(j) a commit after the merge: kept" kept "$w"
check "(j) ... with its branch" has_branch x

fresh
wt side x
commit_in "$w" one
commit_in "$w" two
pr x "$(head_of "$w")"
git -C "$w" reset -q --keep HEAD~1
backdate "$w"
prune
check "(j2) HEAD behind the merged PR's head: removed" gone "$w"
check "(j2) ... with its branch, past origin/main and in the PR" not has_branch x

fresh
wt side x --detach
commit_in "$w" one
sha="$(head_of "$w")"
pr some-branch "$sha"
backdate "$w"
prune
check "(k) detached and squash-merged: removed" gone "$w"

fresh
wt side x --detach
commit_in "$w" one
commit_in "$w" two
pr some-branch "$(head_of "$w")"
git -C "$w" reset -q --keep HEAD~1
backdate "$w"
prune
check "(k2) detached, a merged PR's head only contains HEAD: kept" kept "$w"

# The default branch is staging: origin/HEAD, not origin/main, is main.
fresh
git -C "$main" push -q origin main:staging
git -C "$main" fetch -q origin
git -C "$main" remote set-head origin staging >/dev/null
wt side x
commit_in "$w" one
git -C "$w" push -q origin HEAD:staging
x="$w"
wt side y
commit_in "$w" two
git -C "$w" push -q origin HEAD:main
git -C "$main" fetch -q origin
y="$w"
backdate "$x" "$y"
prune
check "(k3) the default branch is staging, an ancestor of origin/staging: removed" gone "$x"
check "(k3) ... its branch kept for want of a PR into staging" logged "kept branch x: no PR merged into staging has it as its head"
check "(k3) ... an ancestor of origin/main only: kept" kept "$y"

# --- Without GitHub, only the git check is used

fresh
wt side a
wt side s1
wt claude s2
for x in "$main.worktrees/s1" "$w"; do
  commit_in "$x" "$(basename "$x")"
  pr "$(basename "$x")" "$(head_of "$x")"
done
commit_in "$main.worktrees/a" a
merge_ff "$main.worktrees/a"
touch "$stub/gh-fail"
backdate "$main.worktrees/a" "$main.worktrees/s1" "$w"
prune
check "(l) gh-app fails: exit 0" exits 0
check "(l) ... the ancestor one goes" gone "$main.worktrees/a"
check "(l) ... the squash-merged ones stay" kept "$main.worktrees/s1"
check "(l) ... both" kept "$w"
check "(l) ... after one gh-app call" [ "$(wc -l <"$stub/gh-calls")" -eq 1 ]

# --- A worktree in use is never removed

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
mkdir "$w/sub"
backdate "$w"
prune --session-dir "$w/sub"
check "(m) the session's own worktree: kept" kept "$w"
run_dir="$main.worktrees"
prune --session-dir x/sub
check "(m) ... given relative to where the run starts" kept "$w"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
echo "{\"cwd\":\"$w\"}" >"$case_dir/hook.json"
stdin_file="$case_dir/hook.json"
prune --hook
check "(m2) --hook takes the session dir from .cwd: kept" kept "$w"
check "(m2) ... nothing printed" quiet

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
echo "$w/sub" >"$stub/lsof-cwds"
prune
check "(n) a process works in it: kept" kept "$w"
check "(n) ... any user's process: lsof isn't limited to this user" grep -qx -- '-a -d cwd -Fn' "$stub/lsof-args"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
touch "$stub/lsof-fail"
prune
check "(o) lsof fails: kept" kept "$w"
check "(o) ... exit 0" exits 0

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
on_recheck "echo '$w/sub' >'$stub/lsof-cwds'"
prune
check "(o2) a process starts in it after the first lsof: kept" kept "$w"
check "(o2) ... and why" logged "a process works in it ($w/sub)"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
on_recheck "git -C '$w' commit -q --allow-empty -m late"
prune
check "(o3) HEAD moves after the checks: kept" kept "$w"
check "(o3) ... and why" logged "HEAD or its branch moved since the check"
check "(o3) ... with its branch" has_branch x

fresh
wt side x
prune
check "(p) just created at origin/main: kept" kept "$w"
check "(p) ... with its branch" has_branch x

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
mkdir -p "$w/.devenv/profiles/developer/state"
backdate "$w"
touch "$w/.devenv/profiles/developer/state"
prune
check "(q) a devenv shell's profile state touched just now: kept" kept "$w"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
mkdir -p "$w/.devenv/state"
backdate "$w"
touch "$w/.devenv/state"
prune
check "(q2) .devenv/state touched just now: kept" kept "$w"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
prune --idle-minutes 2880
check "(q3) idle, but within --idle-minutes: kept" kept "$w"
prune
check "(q3) ... and gone with the default period" gone "$w"

# --- Removal never forces

fresh
wt side x
rm -rf "$w"
prune
check "(r) half-deleted: unregistered" not listed "$w"
check "(r) ... logged" logged "unregistered worktree $w"

fresh
wt side x
inside="$w"
wt out y
rm -rf "$inside" "$w"
prune
check "(r2) a worktree elsewhere, half-deleted: still registered" listed "$w"
check "(r2) ... so git worktree prune didn't run" listed "$inside"
check "(r2) ... and says why" logged "skipped git worktree prune: $w"

fresh
wt side x
git -C "$main" worktree lock "$w"
locked_wt="$w"
wt side y
rm -rf "$locked_wt" "$w"
prune
check "(r3) a locked worktree, half-deleted: still registered" listed "$locked_wt"
check "(r3) ... not logged as unregistered" not logged "unregistered worktree $locked_wt"
check "(r3) ... but logged as locked" logged "kept worktree $locked_wt (x): locked"
check "(r3) ... and the unlocked one is unregistered" not listed "$w"

fresh
mkdir -p "$case_dir/vol/wt"
ln -s "$case_dir/vol/wt" "$main.worktrees"
wt side x
rm -rf "$case_dir/vol"
prune
check "(r4) a linked root whose volume is gone: its worktree stays registered" \
  [ "$(git -C "$main" worktree list --porcelain | grep -c '^worktree ')" = 2 ]
check "(r4) ... and says why" logged "skipped git worktree prune: the directory holding"

fresh
mkdir -p "$main.worktrees"
wt side x
rm -rf "$w"
realpath -e "$main.worktrees" >"$stub/other-dev"
extra_path="$devspy"
prune
extra_path=""
check "(r5) a root on another device, a worktree under it gone: still registered" listed "$w"
check "(r5) ... and says why" logged "isn't on the main checkout's device"

# A worktree moved by hand looks gone to git, but its admin dir holds its
# index, HEAD and HEAD reflog: git worktree prune would delete them.
fresh
wt side x
echo staged >"$w/new"
git -C "$w" add new
mv "$w" "$w-moved"
prune
check "(r6) a worktree moved by hand with a staged change: still registered" listed "$w"
check "(r6) ... its admin dir and index survive" [ -f "$main/.git/worktrees/x/index" ]
check "(r6) ... with the staged change" [ "$(git --git-dir="$main/.git/worktrees/x" diff-index --cached --name-only HEAD)" = new ]
check "(r6) ... and says why" logged "skipped git worktree prune: $w is gone, but its index in"

fresh
wt side x --detach
commit_in "$w" one
mv "$w" "$w-moved"
prune
check "(r6b) a detached worktree moved by hand, at a commit no branch holds: still registered" listed "$w"
check "(r6b) ... and says why" logged "is a commit no branch holds"

fresh
wt side x --detach
commit_in "$w" one
git -C "$w" reset -q --hard origin/main
mv "$w" "$w-moved"
prune
check "(r6c) a detached worktree moved by hand, with abandoned commits in its HEAD reflog: still registered" listed "$w"
check "(r6c) ... and says why" logged "its HEAD reflog has commits no branch holds"

fresh
wt side x
git -C "$w" checkout -q --detach
commit_in "$w" z
git -C "$w" checkout -q x 2>/dev/null
mv "$w" "$w-moved"
prune
check "(r6d) a worktree back on its branch, moved by hand, with a commit made detached: still registered" listed "$w"
check "(r6d) ... and says why" logged "its HEAD reflog has commits no branch holds"

fresh
wt side x
wt side y
rm "$w/.git"
rm -rf "$main.worktrees/x"
prune
check "(r7) a worktree whose .git file alone is gone: still registered" listed "$w"
check "(r7) ... so git worktree prune didn't run" listed "$main.worktrees/x"
check "(r7) ... and says why" logged "skipped git worktree prune: git calls $w prunable, but it's still there"
check "(r7) ... with its files" [ -f "$w/file" ]

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
on_recheck "echo late >'$w/late'"
prune
check "(s) a file written after the checks: kept" kept "$w"
check "(s) ... with the file" [ -f "$w/late" ]
check "(s) ... and its branch" has_branch x

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
on_recheck "echo secret >'$w/.dev.vars'"
prune
check "(s2) an ignored file written after the checks: kept" kept "$w"
check "(s2) ... with the file" [ -f "$w/.dev.vars" ]
check "(s2) ... and why" logged "ignored files that would be lost (.dev.vars), found just before the removal"

# A detached worktree's HEAD reflog may be all that holds work abandoned there.
fresh
wt side x --detach
commit_in "$w" abandoned
git -C "$w" reset -q --hard origin/main
backdate "$w"
prune
check "(s3) a merged detached worktree with abandoned commits in its HEAD reflog: kept" kept "$w"
check "(s3) ... and why" logged "kept worktree $w (detached): its HEAD reflog has commits no branch holds"

fresh
wt side x --detach
backdate "$w"
# Backdated again, so the activity re-check doesn't keep it first.
on_recheck "git -C '$w' commit -q --allow-empty -m late; git -C '$w' reset -q --hard origin/main; find '$main/.git/worktrees/x' -exec touch -h -d '1 day ago' {} +"
prune
check "(s4) a commit abandoned in a detached worktree after the checks: kept" kept "$w"
check "(s4) ... and why" logged "its HEAD reflog has commits no branch holds, found just before the removal"

if [ "$(id -u)" = 0 ]; then
  echo "skip (s5): root reads a file whatever its mode"
else
  fresh
  wt side x --detach
  backdate "$w"
  chmod 000 "$main/.git/worktrees/x/logs/HEAD"
  prune
  chmod 644 "$main/.git/worktrees/x/logs/HEAD"
  check "(s5) a detached worktree whose HEAD reflog can't be read: kept" kept "$w"
  check "(s5) ... and why" logged "kept worktree $w (detached): its HEAD reflog couldn't be read"
fi

# The reflog check can make the run's first PR lookup; its gh-app failure is
# logged in the log, not in a file named after the reflog's commits.
fresh
wt side x --detach
commit_in "$w" abandoned
git -C "$w" reset -q --hard origin/main
backdate "$w"
touch "$stub/gh-fail"
prune
check "(s3b) gh-app failing at the reflog check: kept" kept "$w"
check "(s3b) ... the failure logged" logged "gh-app failed: nothing counts as merged by a PR this run"
check "(s3b) ... and no stray file in the main checkout" [ -z "$(git -C "$main" status --porcelain --ignored)" ]

# On a branch too: a commit made detached, left by switching back to the
# branch, is in no branch's reflog.
fresh
wt side x
git -C "$w" checkout -q --detach
commit_in "$w" z
git -C "$w" checkout -q x 2>/dev/null
backdate "$w"
# A merged PR whose head this clone hasn't got doesn't hold it, or break the check.
pr other 0123456789abcdef0123456789abcdef01234567
prune
check "(s6) a worktree back on its branch after a commit made detached: kept" kept "$w"
check "(s6) ... and why" logged "kept worktree $w (x): its HEAD reflog has commits no branch holds"

# --- A removed worktree's branch goes with it

fresh
wt side fixx fix/x
commit_in "$w" one
git -C "$w" push -q origin fix/x
merge_ff "$w"
pr fix/x "$(head_of "$w")"
check "(t) setup: branch.fix/x config exists" has_config 'fix/x'
backdate "$w"
prune
check "(t) worktree on fix/x: removed" gone "$w"
check "(t) ... fix/x is gone" not has_branch fix/x
check "(t) ... so is its config section" not has_config 'fix/x'
check "(t) ... origin/fix/x is untouched" has_ref refs/remotes/origin/fix/x

fresh
git -C "$main" switch -q -c other
sha="$(git -C "$main" rev-parse origin/main)"
w="$main.worktrees/mm"
git -C "$main" worktree add -q "$w" main
pr main "$sha"
backdate "$w"
backdate_branch main
prune
check "(t2) a worktree on the default branch: removed" gone "$w"
check "(t2) ... but main stays" has_branch main
check "(t2) ... and why" logged "kept branch main: it's the default branch"

fresh
git -C "$main" branch -q --no-track staging origin/main
commit_in "$main" two
git -C "$main" push -q origin main
git -C "$main" fetch -q origin
w="$main.worktrees/st"
git -C "$main" worktree add -q "$w" staging
backdate "$w"
backdate_branch staging
prune
check "(t3) a worktree on a lagging staging: removed" gone "$w"
check "(t3) ... but staging stays" has_branch staging
check "(t3) ... and why" logged "kept branch staging: a long-lived branch's name"

fresh
wt side dv develop
commit_in "$w" one
pr develop "$(head_of "$w")"
backdate "$w"
prune
check "(t6) a worktree on develop, the exact head of a merged PR: removed" gone "$w"
check "(t6) ... but develop stays" has_branch develop
check "(t6) ... and why" logged "kept branch develop: a long-lived branch's name"

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
git -C "$main" config branch.x.remote origin
git -C "$main" config branch.x.merge refs/heads/x
backdate "$w"
prune
check "(t7) a worktree whose branch has an upstream: removed" gone "$w"
check "(t7) ... with the branch, the exact head of a merged PR" not has_branch x
check "(t7) ... and its config section" not has_config x

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
git -C "$main" switch -q --ignore-other-worktrees x
backdate "$w"
prune
check "(t4) a branch the main checkout also has: the worktree goes" gone "$w"
check "(t4) ... the branch stays" has_branch x
check "(t4) ... and why" logged "kept branch x: another worktree has it checked out"

fresh
wt side y
rebasing="$w"
commit_in "$w" one
commit_in "$w" two
pr y "$(head_of "$w")"
w="$main.worktrees/xx"
git -C "$main" worktree add -q -f "$w" y
GIT_SEQUENCE_EDITOR=true git -C "$rebasing" rebase -q -i --exec false HEAD~1 >/dev/null 2>&1 || true
backdate "$w" "$rebasing"
prune
check "(t5) a branch another worktree is rebasing: the worktree goes" gone "$w"
check "(t5) ... the branch stays" has_branch y
check "(t5) ... and why" logged "kept branch y: another worktree has it checked out"

# --- Merged branches without a worktree are deleted

# orphan <branch>: a branch one commit past origin/main with no worktree,
# and a config section; sets $sha.
orphan() {
  wt side "tmp-$1" "$1"
  commit_in "$w" one
  sha="$(head_of "$w")"
  git -C "$main" worktree remove "$w"
}

fresh
orphan worktree-agent-x
pr worktree-agent-x "$sha"
backdate_branch worktree-agent-x
prune
check "(u) orphaned merged branch: deleted" not has_branch worktree-agent-x
check "(u) ... with its config section" not has_config worktree-agent-x
check "(u) ... logged with its commit" logged "deleted branch worktree-agent-x (was $sha); to restore: git branch worktree-agent-x $sha"

fresh
git -C "$main" branch -q --no-track lagging origin/main
commit_in "$main" two
git -C "$main" push -q origin main
git -C "$main" fetch -q origin
backdate_branch lagging
prune
check "(u2) a lagging branch, an ancestor of origin/main: kept" has_branch lagging
check "(u2) ... and why" logged "kept branch lagging: no PR merged into main has it as its head"

# In any case too: Staging may be the same ref as staging (core.ignorecase).
for b in staging develop release/1.0 hotfix/x Staging Production Release/1.0; do
  fresh
  orphan "$b"
  pr "$b" "$sha"
  backdate_branch "$b"
  prune
  check "(u2b) $b, the exact head of a merged PR: kept" has_branch "$b"
  check "(u2b) ... and why" logged "kept branch $b: a long-lived branch's name"
done

fresh
orphan feat
pr feat "$sha"
git -C "$main" config branch.feat.remote origin
git -C "$main" config branch.feat.merge refs/heads/feat
backdate_branch feat
prune
check "(u2c) a branch with an upstream, the exact head of a merged PR: deleted" not has_branch feat
check "(u2c) ... logged with its commit" logged "deleted branch feat (was $sha); to restore: git branch feat $sha"

fresh
orphan 'feat]x'
pr 'feat]x' "$sha"
backdate_branch 'feat]x'
prune
check "(u2e) a merged branch with a ']' in its name: kept" has_branch 'feat]x'
check "(u2e) ... with its config section" has_config 'feat]x'
check "(u2e) ... and why, the name quoted" logged "kept branch feat\\]x: its name has a ']', so its config section couldn't be removed"

fresh
wt side x 'fix]y'
commit_in "$w" one
pr 'fix]y' "$(head_of "$w")"
backdate "$w"
prune
check "(u2e) a worktree on a merged branch with a ']': removed" gone "$w"
check "(u2e) ... but the branch stays" has_branch 'fix]y'
check "(u2e) ... with its config section" has_config 'fix]y'

fresh
orphan feat
pr feat "$sha"
backdate_branch feat
printf '%s\n' "git -C '$main' worktree add -q '$main.worktrees/late' feat" >"$stub/gh-hook"
prune
check "(u2d) a worktree made on the branch during the run: the branch stays" has_branch feat
check "(u2d) ... and why" logged "kept branch feat: another worktree has it checked out"

fresh
orphan worktree-agent-x
pr worktree-agent-x "$sha" staging
backdate_branch worktree-agent-x
prune
check "(u3) its PR merged into another branch: kept" has_branch worktree-agent-x

fresh
wt side tmp worktree-agent-x
commit_in "$w" one
old="$(head_of "$w")"
commit_in "$w" two
pr worktree-agent-x "$(head_of "$w")"
git -C "$w" reset -q --keep HEAD~1
git -C "$main" worktree remove "$w"
backdate_branch worktree-agent-x
prune
check "(u4) a merged PR's head only contains its tip: kept" [ "$(git -C "$main" rev-parse refs/heads/worktree-agent-x)" = "$old" ]

fresh
orphan b1
pr b1 "$sha"
orphan b2
pr b2 "$sha"
wt side s1
commit_in "$w" s1
pr s1 "$(head_of "$w")"
wt side s2
commit_in "$w" s2
pr s2 "$(head_of "$w")"
backdate_branch b1
backdate_branch b2
backdate "$main.worktrees/s1" "$w"
prune
check "(u5) several PR candidates: all go" not has_branch b1
check "(u5) ... b2" not has_branch b2
check "(u5) ... s1" gone "$main.worktrees/s1"
check "(u5) ... s2" gone "$w"
check "(u5) ... after one gh-app call" calls 1

fresh
orphan worktree-agent-x
backdate_branch worktree-agent-x
prune
check "(v) unmerged branch: kept" has_branch worktree-agent-x
prune
check "(v) ... and the reason logged once over two runs" [ "$(grep -c "kept branch worktree-agent-x" "$main/.git/coldlogic-prune.log")" = 1 ]
touch "$stub/gh-fail"
prune
check "(v) ... and again when it changes" [ "$(grep -c "kept branch worktree-agent-x" "$main/.git/coldlogic-prune.log")" = 2 ]
check "(v) ... with the gh-app failure" [ "$(grep -c "gh-app failed" "$main/.git/coldlogic-prune.log")" = 1 ]
prune
check "(v) ... which isn't repeated either" [ "$(grep -c "gh-app failed" "$main/.git/coldlogic-prune.log")" = 1 ]

fresh
orphan worktree-agent-x
backdate_branch worktree-agent-x
pr other "$sha"
export COLDLOGIC_PRUNE_PR_LIMIT=1
prune
prune
unset COLDLOGIC_PRUNE_PR_LIMIT
check "(v2) as many merged PRs as the limit: logged" logged "gh-app returned 1 merged PRs, its limit"
check "(v2) ... once over two runs" [ "$(grep -c "its limit" "$main/.git/coldlogic-prune.log")" = 1 ]
check "(v2) ... after a gh-app call each" calls 2

fresh
git -C "$main" branch -q fresh origin/main
prune
check "(w) branch just created at origin/main: kept" has_branch fresh

fresh
orphan worktree-agent-x
pr worktree-agent-x "$sha"
backdate_branch worktree-agent-x
other="$(git -C "$main" rev-parse origin/main)"
echo "git -C '$main' update-ref refs/heads/worktree-agent-x $other" >"$stub/gh-hook"
prune
check "(x) branch moved after the check: kept" [ "$(git -C "$main" rev-parse refs/heads/worktree-agent-x)" = "$other" ]

fresh
git -C "$main" switch -q -c other
backdate_branch main
prune
check "(y) the default branch, checked out nowhere: kept" has_branch main
check "(y) ... and why" logged "kept branch main: it's the default branch"

# --- A dry run changes nothing

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
prune --dry-run
check "(z) dry run: prints the worktree, and its branch that would go with it" [ "$out" = "worktree $w (x)"$'\n'"branch x" ]
check "(z) ... leaves the worktree" kept "$w"
check "(z) ... its branch" has_branch x
check "(z) ... and its config" has_config x
check "(z) ... and writes no lock, stamp or log" [ -z "$(find "$main/.git" -maxdepth 1 -name 'coldlogic-prune*')" ]

fresh
orphan worktree-agent-x
pr worktree-agent-x "$sha"
backdate_branch worktree-agent-x
prune --dry-run
check "(z2) dry run: prints the branch" [ "$out" = "branch worktree-agent-x" ]
check "(z2) ... and keeps it" has_branch worktree-agent-x

# --- Runs are rate-limited and serialised

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
sleep 300 &
live=$!
mkdir "$main/.git/coldlogic-prune.lock"
echo "$live" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(A) another run holds the lock: exit 0" exits 0
check "(A) ... and changes nothing" kept "$w"
touch -d '2 hours ago' "$main/.git/coldlogic-prune.lock"
prune
check "(A) ... nor when the live owner's lock is over an hour old" kept "$w"
check "(A) ... whose lock stays" [ "$(cat "$main/.git/coldlogic-prune.lock/pid")" = "$live" ]
check "(A) ... and the skip is logged" logged "skipped: run $live has held the lock for over an hour"
prune
check "(A) ... once" [ "$(grep -c "has held the lock" "$main/.git/coldlogic-prune.log")" = 1 ]
printf '%s\n%s\n' "$live" "lstart:start-$live" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(A) ... the owner's recorded start time matches: still kept" kept "$w"
printf '%s\n%s\n' "$live" "ticks:1" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(A) ... a start time from another source isn't compared: still kept" kept "$w"
printf '%s\n%s\n' "$live" "lstart:an earlier process" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(A) ... a reused pid (another start time): taken over" gone "$w"
check "(A) ... and released" [ ! -e "$main/.git/coldlogic-prune.lock" ]

# The same with /proc: a stand-in whose stat has the start time, field 22,
# after a command name with a space and a parenthesis in it.
fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
mkdir -p "$stub/proc/$live"
echo "$live (sle ep) x) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 4242 20 21" >"$stub/proc/$live/stat"
mkdir "$main/.git/coldlogic-prune.lock"
printf '%s\n%s\n' "$live" "ticks:4242" >"$main/.git/coldlogic-prune.lock/pid"
COLDLOGIC_PRUNE_PROC="$stub/proc" prune
check "(A3) /proc: the owner's start time matches: kept" kept "$w"
printf '%s\n%s\n' "$live" "ticks:17" >"$main/.git/coldlogic-prune.lock/pid"
COLDLOGIC_PRUNE_PROC="$stub/proc" prune
check "(A3) ... a reused pid (other start ticks): taken over" gone "$w"
stop_live

if [ "$(id -u)" = 0 ]; then
  echo "skip (A4): root writes a file whatever its mode"
else
  fresh
  wt side x
  commit_in "$w" one
  merge_ff "$w"
  backdate "$w"
  # The lock is made read-only, so its owner can't be written. The log is
  # made first, so the umask doesn't make it read-only too.
  touch "$main/.git/coldlogic-prune.log"
  umask_was="$(umask)"
  umask 0277
  prune
  umask "$umask_was"
  check "(A4) the lock's owner can't be written: exit 0" exits 0
  check "(A4) ... nothing removed" kept "$w"
  check "(A4) ... the lock removed again" [ ! -e "$main/.git/coldlogic-prune.lock" ]
  check "(A4) ... and logged" logged "skipped: couldn't write the lock's owner"
  rm -f "$case_dir/stderr"
  echo again >>"$main/.git/coldlogic-prune.log"
  umask 0277
  prune
  umask "$umask_was"
  check "(A4) ... the second run skips too" exits 0
  check "(A4) ... and records why" grep -q $'^lock-write\t' "$main/.git/coldlogic-prune.kept"
  check "(A4) ... logged once over two runs" [ "$(grep -c "couldn't write the lock's owner" "$main/.git/coldlogic-prune.log")" = 1 ]
fi

# The worktree list is read under the lock: a worktree removed while this
# run waited for it (here, from the ps stub, called once the first read is
# done) isn't a candidate.
fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
printf "git -C '%s' worktree remove '%s'\nrm -f '%s'\n" "$main" "$w" "$stub/ps-hook" >"$stub/ps-hook"
prune
check "(A5) a worktree removed before the lock is taken: exit 0" exits 0
check "(A5) ... not judged from the earlier list" not logged "kept worktree $w"
check "(A5) ... and the ps stub ran" [ ! -e "$stub/ps-hook" ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
mkdir "$main/.git/coldlogic-prune.lock"
prune
check "(A2) a lock naming no owner, just made: kept" kept "$w"
touch -d '2 hours ago' "$main/.git/coldlogic-prune.lock"
prune
check "(A2) ... over an hour old: taken over" gone "$w"
check "(A2) ... and released" [ ! -e "$main/.git/coldlogic-prune.lock" ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
mkdir "$main/.git/coldlogic-prune.lock"
echo "$dead" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(B) stale lock (its process has exited): pruned" gone "$w"
check "(B) ... and released" [ ! -e "$main/.git/coldlogic-prune.lock" ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
mkdir "$main/.git/coldlogic-prune.lock" "$main/.git/coldlogic-prune.lock.takeover"
echo "$dead" >"$main/.git/coldlogic-prune.lock/pid"
prune
check "(B2) a stale lock another run is taking over: exit 0" exits 0
check "(B2) ... and changes nothing" kept "$w"
check "(B2) ... nor the lock" [ "$(cat "$main/.git/coldlogic-prune.lock/pid")" = "$dead" ]
touch -d '2 minutes ago' "$main/.git/coldlogic-prune.lock.takeover"
prune
check "(B2) ... a takeover over a minute old is broken: pruned" gone "$w"
check "(B2) ... and the lock released" [ ! -e "$main/.git/coldlogic-prune.lock" ]
check "(B2) ... with the takeover" [ ! -e "$main/.git/coldlogic-prune.lock.takeover" ]

fresh
wt side x
commit_in "$w" one
pr x "$(head_of "$w")"
backdate "$w"
echo "echo other >'$main/.git/coldlogic-prune.lock/pid'" >"$stub/gh-hook"
prune
check "(B3) a lock taken over mid-run: the run still prunes" gone "$w"
check "(B3) ... but leaves the new owner's lock" [ "$(cat "$main/.git/coldlogic-prune.lock/pid")" = other ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
(cd "$main" && PATH="$stubs:$PATH" STUB_DIR="$stub" bash "$script" </dev/null >"$case_dir/out1" 2>&1) &
p1=$!
(cd "$main" && PATH="$stubs:$PATH" STUB_DIR="$stub" bash "$script" </dev/null >"$case_dir/out2" 2>&1) &
p2=$!
c1=0
c2=0
wait "$p1" || c1=$?
wait "$p2" || c2=$?
check "(C) two runs at once: both exit 0" [ "$c1$c2" = 00 ]
check "(C) ... the worktree is gone" gone "$w"
check "(C) ... removed once" [ "$(grep -c "removed worktree" "$main/.git/coldlogic-prune.log")" = 1 ]
check "(C) ... no lock is left" [ ! -e "$main/.git/coldlogic-prune.lock" ]

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
touch "$main/.git/coldlogic-prune.stamp"
prune --background
sleep 2
check "(D) --background within 10 minutes of the last run: exit 0" exits 0
check "(D) ... nothing printed" quiet
check "(D) ... and no run" kept "$w"

fresh
wt side x
touch "$main/.git/coldlogic-prune.stamp"
echo "{\"cwd\":\"$main\"}" >"$case_dir/hook.json"
stdin_file="$case_dir/hook.json"
extra_path="$spies"
export CLAUDE_PROJECT_DIR="$main"
prune --hook --background
check "(D3) the Stop hook, the stamp fresh: exit 0" exits 0
check "(D3) ... nothing printed" quiet
check "(D3) ... without running git or jq" [ ! -e "$stub/calls" ]
export CLAUDE_PROJECT_DIR="$w"
echo "{\"cwd\":\"$w/sub\"}" >"$case_dir/hook.json"
prune --hook --background
check "(D3) ... nor from a linked worktree" [ ! -e "$stub/calls" ]
# A .cwd outside the project dir: the run acts on .cwd's repository, so
# the project's fresh stamp doesn't count, and the full lookup runs.
export CLAUDE_PROJECT_DIR="$main"
git init -q "$case_dir/other"
touch "$case_dir/other/.git/coldlogic-prune.stamp"
echo "{\"cwd\":\"$case_dir/other\"}" >"$case_dir/hook.json"
prune --hook --background
check "(D3) ... a .cwd outside the project dir: exit 0" exits 0
check "(D3) ... takes the full lookup" grep -q "git -C $case_dir/other rev-parse" "$stub/calls"
rm -f "$stub/calls"
unset CLAUDE_PROJECT_DIR
stdin_file=/dev/null
rm "$main/.git/coldlogic-prune.stamp"
prune --session-dir "$w" --background
check "(D3) ... a stale stamp: git runs" [ -s "$stub/calls" ]
extra_path=""
wait_until "(D3)'s detached run releases the lock" unlocked

fresh
sleep 300 &
live=$!
mkdir "$main/.git/coldlogic-prune.lock"
echo "$live" >"$main/.git/coldlogic-prune.lock/pid"
prune --background
sleep 1
check "(D2) --background stamps the start, though its run can't finish" [ -e "$main/.git/coldlogic-prune.stamp" ]
stop_live

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
start="$(date +%s)"
prune --background
took=$(($(date +%s) - start))
check "(E) --background: exit 0" exits 0
check "(E) ... at once" [ "$took" -le 2 ]
check "(E) ... nothing printed" quiet
check "(E) ... stamped at launch" [ -e "$main/.git/coldlogic-prune.stamp" ]
wait_until "(E)'s detached run logs its removal" logged "removed worktree $w"
check "(E) ... and the detached run prunes" gone "$w"
wait_until "(E)'s detached run releases the lock" unlocked
check "(E) ... and finishes" unlocked

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
prune
check "(F) a manual run prunes and leaves a stamp" [ -e "$main/.git/coldlogic-prune.stamp" ]
wt side y
commit_in "$w" one
merge_ff "$w"
backdate "$w"
prune
check "(F) a manual run within 10 minutes of the stamp still prunes" gone "$w"

fresh
wt side x
commit_in "$w" one
merge_ff "$w"
backdate "$w"
pr x "$(head_of "$w")"
logf="$main/.git/coldlogic-prune.log"
echo "2000-01-01T00:00:00Z removed worktree /old (old) at 1234; to restore: git worktree add /old 1234" >"$logf"
for i in $(seq 1 1500); do echo "2000-01-01T00:00:00Z kept filler $i"; done >>"$logf"
prune
check "(I) the log is cut: removals stay" logged "removed worktree /old (old)"
check "(I) ... with this run's" logged "removed worktree $w (x)"
check "(I) ... and the last 1000 other lines" [ "$(grep -c "kept filler" "$logf")" = 1000 ]
check "(I) ... the newest of them" logged "kept filler 1500"
check "(I) ... in order" [ "$(head -n 1 "$logf")" = "2000-01-01T00:00:00Z removed worktree /old (old) at 1234; to restore: git worktree add /old 1234" ]

# --- Never writes through a link (#82)

# A session in the sandbox can write the common dir; the run, outside it,
# must not follow what it plants there. $target stands for ~/.zshrc.
target="$root/target"
# merged_wt <name>: a merged, clean, idle worktree in m.worktrees/; sets $w.
merged_wt() {
  wt side "$1"
  commit_in "$w" one
  merge_ff "$w"
  backdate "$w"
}
# The target, with more than 1000 lines, so a trim would rewrite the log.
plant_target() {
  {
    echo precious
    for i in $(seq 1 1100); do echo "line $i"; done
  } >"$target"
  cp "$target" "$case_dir/target.orig"
}
untouched() { [ "$(cat "$target")" = "$(cat "$case_dir/target.orig")" ]; }
no_tmp_left() { [ -z "$(find "$main/.git" -maxdepth 1 -name 'coldlogic-prune.*.??????')" ]; }

# A log that can't be used: no removal (it couldn't be recorded), one line on
# stderr, exit 0. A dry run writes nothing, so it still lists.
one_line_err() { [ -z "$out" ] && [ -n "$err" ] && [ "$(wc -l <"$case_dir/stderr")" -eq 1 ]; }

fresh
merged_wt x
plant_target
ln -s "$target" "$main/.git/coldlogic-prune.log"
prune
check "(K) the log a link: exit 0, nothing removed" kept "$w"
check "(K) ... one line on stderr, nothing on stdout" one_line_err
check "(K) ... the link's target untouched" untouched
check "(K) ... and the log still the link, not a copy of it" [ -L "$main/.git/coldlogic-prune.log" ]
prune --dry-run
check "(K) ... a dry run still lists it" grep -qF "worktree $w" <<<"$out"
# --background: no detached run at all, so nothing is sent through the link.
rm -f "$main/.git/coldlogic-prune.stamp"
prune --background
check "(K) ... --background: exit 0, one line on stderr" one_line_err
# Time for a wrongly detached run to have done its work.
sleep 2
check "(K) ... no detached run: nothing removed" kept "$w"
check "(K) ... and no lock taken" unlocked
check "(K) ... the link's target still untouched" untouched
check "(K) ... and no temporary file left" no_tmp_left

# Dangling links for the stamp and the kept file: the run prunes and makes
# nothing at their targets. A dangling log can't be used (K2b).
fresh
merged_wt x
ln -s "$case_dir/new-stamp" "$main/.git/coldlogic-prune.stamp"
ln -s "$case_dir/new-kept" "$main/.git/coldlogic-prune.kept"
prune
check "(K2) dangling links for the stamp and kept file: the run prunes" gone "$w"
check "(K2) ... makes no file where the stamp's points" [ ! -e "$case_dir/new-stamp" ]
check "(K2) ... nor the kept file's" [ ! -e "$case_dir/new-kept" ]
own_kept_file() { [ -f "$main/.git/coldlogic-prune.kept" ] && [ ! -L "$main/.git/coldlogic-prune.kept" ]; }
check "(K2) ... and replaces the kept file's link with its own file" own_kept_file

fresh
merged_wt x
ln -s "$case_dir/new-log" "$main/.git/coldlogic-prune.log"
prune
check "(K2b) the log a dangling link: nothing removed" kept "$w"
check "(K2b) ... one line on stderr" one_line_err
check "(K2b) ... and no file made where it points" [ ! -e "$case_dir/new-log" ]

fresh
merged_wt x
plant_target
ln "$target" "$main/.git/coldlogic-prune.log"
prune
check "(K3) the log a hard link: nothing removed" kept "$w"
check "(K3) ... one line on stderr" one_line_err
check "(K3) ... and the other name's file untouched" untouched

for kind in fifo dir; do
  fresh
  merged_wt x
  case "$kind" in
    fifo) mkfifo "$main/.git/coldlogic-prune.log" ;;
    dir) mkdir "$main/.git/coldlogic-prune.log" ;;
  esac
  code=0
  # Under a timeout: opening a FIFO to append blocks until a reader comes.
  (cd "$run_dir" && PATH="$stubs:$PATH" STUB_DIR="$stub" timeout 60 bash "$script" \
    </dev/null >"$case_dir/out" 2>&1) || code=$?
  check "(K4) the log a $kind: exit 0" exits 0
  check "(K4) ... one line printed" [ "$(wc -l <"$case_dir/out")" -eq 1 ]
  check "(K4) ... and nothing removed" kept "$w"
done

# Another run's trim renames a new file over the log after this run opened
# it: the run's lines still reach the log at its path.
fresh
merged_wt x
logf="$main/.git/coldlogic-prune.log"
on_recheck "cp $logf $logf.new && mv -f $logf.new $logf"
prune
check "(K11) the log replaced mid-run: the run removes the worktree" gone "$w"
check "(K11) ... and its removal is in the log at the path" logged "removed worktree $w"
check "(K11) ... its intent written before it" logged "removing worktree $w"

# The log becomes unusable (a hard link) after the checks, before the
# removal: no record can be written, so nothing is removed.
fresh
merged_wt x
plant_target
logf="$main/.git/coldlogic-prune.log"
on_recheck "rm -f $logf && ln $target $logf"
prune
check "(K13) the log unusable just before a removal: exit 0" exits 0
check "(K13) ... the worktree kept" kept "$w"
check "(K13) ... with its branch" has_branch x
check "(K13) ... and the other name's file untouched" untouched

# A stamp that is a link counts as none: --background runs and replaces it.
fresh
merged_wt x
printf 'x\n' >"$target"
ln -s "$target" "$main/.git/coldlogic-prune.stamp"
prune --background
check "(K14) the stamp a link, fresh target: --background isn't skipped, replaces the link" \
  not [ -L "$main/.git/coldlogic-prune.stamp" ]
wait_until "(K14)'s detached run removes $w" not [ -e "$w" ]
wait_until "(K14)'s detached run releases the lock" unlocked

# The kept file a link to a file the sandbox can't read: a run skipped for
# an old lock writes the last run's reasons back, which would copy it.
fresh
merged_wt x
printf 'secret-key\tsecret-value\n' >"$target"
cp "$target" "$case_dir/target.orig"
ln -s "$target" "$main/.git/coldlogic-prune.kept"
sleep 300 &
live=$!
mkdir "$main/.git/coldlogic-prune.lock"
echo "$live" >"$main/.git/coldlogic-prune.lock/pid"
touch -d '2 hours ago' "$main/.git/coldlogic-prune.lock"
prune
check "(K5) the kept file a link, a run skipped for an old lock: exit 0" exits 0
check "(K5) ... the link's target untouched" untouched
check "(K5) ... and not copied into the kept file" not grep -qF secret "$main/.git/coldlogic-prune.kept"
check "(K5) ... nor the log" not logged secret
stop_live

# Free text in a log line (a git error, a lock's owner): readable, with its
# spaces unescaped, and no live $( ) or backquote.
fresh
merged_wt x
sleep 300 &
live=$!
# shellcheck disable=SC2016 # the owner's text, never expanded
printf '%s-a $(touch pwned) `x`\n' "$live" >"$main/.git/coldlogic-prune.lock.owner"
mkdir "$main/.git/coldlogic-prune.lock"
mv "$main/.git/coldlogic-prune.lock.owner" "$main/.git/coldlogic-prune.lock/pid"
touch -d '2 hours ago' "$main/.git/coldlogic-prune.lock"
prune
check "(K12) a lock owner with spaces, a \$( ) and backquotes: logged readably" \
  logged "skipped: run $live-a \$ (touch pwned) 'x' has held the lock for over an hour"
check "(K12) ... no unquoted \$( or backquote in the log" not grep -qE '(^|[^\\])(\$\(|`)' "$main/.git/coldlogic-prune.log"
stop_live

# The lock's pid a link to a file whose first line names a live process:
# read through, it would keep an old lock and log that line.
fresh
merged_wt x
sleep 300 &
live=$!
printf '%s-secret\nsecret-start\n' "$live" >"$target"
cp "$target" "$case_dir/target.orig"
mkdir "$main/.git/coldlogic-prune.lock"
ln -s "$target" "$main/.git/coldlogic-prune.lock/pid"
touch -h -d '2 hours ago' "$main/.git/coldlogic-prune.lock/pid"
touch -d '2 hours ago' "$main/.git/coldlogic-prune.lock"
prune
check "(K7) the lock's pid a link, the lock 2 hours old: taken over as ownerless" gone "$w"
check "(K7) ... exit 0, nothing printed" quiet
check "(K7) ... the link's target untouched" untouched
check "(K7) ... not logged" not logged secret
check "(K7) ... and the lock released" unlocked
stop_live
fresh
merged_wt x
printf 'secret\n' >"$target"
cp "$target" "$case_dir/target.orig"
mkdir "$main/.git/coldlogic-prune.lock"
ln -s "$target" "$main/.git/coldlogic-prune.lock/pid"
prune
check "(K7) ... a fresh lock so: kept, exit 0" exits 0
check "(K7) ... the worktree waits" kept "$w"
check "(K7) ... the link's target untouched" untouched
check "(K7) ... and the lock left" [ -L "$main/.git/coldlogic-prune.lock/pid" ]

# mktemp failing, with a log long enough to trim: the rewrite gives up
# without killing its writer, so the run still exits 0.
fresh
merged_wt x
logf="$main/.git/coldlogic-prune.log"
pad="$(printf '%0300d' 0)"
for i in $(seq 1 1500); do echo "2000-01-01T00:00:00Z kept filler $i $pad"; done >"$logf"
mkdir -p "$case_dir/no-mktemp"
printf '#!%s\nexit 1\n' "$BASH" >"$case_dir/no-mktemp/mktemp"
chmod +x "$case_dir/no-mktemp/mktemp"
extra_path="$case_dir/no-mktemp"
prune
extra_path=""
check "(K8) mktemp fails, the log over 1000 lines: exit 0" exits 0
check "(K8) ... nothing printed" quiet
check "(K8) ... the run prunes" gone "$w"
check "(K8) ... and logs it" logged "removed worktree $w"
check "(K8) ... the log left untrimmed" [ "$(grep -c "kept filler" "$logf")" = 1500 ]
check "(K8) ... and no temporary file left" no_tmp_left

# Hard links for the stamp and the kept file: neither is touched or
# written through, and each is replaced with a file of the run's own.
fresh
merged_wt x
printf 'secret-key\tsecret-value\n' >"$target"
touch -d '2 days ago' "$target"
cp -p "$target" "$case_dir/target.orig"
target_time="$(stat -c %Y "$target")"
ln "$target" "$main/.git/coldlogic-prune.stamp"
ln "$target" "$main/.git/coldlogic-prune.kept"
prune
one_name() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %h "$1")" = 1 ]; }
check "(K9) the stamp and kept file hard links: the run prunes" gone "$w"
check "(K9) ... the other name's file untouched" untouched
check "(K9) ... nor its time" [ "$(stat -c %Y "$target")" = "$target_time" ]
check "(K9) ... the stamp now a file of its own" one_name "$main/.git/coldlogic-prune.stamp"
check "(K9) ... so is the kept file" one_name "$main/.git/coldlogic-prune.kept"
check "(K9) ... without the other file's lines" not grep -qF secret "$main/.git/coldlogic-prune.kept"

# shellcheck disable=SC2016 # the script's text, never expanded
check "(K6) no file is written at a predictable temporary name" not grep -qF '.tmp.$$' "$script"

# --- Not a git repository, bad usage

fresh
mkdir "$case_dir/plain"
run_dir="$case_dir/plain"
prune
check "(G) not a git repository: exit 0" exits 0
check "(G) ... nothing printed" quiet
echo "{\"cwd\":\"$case_dir/plain\"}" >"$case_dir/hook.json"
stdin_file="$case_dir/hook.json"
prune --hook --background
check "(G) --hook --background there: exit 0" exits 0
check "(G) ... nothing printed" quiet

fresh
prune --bogus
check "(H) unknown option: exit 2" exits 2
prune --idle-minutes abc
check "(H) non-numeric --idle-minutes: exit 2" exits 2
# Bash arithmetic reads 010 as octal 8 and fails on 08.
prune --idle-minutes 08
check "(H) --idle-minutes 08: exit 2" exits 2
prune --idle-minutes 010
check "(H) --idle-minutes 010: exit 2" exits 2
prune --idle-minutes 0
check "(H) --idle-minutes 0: accepted" exits 0
# More than 6 digits could overflow minutes * 60.
prune --idle-minutes 1000000
check "(H) --idle-minutes 1000000: exit 2" exits 2
prune --idle-minutes 999999
check "(H) --idle-minutes 999999: accepted" exits 0

# Bash before 4.4 rejects "${a[@]}" of an empty array under set -u, so every
# array expansion in the script is guarded: ${a[@]+"${a[@]}"}.
unguarded="$(sed -E 's/\$\{[a-z_]+\[@\]\+"\$\{!?[a-z_]+\[@\]\}"\}//g' "$script" | grep -nE '"\$\{!?[a-z_]+\[@\]\}"' || true)"
check "(H) no unguarded array expansion" [ -z "$unguarded" ]

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
