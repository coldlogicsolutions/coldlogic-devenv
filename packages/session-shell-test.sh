#!/usr/bin/env bash
# Tests for session-shell.sh, run when packages/session-shell.nix builds:
#
#   bash packages/session-shell-test.sh packages/session-shell.sh
#
# Needs no sandbox or session, but does need git and GNU coreutils on PATH.
# Each run of the script gets a clean environment (env -i), so the caller's
# session variables can't leak in. A read-only directory stands in for one
# the sandbox protects.
set -eu

script="$(cd "$(dirname "${1:?usage: session-shell-test.sh <session-shell.sh>}")" && pwd)/$(basename "$1")"
root="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  chmod -R u+w "$root" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT

# The git this file runs itself: no user or system configuration.
export HOME="$root/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CEILING_DIRECTORIES="$root"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME"

passed=0
failed=0
n=0
code=0
out=""
err=""
root_user=""
[ "$(id -u)" != 0 ] || root_user=1

fresh() {
  n=$((n + 1))
  case_dir="$root/case$n"
  mkdir -p "$case_dir"
  cd "$case_dir"
}

# run [VAR=value...] -- <args...>: runs the script with only those variables
# set, and sets $code, $out (stdout) and $err (stderr).
run() {
  local vars=()
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  code=0
  env -i PATH="$PATH" HOME="$root/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CEILING_DIRECTORIES="$root" ${vars[@]+"${vars[@]}"} \
    bash "$script" "$@" >"$root/.out" 2>"$root/.err" || code=$?
  out="$(cat "$root/.out")"
  err="$(cat "$root/.err")"
}

check() {
  name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name (exit $code; out '$out'; err '$err')"
  fi
}

exits() { [ "$code" = "$1" ]; }
silent() { [ -z "$out" ] && [ -z "$err" ]; }
# printed <text>: exit 0, <text> on stderr and nothing on stdout.
printed() { [ "$code" = 0 ] && [ -z "$out" ] && [ "$err" = "$1" ]; }
quiet() { [ "$code" = 0 ] && silent; }
err_has() { case "$err" in *"$1"*) return 0 ;; *) return 1 ;; esac }
err_lacks() { ! err_has "$1"; }
# one_line: exit 0, nothing on stdout, one line on stderr.
one_line() { [ "$code" = 0 ] && [ -z "$out" ] && [ -n "$err" ] && [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ]; }

# --- own-checkout ---------------------------------------------------------

fresh
A="$case_dir/A"
B="$case_dir/B"
mkdir -p "$A" "$B"
ln -s "$A" "$case_dir/linkA"

run COLDLOGIC_SESSION_ROOT="$A" DEVENV_ROOT="$B" -- own-checkout
check "(a) not a session: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 DEVENV_ROOT="$B" -- own-checkout
check "(b) no session root: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT= DEVENV_ROOT="$B" -- own-checkout
check "(b2) empty session root: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$A" DEVENV_ROOT="$A" -- own-checkout
check "(c) same checkout: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$case_dir/linkA" DEVENV_ROOT="$A/" -- own-checkout
check "(d) same checkout through a link and a trailing slash: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$A" DEVENV_ROOT="$B" -- own-checkout
check "(e) another checkout: exit 10" exits 10
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$root/none" DEVENV_ROOT="$B" -- own-checkout
check "(f) session root doesn't resolve: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$B" DEVENV_ROOT="$root/none" -- own-checkout
check "(f2) devenv root doesn't resolve: exit 0" exits 0
check "(h) ... and silent" silent
run CLAUDECODE=1 COLDLOGIC_SESSION_ROOT="$A" -- own-checkout
check "(g) no devenv root: exit 0" exits 0
check "(h) ... and silent" silent
# The session test is devenv.nix's `inSession`: the wrapper's marker alone
# counts, an empty one doesn't.
run COLDLOGIC_DEVENV_SESSION=1 COLDLOGIC_SESSION_ROOT="$A" DEVENV_ROOT="$B" -- own-checkout
check "(e2) the wrapper's marker alone is a session: exit 10" exits 10
check "(h) ... and silent" silent
run COLDLOGIC_DEVENV_SESSION= CLAUDECODE= COLDLOGIC_SESSION_ROOT="$A" DEVENV_ROOT="$B" -- own-checkout
check "(a2) both variables empty: not a session, exit 0" exits 0
check "(h) ... and silent" silent

# --- notice and clear -----------------------------------------------------

S="$case_dir/S"
rec="$S/coldlogic-notices/k"
s1=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$S")
s2=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s2 DEVENV_STATE="$S")
noid=(CLAUDECODE=1 DEVENV_STATE="$S")

run DEVENV_STATE="$S" -- notice k hello
check "(i) not a session: prints" printed hello
run DEVENV_STATE="$S" -- notice k hello
check "(i) ... and prints again" printed hello
check "(i) ... and records nothing" [ ! -e "$S/coldlogic-notices" ]

run "${s1[@]}" -- notice k hello
check "(j) first in a session: prints" printed hello
run "${s1[@]}" -- notice k hello
check "(j) ... then silent" quiet

run "${s1[@]}" -- notice k "hello two"
check "(k) new text: prints" printed "hello two"
run "${s1[@]}" -- notice k "hello two"
check "(k) ... then silent" quiet
run "${s1[@]}" -- notice k hello
check "(k) ... the old text back: prints" printed hello

run "${s2[@]}" -- notice k hello
check "(l) another session: prints" printed hello
run "${s2[@]}" -- notice k hello
check "(l) ... then silent" quiet

run "${noid[@]}" -- notice k hello
check "(m) no session id: prints" printed hello
run "${noid[@]}" -- notice k hello
check "(m) ... then silent" quiet
run "${s1[@]}" -- notice k hello
check "(m) ... then with s1: prints" printed hello
run "${s1[@]}" -- notice k hello
check "(m) ... then silent" quiet

# A session the wrapper started, with its marker and no CLAUDECODE, is a
# session here too: once per session.
run COLDLOGIC_DEVENV_SESSION=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$S" -- notice w hello
check "(m2) the wrapper's marker alone: prints" printed hello
run COLDLOGIC_DEVENV_SESSION=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$S" -- notice w hello
check "(m2) ... then silent" quiet

run "${s1[@]}" -- clear k
check "(n) clear: exit 0, no output" quiet
run "${s1[@]}" -- notice k hello
check "(n) ... the notice prints again" printed hello
run "${s1[@]}" -- clear never-written
check "(n) clear of a key never written: exit 0, no output" quiet

printf '' >"$rec"
run "${s1[@]}" -- notice k hello
check "(p) empty record: prints" printed hello
run "${s1[@]}" -- notice k hello
check "(p) ... then silent" quiet
printf 's1\n' >"$rec"
run "${s1[@]}" -- notice k hello
check "(p) record of only the session line: prints" printed hello
run "${s1[@]}" -- notice k hello
check "(p) ... then silent" quiet

run "${s1[@]}" -- notice k $'one\ntwo'
check "(q) two-line text: prints both lines" printed $'one\ntwo'
run "${s1[@]}" -- notice k $'one\ntwo'
check "(q) ... then silent" quiet
run "${s1[@]}" -- notice k $'ends\n\n'
check "(q2) text ending in newlines: prints" printed ends
check "(q2) ... once, with one newline" [ "$(wc -l <"$root/.err")" -eq 1 ]
run "${s1[@]}" -- notice k $'ends\n\n'
check "(q2) ... then silent" quiet
run "${s1[@]}" -- notice k ends
check "(q2) ... and the same text without them is silent too" quiet

check "(t) no temporary file is left" [ -z "$(find "$S/coldlogic-notices" -name '.*')" ]

run "${s1[@]}" -- notice a t
check "(u) key a: prints" printed t
run "${s1[@]}" -- notice b t
check "(u) key b, same text: prints" printed t

run CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$case_dir/S2" -- notice a t
check "(v) another state directory: prints" printed t

run CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_ROOT="$B" -- notice k hello
check "(r) no DEVENV_STATE: prints" printed hello
check "(r) ... the record is under DEVENV_ROOT/.devenv/state" \
  [ "$(cat "$B/.devenv/state/coldlogic-notices/k")" = $'s1\nhello' ]

touch "$S/x"
for args in "notice" "notice k" "notice k t extra" "notice ../x t" "notice a/b t" \
  "notice -x t" "notice .k t" "notice K t" "clear ../x" "clear" "clear a b" \
  "own-checkout extra" "nope" ""; do
  # shellcheck disable=SC2086 # split on purpose
  run "${s1[@]}" -- $args
  check "(s) usage '$args': exit 2" exits 2
done
check "(s) ... and clear ../x left S/x" [ -e "$S/x" ]
run "${s1[@]}" -- notice "a/../k" t
check "(s) 'notice a/../k t': exit 2" exits 2

if [ -n "$root_user" ]; then
  echo "skip (o) read-only state: running as root, which ignores the mode"
else
  fresh
  mkdir S
  chmod a-w S
  run CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$case_dir/S" -- notice k hello
  check "(o) unwritable state: prints" printed hello
  run CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_STATE="$case_dir/S" -- notice k hello
  check "(o) ... and prints again" printed hello
  chmod u+w S
  check "(o) ... and leaves nothing" [ -z "$(ls -A S)" ]
fi

# --- skip-hooks-install and hooks-check -----------------------------------

# mkrepo: ./main with one commit, and ./wt a linked worktree of it.
mkrepo() {
  main="$case_dir/main"
  wt="$case_dir/wt"
  git -c init.defaultBranch=main init -q "$main"
  git -C "$main" commit -q --allow-empty -m init
  git -C "$main" worktree add -q --detach ../wt 2>/dev/null
}
# own_path: the per-worktree hooks path the removed step gave older worktrees.
own_path() {
  git -C "$main" config extensions.worktreeConfig true
  git -C "$wt" config --worktree core.hooksPath "$main/.git/worktrees/wt/hooks"
}
# hook <dir> <name>: an executable hook.
hook() {
  mkdir -p "$1"
  printf '#!/bin/sh\nexit 0\n' >"$1/$2"
  chmod +x "$1/$2"
}
# st <name>: a state directory of its own for a case.
st() { printf '%s\n' "$case_dir/state-$1"; }

if [ -n "$root_user" ]; then
  echo "skip (H1)-(H9) read-only hooks directories: running as root, which ignores the mode"
else
  fresh
  mkrepo
  cp "$main/.git/config" "$case_dir/config.before"
  hooks="$main/.git/hooks"
  hook "$hooks" pre-commit
  sess=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_ROOT="$wt")

  run "${sess[@]}" DEVENV_STATE="$(st h1)" -- skip-hooks-install pre-commit
  check "(H1) writable, hook present: install runs (exit 1)" exits 1
  check "(H1) ... silent" silent
  run "${sess[@]}" DEVENV_STATE="$(st h1)" -- hooks-check pre-commit
  check "(H1) hooks-check: nothing" quiet

  chmod a-w "$hooks"
  run "${sess[@]}" DEVENV_STATE="$(st h2)" -- skip-hooks-install pre-commit
  check "(H2) unwritable, hook present: install skipped (exit 0)" exits 0
  check "(H2) ... silent" silent
  run "${sess[@]}" DEVENV_STATE="$(st h2)" -- hooks-check pre-commit
  check "(H2) hooks-check: nothing" quiet

  run "${sess[@]}" DEVENV_STATE="$(st h6)" -- hooks-check pre-commit pre-push
  check "(H6) a missing pre-push: one line" one_line
  check "(H6) ... naming pre-push" err_has "run no pre-push hook"
  check "(H6) ... and not pre-commit" err_lacks pre-commit

  chmod u+w "$hooks"
  rm "$hooks/pre-commit"
  chmod a-w "$hooks"
  run "${sess[@]}" DEVENV_STATE="$(st h3)" -- skip-hooks-install pre-commit
  check "(H3) unwritable, no hook: install skipped (exit 0)" exits 0
  check "(H3) ... silent" silent
  run "${sess[@]}" DEVENV_STATE="$(st h3)" -- hooks-check pre-commit
  check "(H3) hooks-check: exit 0, one line on stderr only" one_line
  check "(H3) ... naming the hook" err_has "run no pre-commit hook"
  check "(H3) ... and the directory" err_has "$hooks"
  check "(H3) ... and saying how to fix it" err_has "devenv shell"
  run "${sess[@]}" DEVENV_STATE="$(st h3)" -- hooks-check pre-commit
  check "(H3) ... then silent" quiet

  # (H4) outside a session, with the same layout.
  run DEVENV_ROOT="$wt" DEVENV_STATE="$(st h4)" -- skip-hooks-install pre-commit
  check "(H4) not a session: install runs (exit 1)" exits 1
  check "(H4) ... silent" silent
  for i in 1 2; do
    run DEVENV_ROOT="$wt" DEVENV_STATE="$(st h4)" -- hooks-check pre-commit
    check "(H4) hooks-check run $i: exit 0, one line" one_line
    check "(H4) ... the terminal's wording" err_has "the install didn't add one"
    check "(H4) ... not the session's" err_lacks "Claude Code"
  done
  check "(H4) ... and records nothing" [ ! -e "$(st h4)/coldlogic-notices" ]

  chmod u+w "$hooks"
  printf '#!/bin/sh\n' >"$hooks/pre-commit"
  chmod a-x "$hooks/pre-commit"
  chmod a-w "$hooks"
  run "${sess[@]}" DEVENV_STATE="$(st h3x)" -- hooks-check pre-commit
  check "(H3) a pre-commit that isn't executable: one line" one_line
  check "(H3) ... naming the hook" err_has "run no pre-commit hook"
  run "${sess[@]}" DEVENV_STATE="$(st h3x)" -- hooks-check pre-commit
  check "(H3) ... then silent" quiet

  chmod u+w "$hooks"
  rm "$hooks/pre-commit"
  hook "$hooks" pre-commit
  chmod a-w "$hooks"
  run "${sess[@]}" DEVENV_STATE="$(st h3)" -- hooks-check pre-commit
  check "(H3) the hook added: nothing" quiet
  check "(H3) ... and the record is gone" [ ! -e "$(st h3)/coldlogic-notices/hooks-missing" ]
  chmod u+w "$hooks"
  rm "$hooks/pre-commit"
  chmod a-w "$hooks"
  run "${sess[@]}" DEVENV_STATE="$(st h3)" -- hooks-check pre-commit
  check "(H3) the hook removed again: printed again" one_line
  chmod u+w "$hooks"

  check "(H9) .git/config is unchanged" cmp -s "$case_dir/config.before" "$main/.git/config"
  check "(H9) ... and no config.worktree was written" [ ! -e "$main/.git/worktrees/wt/config.worktree" ]

  # (H5) skip-hooks-install, each with no output.
  fresh
  mkrepo
  hooks="$main/.git/hooks"
  sess=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_ROOT="$wt" DEVENV_STATE="$(st h5)")
  rm -rf "$hooks"
  run "${sess[@]}" -- skip-hooks-install pre-commit
  check "(H5) hooks directory missing, parent writable: exit 1" exits 1
  check "(H5) ... silent" silent
  chmod a-w "$main/.git"
  run "${sess[@]}" -- skip-hooks-install pre-commit
  chmod u+w "$main/.git"
  check "(H5) hooks directory missing, parent unwritable: exit 0" exits 0
  check "(H5) ... silent" silent
  hook "$hooks" pre-commit
  chmod a-w "$hooks/pre-commit"
  run "${sess[@]}" -- skip-hooks-install pre-commit
  check "(H5) writable directory, unwritable pre-commit: exit 0" exits 0
  check "(H5) ... silent" silent
  run "${sess[@]}" -- skip-hooks-install
  check "(H5) ... no arguments, as pre-commit: exit 0" exits 0
  check "(H5) ... silent" silent
  run "${sess[@]}" -- skip-hooks-install pre-push
  check "(H5) ... but pre-push alone, absent: exit 1" exits 1
  chmod u+w "$hooks/pre-commit"
  run CLAUDECODE=1 DEVENV_ROOT="$B" -- skip-hooks-install pre-commit
  check "(H5) DEVENV_ROOT outside any repository: exit 1" exits 1
  check "(H5) ... silent" silent
  run CLAUDECODE=1 -- skip-hooks-install pre-commit
  check "(H5) no DEVENV_ROOT: exit 1" exits 1
  check "(H5) ... silent" silent

  # (H7) a worktree with its own hooks path from the removed step.
  fresh
  mkrepo
  own_path
  cp "$main/.git/worktrees/wt/config.worktree" "$case_dir/config.worktree.before"
  hook "$main/.git/hooks" pre-commit
  sess=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 DEVENV_ROOT="$wt" DEVENV_STATE="$(st h7)")
  run "${sess[@]}" -- skip-hooks-install pre-commit
  check "(H7) own hooks directory absent, parent writable: exit 1" exits 1
  check "(H7) ... silent" silent
  run "${sess[@]}" -- hooks-check pre-commit
  check "(H7) hooks-check: one line" one_line
  check "(H7) ... naming the worktree's own directory" err_has "$main/.git/worktrees/wt/hooks"
  rm "$main/.git/hooks/pre-commit"
  hook "$main/.git/worktrees/wt/hooks" pre-commit
  run "${sess[@]}" -- hooks-check pre-commit
  check "(H7) a hook in its own directory, none in the main one: nothing" quiet
  check "(H9) config.worktree is as own_path left it" \
    cmp -s "$case_dir/config.worktree.before" "$main/.git/worktrees/wt/config.worktree"

  # (H8) hooks-check where there is no repository, and with no arguments.
  run CLAUDECODE=1 DEVENV_ROOT="$B" DEVENV_STATE="$(st h8)" -- hooks-check pre-commit
  check "(H8) DEVENV_ROOT outside any repository: exit 0, nothing" quiet
  run CLAUDECODE=1 DEVENV_STATE="$(st h8)" -- hooks-check pre-commit
  check "(H8) no DEVENV_ROOT: exit 0, nothing" quiet
  run "${sess[@]}" -- hooks-check
  check "(H8) no arguments, pre-commit present: nothing" quiet
  rm "$main/.git/worktrees/wt/hooks/pre-commit"
  run "${sess[@]}" DEVENV_STATE="$(st h8b)" -- hooks-check
  check "(H8) no arguments, pre-commit absent: names pre-commit" err_has "run no pre-commit hook"
fi

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
