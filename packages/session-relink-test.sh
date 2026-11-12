#!/usr/bin/env bash
# Tests for session-relink.sh, run when packages/session-relink.nix builds:
#
#   bash packages/session-relink-test.sh packages/session-relink.sh
#
# Needs no sandbox or session, but does need GNU coreutils on PATH (as in
# `devenv shell`), for `touch -d`. A read-only directory stands in for a denied create, and a
# failing `mv` on PATH for a denied rename. Targets are made-up store paths,
# so the links dangle; the script only compares them.
set -eu

script="$(cd "$(dirname "${1:?usage: session-relink-test.sh <session-relink.sh>}")" && pwd)/$(basename "$1")"
root="$(mktemp -d)"
live=""
cleanup() {
  [ -z "$live" ] || kill "$live" 2>/dev/null || true
  chmod -R u+w "$root" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT

old=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-settings.json
new=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-settings.json
passed=0
failed=0
n=0
code=0
out=""

# A process that has exited, for a leftover temporary link's PID.
sh -c 'exit 0' &
dead=$!
wait "$dead"

# Fresh working directory for a case; the script runs relative to it.
fresh() {
  n=$((n + 1))
  case_dir="$root/case$n"
  mkdir -p "$case_dir/.claude"
  cd "$case_dir"
}

# relink [args...]: runs the script, sets $code and $out (its stdout).
relink() {
  code=0
  out="$(bash "$script" "$@")" || code=$?
}

check() {
  name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name (exit $code; out '$out'; $(find "$case_dir" -exec ls -ld {} + 2>&1 | tr '\n' ' '))"
  fi
}

points_at() { [ "$(readlink "$1" 2>/dev/null)" = "$2" ]; }
# A leftover temporary link, made more than a minute ago.
backdate() { touch -h -d '2 minutes ago' "$1"; }
# shim <name>: a command of that name on PATH that fails, in ./shim.
shim() {
  mkdir -p shim
  printf '#!/bin/sh\nexit 1\n' >"shim/$1"
  chmod +x "shim/$1"
}
# relink_shimmed [args...]: relink with ./shim first on PATH.
relink_shimmed() {
  code=0
  out="$(PATH="$case_dir/shim:$PATH" bash "$script" "$@")" || code=$?
}
exits() { [ "$code" = "$1" ]; }
printed() { [ "$out" = "$1" ]; }
# No temporary link anywhere in the case, except one named $1 if given.
no_tmp() { [ -z "$(find "$case_dir" -name '*.coldlogic-relink.*' ! -name "${1:-}")" ]; }
# Ends a case: no temporary link may be left, except $1.
done_case() { check "  ... and no temporary link is left${1:+ but $1}" no_tmp "${1:-}"; }

fresh
ln -s "$old" .claude/settings.json
relink .claude/settings.json "$new"
check "(a) stale link in a writable dir is relinked: exit 1" exits 1
check "(a) ... and points at the new target" points_at .claude/settings.json "$new"
done_case

fresh
rmdir .claude
relink .claude/settings.json "$new"
check "(b) missing link is created" exits 1
check "(b) ... pointing at the target" points_at .claude/settings.json "$new"
done_case

fresh
ln -s "$new" .claude/settings.json
before="$(ls -li .claude/settings.json)"
relink .claude/settings.json "$new"
check "(c) current link: exit 1" exits 1
check "(c) ... is untouched" [ "$(ls -li .claude/settings.json)" = "$before" ]
done_case

if [ "$(id -u)" = 0 ]; then
  echo "skip (d) read-only dir: running as root, which ignores the mode"
else
  fresh
  ln -s "$old" .claude/settings.json
  chmod a-w .claude
  relink .claude/settings.json "$new"
  chmod u+w .claude
  check "(d) stale link in a read-only dir: exit 0" exits 0
  check "(d) ... keeps its old target" points_at .claude/settings.json "$old"
  done_case
fi

fresh
ln -s "$old" .claude/settings.json
shim mv
relink_shimmed .claude/settings.json "$new"
check "(e) denied rename: exit 0" exits 0
check "(e) ... keeps its old target" points_at .claude/settings.json "$old"
done_case

fresh
echo '{}' >.mcp.json
relink --print .mcp.json "$new"
check "(f) regular file: exit 0" exits 0
check "(f) ... prints it as a conflict" printed "conflict .mcp.json"
check "(f) ... is still a regular file" [ ! -L .mcp.json ]
check "(f) ... with its contents" [ "$(cat .mcp.json)" = '{}' ]
done_case

fresh
mkdir -p .claude/settings.json
touch .claude/settings.json/keep
relink --print .claude/settings.json "$new"
check "(f2) real directory: exit 0" exits 0
check "(f2) ... prints it as a conflict" printed "conflict .claude/settings.json"
check "(f2) ... is still a directory" [ -d .claude/settings.json ]
check "(f2) ... not a link" [ ! -L .claude/settings.json ]
check "(f2) ... with its contents, and nothing linked into it" [ "$(ls -A .claude/settings.json)" = keep ]
done_case

fresh
mkdir elsewhere
ln -s "$case_dir/elsewhere" .claude/settings.json
relink .claude/settings.json "$new"
check "(g) link to a directory: exit 0" exits 0
check "(g) ... is untouched" points_at .claude/settings.json "$case_dir/elsewhere"
check "(g) ... and nothing was moved into the directory" [ -z "$(ls -A elsewhere)" ]
done_case

fresh
ln -s "$old" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$dead"
backdate ".claude/.settings.json.coldlogic-relink.$dead"
relink .claude/settings.json "$new"
check "(h) a dead run's old temporary link is removed" [ ! -L ".claude/.settings.json.coldlogic-relink.$dead" ]
check "(h) ... and the link is relinked" points_at .claude/settings.json "$new"
done_case

fresh
ln -s "$old" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$dead"
relink .claude/settings.json "$new"
check "(h1) a dead run's temporary link under a minute old is kept" [ -L ".claude/.settings.json.coldlogic-relink.$dead" ]
check "(h1) ... and the link is relinked" points_at .claude/settings.json "$new"
done_case ".settings.json.coldlogic-relink.$dead"

fresh
ln -s "$new" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$dead"
backdate ".claude/.settings.json.coldlogic-relink.$dead"
relink .claude/settings.json "$new"
check "(h3) beside a current link: exit 1" exits 1
check "(h3) ... and a dead run's old temporary link is still removed" [ ! -L ".claude/.settings.json.coldlogic-relink.$dead" ]
done_case

fresh
sleep 300 &
live=$!
ln -s "$old" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$live"
backdate ".claude/.settings.json.coldlogic-relink.$live"
relink .claude/settings.json "$new"
check "(h2) a running run's temporary link is kept" points_at ".claude/.settings.json.coldlogic-relink.$live" "$old"
check "(h2) ... and the link is relinked" points_at .claude/settings.json "$new"
done_case ".settings.json.coldlogic-relink.$live"
kill "$live" 2>/dev/null || true
wait "$live" 2>/dev/null || true
live=""

fresh
ln -s "$old" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$dead"
backdate ".claude/.settings.json.coldlogic-relink.$dead"
relink --check-only --print .claude/settings.json "$new"
check "(n) --check-only, stale link: exit 0" exits 0
check "(n) ... prints it as stale" printed "stale .claude/settings.json"
check "(n) ... leaves it alone" points_at .claude/settings.json "$old"
check "(n) ... and doesn't sweep leftovers" [ -L ".claude/.settings.json.coldlogic-relink.$dead" ]
done_case ".settings.json.coldlogic-relink.$dead"

fresh
ln -s "$new" .claude/settings.json
relink --check-only --print .claude/settings.json "$new"
check "(o) --check-only, current link: exit 1" exits 1
check "(o) ... prints nothing" printed ""
done_case

fresh
echo '{}' >.mcp.json
rmdir .claude
relink --check-only --print .claude/settings.json "$new" .mcp.json "$new"
check "(p) --check-only, missing link and real file: exit 0" exits 0
check "(p) ... prints the missing link, then the conflict" printed "missing .claude/settings.json
conflict .mcp.json"
check "(p) ... creates nothing" [ ! -e .claude ]
check "(p) ... and leaves the real file" [ "$(cat .mcp.json)" = '{}' ]
done_case

fresh
echo '{}' >.mcp.json
ln -s "$new" .claude/settings.json
relink --check-only --print .claude/settings.json "$new" .mcp.json "$new"
check "(p2) --check-only, real file otherwise current: exit 0" exits 0
check "(p2) ... prints only the conflict" printed "conflict .mcp.json"
done_case

fresh
relink --bogus .claude/settings.json "$new"
check "(r) unknown option: exit 2" exits 2
relink .claude/settings.json
check "(r) odd number of arguments: exit 2" exits 2
relink --state files.json .claude/settings.json "$new"
check "(r) the removed --state option: exit 2" exits 2
done_case

# A file the sandbox refuses must not stop the rest from being linked (#78).
if [ "$(id -u)" = 0 ]; then
  echo "skip (u) (u2) read-only dir: running as root, which ignores the mode"
else
  fresh
  ln -s "$old" .claude/settings.json
  chmod a-w .claude
  relink .claude/settings.json "$new" .pre-commit-config.yaml "$new"
  chmod u+w .claude
  check "(u) refused file first, writable one after: exit 0" exits 0
  check "(u) ... the refused link keeps its old target" points_at .claude/settings.json "$old"
  check "(u) ... and the writable one is linked" points_at .pre-commit-config.yaml "$new"
  done_case

  fresh
  ln -s "$old" .claude/settings.json
  chmod a-w .claude
  relink .pre-commit-config.yaml "$new" .claude/settings.json "$new"
  chmod u+w .claude
  check "(u2) writable file first, refused one after: exit 0" exits 0
  check "(u2) ... the refused link keeps its old target" points_at .claude/settings.json "$old"
  check "(u2) ... and the writable one is linked" points_at .pre-commit-config.yaml "$new"
  done_case
fi

fresh
ln -s "$old" b.json
ln -s "$new" c.json
echo '{}' >d.json
relink --check-only --print a.json "$new" b.json "$new" c.json "$new" d.json "$new"
check "(v) --check-only over missing, stale, current, real file: exit 0" exits 0
check "(v) ... prints them in order, the real file as a conflict" printed "missing a.json
stale b.json
conflict d.json"
done_case

if [ "$(id -u)" = 0 ]; then
  echo "skip (v2) read-only dir: running as root, which ignores the mode"
else
  fresh
  chmod a-w .claude
  relink --print .claude/settings.json "$new"
  chmod u+w .claude
  check "(v2) relink of a missing link, create denied: exit 0" exits 0
  check "(v2) ... prints it as missing" printed "missing .claude/settings.json"
  check "(v2) ... and creates no link" [ ! -L .claude/settings.json ]
  check "(v2) ... nor anything else" [ ! -e .claude/settings.json ]
  done_case
fi

# A failing command must never come out as exit 1 (nothing stale).
fresh
ln -s "$old" .claude/settings.json
shim dirname
relink_shimmed .claude/settings.json "$new"
check "(t) dirname fails during the relink: exit 3" exits 3
check "(t) ... and the link keeps its old target" points_at .claude/settings.json "$old"
done_case

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
