#!/usr/bin/env bash
# Tests for session-relink.sh, run when packages/session-relink.nix builds:
#
#   bash packages/session-relink-test.sh packages/session-relink.sh
#
# Needs no sandbox or session, but does need GNU coreutils on PATH (as in
# `devenv shell`). A read-only directory stands in for a denied create, and a
# failing `mv` on PATH for a denied rename. Targets are made-up store paths,
# so the links dangle; the script only compares them.
set -eu

script="$(cd "$(dirname "${1:?usage: session-relink-test.sh <session-relink.sh>}")" && pwd)/$(basename "$1")"
if ! realpath -ms / >/dev/null 2>&1; then
  echo "session-relink-test: needs GNU realpath (coreutils) on PATH" >&2
  exit 1
fi
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
relink .mcp.json "$new"
check "(f) regular file: exit 1" exits 1
check "(f) ... is still a regular file" [ ! -L .mcp.json ]
check "(f) ... with its contents" [ "$(cat .mcp.json)" = '{}' ]
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
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[".mcp.json",".claude/settings.json"]}' >files.json
relink --state files.json "$PWD/.claude/settings.json" "$new" .mcp.json "$new"
check "(i) state spells settings relatively, current name absolute: exit 0" exits 0
check "(i) ... and the link survives" points_at .claude/settings.json "$new"
done_case

fresh
ln -s "$new" .claude/settings.json
ln -s "$new" .mcp.json
echo "{\"managedFiles\":[\".mcp.json\",\"$PWD/.claude/settings.json\"]}" >files.json
relink --state files.json "$PWD/.claude/settings.json" "$new" .mcp.json "$new"
check "(j) state spellings match: exit 1" exits 1
done_case

fresh
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[' >files.json
relink --state files.json .claude/settings.json "$new"
check "(k) malformed state: exit 0" exits 0
check "(k) ... and the link survives" points_at .claude/settings.json "$new"
done_case

for shape in '{"files":[".claude/settings.json"]}' '{"managedFiles":".claude/settings.json"}' \
  '{"managedFiles":[1]}' '[".claude/settings.json"]' '' '{"managedFiles":[]} {"managedFiles":[]}'; do
  fresh
  ln -s "$new" .claude/settings.json
  printf '%s' "$shape" >files.json
  relink --state files.json .claude/settings.json "$new"
  check "(l) state of the wrong shape '$shape': exit 0" exits 0
  done_case
done

fresh
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[]}' >files.json
relink --state files.json .claude/settings.json "$new"
check "(l2) state with no entries: exit 1" exits 1
done_case

fresh
ln -s "$new" .claude/settings.json
relink --state missing.json .claude/settings.json "$new"
check "(l3) no state file yet: exit 1" exits 1
done_case

for spelling in .claude//settings.json x/../.claude/settings.json ./.claude/./settings.json; do
  fresh
  ln -s "$new" .claude/settings.json
  echo "{\"managedFiles\":[\"$spelling\"]}" >files.json
  relink --state files.json .claude/settings.json "$new"
  check "(m) state spells settings '$spelling': exit 0" exits 0
  check "(m) ... and the link survives" points_at .claude/settings.json "$new"
  done_case
done

fresh
ln -s "$new" .claude/settings.json
echo "{\"managedFiles\":[\"$PWD/.claude/settings.json\"]}" >files.json
relink --state files.json .claude/settings.json "$new"
check "(m2) state spells settings absolutely, current name relative: exit 0" exits 0
check "(m2) ... and the link survives" points_at .claude/settings.json "$new"
done_case

fresh
ln -s "$new" .claude/settings.json
echo "{\"managedFiles\":[\"$PWD/x/../.claude//settings.json\"]}" >files.json
relink --state files.json "$PWD/.claude/settings.json" "$new"
check "(m3) state spells the absolute name differently: exit 0" exits 0
done_case

fresh
ln -s "$new" .claude/settings.json
echo '{"managedFiles":["/elsewhere/.claude/settings.json",".claude/settings.json.bak"]}' >files.json
relink --state files.json .claude/settings.json "$new"
check "(m4) entries naming other paths: exit 1" exits 1
done_case

fresh
ln -s "$old" .claude/settings.json
ln -s "$old" ".claude/.settings.json.coldlogic-relink.$dead"
backdate ".claude/.settings.json.coldlogic-relink.$dead"
relink --check-only --print .claude/settings.json "$new"
check "(n) --check-only, stale link: exit 0" exits 0
check "(n) ... prints it" printed .claude/settings.json
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
check "(p) ... prints only the missing link" printed .claude/settings.json
check "(p) ... creates nothing" [ ! -e .claude ]
done_case

fresh
echo '{}' >.mcp.json
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[".mcp.json",".claude/settings.json"]}' >files.json
relink --check-only --print --state files.json .claude/settings.json "$new" .mcp.json "$new"
check "(p2) --check-only --state, real file otherwise current: exit 1" exits 1
check "(p2) ... prints nothing" printed ""
done_case

fresh
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[".claude/settings.json"]}' >files.json
relink --check-only --state files.json "$PWD/.claude/settings.json" "$new"
check "(q) --check-only with a respelled state entry: exit 0" exits 0
check "(q) ... prints nothing (no file is stale)" printed ""
done_case

fresh
relink --bogus .claude/settings.json "$new"
check "(r) unknown option: exit 2" exits 2
relink .claude/settings.json
check "(r) odd number of arguments: exit 2" exits 2
done_case

# A failing command must never come out as exit 1 (run the task).
fresh
ln -s "$new" .claude/settings.json
echo '{"managedFiles":[".claude/settings.json"]}' >files.json
shim realpath
relink_shimmed --check-only --state files.json "$PWD/.claude/settings.json" "$new"
check "(t) realpath fails during the state check: exit 3" exits 3
done_case

fresh
ln -s "$old" .claude/settings.json
shim dirname
relink_shimmed .claude/settings.json "$new"
check "(t) dirname fails during the relink: exit 3" exits 3
check "(t) ... and the link keeps its old target" points_at .claude/settings.json "$old"
done_case

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
