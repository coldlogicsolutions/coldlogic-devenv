#!/usr/bin/env bash
# Tests for claude-wrapper.sh, run when packages/claude-wrapper.nix builds:
#
#   bash packages/claude-wrapper-test.sh packages/claude-wrapper.sh
#
# Needs bash and coreutils only. Stand-ins for devenv, git and the real
# claude log what they were given; nothing runs the real devenv. Every
# wrapper under test is a copy of the script, started by its path, so
# BASH_SOURCE is what PATH would give.
#
# The stand-ins' bodies are single-quoted on purpose: they expand when a
# stand-in runs, not when it is written.
# shellcheck disable=SC2016
set -eu

# Also run by hand inside a session, which sets these.
unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION COLDLOGIC_DEVENV_SESSION COLDLOGIC_WRAPPERS_RUN COLDLOGIC_START_WITHOUT_SETTINGS DEVENV_ROOT DEVENV_DOTFILE DEVENV_STATE DEVENV_PROFILE DEVENV_RUNTIME git_bin mktemp_bin rm_bin settings_path

script="$(cd "$(dirname "${1:?usage: claude-wrapper-test.sh <claude-wrapper.sh>}")" && pwd)/$(basename "$1")"
root="$(mktemp -d)"
root="$(cd "$root" && pwd -P)"
trap 'rm -rf "$root"' EXIT

bash_bin="$(command -v bash)"
timeout_bin="$(command -v timeout)"
# The built wrapper names these by store path; the tests name them too, so
# cases with a narrow PATH still have them.
mktemp_abs="$(command -v mktemp)"
rm_abs="$(command -v rm)"
outer_path="$PATH"
passed=0
failed=0
n=0
code=0
out=""

# install_wrapper <dir>: the script as <dir>/claude.
install_wrapper() {
  mkdir -p "$1"
  {
    printf '#!%s\n' "$bash_bin"
    tail -n +2 "$script"
  } >"$1/claude"
  chmod +x "$1/claude"
}

# write_exe <file> <body>: an executable bash script. Builtins only, so it
# works with any PATH.
write_exe() {
  printf '#!%s\n%s\n' "$bash_bin" "$2" >"$1"
  chmod +x "$1"
}

# Copies standard input to the file $1, with builtins only.
copy_stdin='copy_stdin() { local l; : >"$1"; while IFS= read -r l || [ -n "$l" ]; do printf "%s\n" "$l" >>"$1"; done; }'

fresh() {
  n=$((n + 1))
  case_dir="$root/case$n"
  mkdir -p "$case_dir/stubs" "$case_dir/real/bin" "$case_dir/proj" "$case_dir/log" "$case_dir/tmp"
  install_wrapper "$case_dir/wrap/bin"
  : >"$case_dir/proj/devenv.nix"
  write_exe "$case_dir/real/bin/claude" "$copy_stdin"'
log="$STUB_LOG/claude"
{
  echo ran
  echo "cwd=$PWD"
  echo "CLAUDECODE=${CLAUDECODE-unset}"
  echo "session=${COLDLOGIC_DEVENV_SESSION-unset}"
  echo "wrappers=${COLDLOGIC_WRAPPERS_RUN-unset}"
  echo "DEVENV_ROOT=${DEVENV_ROOT-unset}"
  echo "path=$PATH"
  for a in "$@"; do echo "arg=<$a>"; done
} >>"$log"
copy_stdin "$STUB_LOG/claude-stdin"
echo claude-stdout
exit "${STUB_CLAUDE_EXIT:-0}"'
  write_exe "$case_dir/stubs/devenv" "$copy_stdin"'
{
  echo ran
  echo "cwd=$PWD"
  echo "args=$*"
  echo "CLAUDECODE=${CLAUDECODE-unset}"
  echo "session=${COLDLOGIC_DEVENV_SESSION-unset}"
  for v in DEVENV_ROOT DEVENV_DOTFILE DEVENV_STATE DEVENV_PROFILE DEVENV_RUNTIME; do
    echo "$v=${!v-unset}"
  done
} >>"$STUB_LOG/devenv"
copy_stdin "$STUB_LOG/devenv-stdin"
echo devenv-stdout
echo devenv-stderr >&2
exit "${STUB_DEVENV_EXIT:-0}"'
  write_exe "$case_dir/stubs/git" '
if [ "$1 $2" = "rev-parse --show-toplevel" ] && [ -n "${STUB_GIT_TOP:-}" ]; then
  echo "$STUB_GIT_TOP"
  exit 0
fi
exit 128'
  entry="$case_dir/wrap/bin/claude"
  path="$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin:$outer_path"
  git_top="$case_dir/proj"
  run_dir="$case_dir/proj"
  stdin_file=/dev/null
  extra=()
  cd "$case_dir"
}

# run <args...>: the wrapper at $entry, from $run_dir, with $path, the
# case's $extra variables and $stdin_file. Sets $code and $out; stderr goes
# to log/stderr. The timeout turns a loop into a failure, not a hung build.
run() {
  code=0
  out="$(
    cd "$run_dir"
    export STUB_LOG="$case_dir/log"
    export TMPDIR="$case_dir/tmp" mktemp_bin="$mktemp_abs" rm_bin="$rm_abs"
    if [ -n "$git_top" ]; then
      export STUB_GIT_TOP="$git_top"
    fi
    for kv in ${extra[@]+"${extra[@]}"}; do
      export "${kv?}"
    done
    export PATH="$path"
    exec "$timeout_bin" 20 "$entry" "$@" <"$stdin_file" 2>"$case_dir/log/stderr"
  )" || code=$?
}

check() {
  name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name (exit $code; out '$out')"
    for f in "$case_dir"/log/*; do
      [ -f "$f" ] || continue
      echo "     ${f##*/}: $(tr '\n' '|' <"$f")"
    done
  fi
}

# Log helpers, with bash builtins: the build has no grep.
log() { cat "$case_dir/log/$1" 2>/dev/null || true; }
# has <log> <line>: the log has exactly that line.
has() {
  local l
  [ -f "$case_dir/log/$1" ] || return 1
  while IFS= read -r l; do
    if [ "$l" = "$2" ]; then return 0; fi
  done <"$case_dir/log/$1"
  return 1
}
# contains <log> <text>: the text is somewhere in the log.
contains() {
  local all
  all="$(log "$1")"
  [[ $all == *"$2"* ]]
}
absent() { [ ! -e "$case_dir/log/$1" ]; }
# runs <log> <n>: the stand-in ran n times.
runs() {
  local l count=0
  if [ -f "$case_dir/log/$1" ]; then
    while IFS= read -r l; do
      if [ "$l" = ran ]; then count=$((count + 1)); fi
    done <"$case_dir/log/$1"
  fi
  [ "$count" = "$2" ]
}
exits() { [ "$code" = "$1" ]; }
# args_are <lines>: claude's arg= lines, in order, are exactly these.
args_are() {
  local l got=""
  [ -f "$case_dir/log/claude" ] || return 1
  while IFS= read -r l; do
    case "$l" in
      arg=*) got="${got:+$got
}$l" ;;
    esac
  done <"$case_dir/log/claude"
  [ "$got" = "$1" ]
}
# empty_file <log>: the log exists and is empty.
empty_file() { [ -f "$case_dir/log/$1" ] && [ ! -s "$case_dir/log/$1" ]; }
# tmp_clean: the wrapper left nothing in the case's TMPDIR.
tmp_clean() { [ -z "$(ls -A "$case_dir/tmp")" ]; }

# (a) the launch passes through; the refresh runs without the marker.
fresh
run -p 'a b' '' '*' --flag=x
check "(a) exit 0" exits 0
check "(a) claude gets exactly its arguments" args_are "arg=<-p>
arg=<a b>
arg=<>
arg=<*>
arg=<--flag=x>"
check "(a) devenv runs the file tasks" has devenv "args=--quiet tasks run devenv:files"
check "(a) ... without the marker" has devenv "session=unset"
check "(a) claude has the marker" has claude "session=1"
check "(a) stdout is only claude's" [ "$out" = claude-stdout ]
check "(a) stderr is empty: devenv's is held back on success" empty_file stderr
check "(a) ... and its file removed" tmp_clean
check "(a) claude gets PATH unchanged" has claude "path=$path"

# (b) standard input reaches claude, not devenv.
fresh
echo question >"$case_dir/question"
stdin_file="$case_dir/question"
run -p
check "(b) claude reads the input" [ "$(log claude-stdin)" = question ]
check "(b) devenv reads none of it" empty_file devenv-stdin

# (c) claude's exit code is the command's.
fresh
extra=(STUB_CLAUDE_EXIT=7)
run
check "(c) exit 7" exits 7

# (d) the marker alone: a session the wrapper started.
fresh
before="$(ls -A "$case_dir/proj")"
extra=(COLDLOGIC_DEVENV_SESSION=1)
run -p hello
check "(d) marker: no devenv" absent devenv
check "(d) ... claude ran with its arguments" args_are "arg=<-p>
arg=<hello>"
check "(d) ... and the marker" has claude "session=1"
check "(d) ... and nothing new in the project" [ "$(ls -A "$case_dir/proj")" = "$before" ]

# (d2) CLAUDE_CODE_CHILD_SESSION alone: a session started another way.
fresh
extra=(CLAUDE_CODE_CHILD_SESSION=1)
run
check "(d2) child session: no devenv" absent devenv
check "(d2) ... claude ran with the marker" has claude "session=1"

# (d3) both, and CLAUDECODE: a session's Bash tool.
fresh
extra=(COLDLOGIC_DEVENV_SESSION=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDECODE=1)
run
check "(d3) session tool: no devenv" absent devenv
check "(d3) ... claude keeps CLAUDECODE" has claude "CLAUDECODE=1"

# (e) CLAUDECODE alone: an IDE terminal, which must still refresh.
fresh
extra=(CLAUDECODE=1)
run
check "(e) IDE terminal: devenv runs without CLAUDECODE" has devenv "CLAUDECODE=unset"
check "(e) ... and without the marker" has devenv "session=unset"
check "(e) claude gets CLAUDECODE as given" has claude "CLAUDECODE=1"
check "(e) ... and the marker" has claude "session=1"

# (f) a subdirectory: refresh at the top, claude where it was started.
fresh
mkdir -p "$case_dir/proj/src/deep"
run_dir="$case_dir/proj/src/deep"
run
check "(f) devenv runs at the checkout's top" has devenv "cwd=$case_dir/proj"
check "(f) claude starts in the subdirectory" has claude "cwd=$case_dir/proj/src/deep"

# (g) a project with only devenv.yaml.
fresh
rm "$case_dir/proj/devenv.nix"
: >"$case_dir/proj/devenv.yaml"
run
check "(g) devenv.yaml marks the checkout" has devenv "cwd=$case_dir/proj"

# (g2) a sibling worktree: the shell's DEVENV_ROOT names another checkout,
# and git's top, a devenv project, wins.
fresh
mkdir -p "$case_dir/other"
extra=(DEVENV_ROOT="$case_dir/other")
run
check "(g2) git's top wins over DEVENV_ROOT" has devenv "cwd=$case_dir/proj"

# (g3) the shell's devenv variables, which name another checkout, don't
# reach the refresh; claude still gets them.
fresh
mkdir -p "$case_dir/other"
extra=(DEVENV_ROOT="$case_dir/other" DEVENV_DOTFILE="$case_dir/other/.devenv" DEVENV_STATE="$case_dir/other/.devenv/state" DEVENV_PROFILE="$case_dir/other/profile" DEVENV_RUNTIME="$case_dir/other/run")
run
check "(g3) the refresh has no DEVENV_ROOT" has devenv "DEVENV_ROOT=unset"
check "(g3) ... no DEVENV_DOTFILE" has devenv "DEVENV_DOTFILE=unset"
check "(g3) ... no DEVENV_STATE" has devenv "DEVENV_STATE=unset"
check "(g3) ... no DEVENV_PROFILE" has devenv "DEVENV_PROFILE=unset"
check "(g3) ... no DEVENV_RUNTIME" has devenv "DEVENV_RUNTIME=unset"
check "(g3) ... and claude keeps them" has claude "DEVENV_ROOT=$case_dir/other"

# (h) git's top is no devenv project: nothing refreshed or checked, even
# with the shell's DEVENV_ROOT naming a project whose refresh would fail and
# whose settings are missing.
fresh
mkdir -p "$case_dir/plain"
git_top="$case_dir/plain"
run_dir="$case_dir/plain"
extra=(DEVENV_ROOT="$case_dir/proj" STUB_DEVENV_EXIT=3)
run
check "(h) no devenv files at the top: no devenv" absent devenv
check "(h) ... no refusal: claude ran" runs claude 1
check "(h) ... in its directory" has claude "cwd=$case_dir/plain"
check "(h) ... with the marker" has claude "session=1"
check "(h) ... and nothing on stderr" empty_file stderr

# (i) not in git: the same.
fresh
mkdir -p "$case_dir/elsewhere"
git_top=""
run_dir="$case_dir/elsewhere"
extra=(DEVENV_ROOT="$case_dir/proj" STUB_DEVENV_EXIT=3)
run
check "(i) git fails: no devenv" absent devenv
check "(i) ... no refusal: claude ran" runs claude 1
check "(i) ... in its directory" has claude "cwd=$case_dir/elsewhere"
check "(i) ... and nothing on stderr" empty_file stderr

# (j) no project and no shell's project.
fresh
git_top=""
run
check "(j) no project: no devenv" absent devenv
check "(j) ... claude ran with the marker" has claude "session=1"
check "(j) ... and nothing on stderr" empty_file stderr

# (k) the refresh fails, settings in place.
fresh
mkdir -p "$case_dir/proj/.claude"
: >"$case_dir/settings-target"
ln -s "$case_dir/settings-target" "$case_dir/proj/.claude/settings.json"
extra=(STUB_DEVENV_EXIT=3)
run
check "(k) failed refresh, settings there: claude ran" runs claude 1
check "(k) ... stderr says it couldn't refresh" contains stderr "couldn't refresh"
check "(k) ... with the exit code" contains stderr "exited 3"
check "(k) ... and that they may be out of date" contains stderr "may be out of date"
check "(k) ... and claude has the marker" has claude "session=1"
check "(k) ... devenv's stderr shown" has stderr devenv-stderr
check "(k) ... and its file removed" tmp_clean

# (l) the refresh fails, no settings: refused.
fresh
extra=(STUB_DEVENV_EXIT=3)
run
check "(l) failed refresh, no settings: exit 1" exits 1
check "(l) ... claude not started" absent claude
check "(l) ... stderr says so" contains stderr "not starting claude"
check "(l) ... names the settings" contains stderr "$case_dir/proj/.claude/settings.json"
check "(l) ... and the override" contains stderr "COLDLOGIC_START_WITHOUT_SETTINGS=1 claude"
check "(l) ... devenv's stderr shown" has stderr devenv-stderr
check "(l) ... and its file removed on the refusal" tmp_clean

# (m) a dangling settings link counts as missing.
fresh
mkdir -p "$case_dir/proj/.claude"
ln -s "$case_dir/gone" "$case_dir/proj/.claude/settings.json"
extra=(STUB_DEVENV_EXIT=3)
run
check "(m) dangling link: exit 1" exits 1
check "(m) ... claude not started" absent claude
check "(m) ... stderr says so" contains stderr "not starting claude"

# (n) the override.
fresh
extra=(STUB_DEVENV_EXIT=3 COLDLOGIC_START_WITHOUT_SETTINGS=1)
run
check "(n) override: claude ran" runs claude 1
check "(n) ... and stderr says it starts anyway" contains stderr "Starting claude anyway"
check "(n) ... and claude has the marker" has claude "session=1"

# (o) a regular settings file counts as there.
fresh
mkdir -p "$case_dir/proj/.claude"
echo '{}' >"$case_dir/proj/.claude/settings.json"
extra=(STUB_DEVENV_EXIT=3)
run
check "(o) regular settings file: claude ran" runs claude 1

# (o2) a non-default settings path, as the built wrapper gets it from
# claude.code.settingsPath: that file is the one checked, in the checkout.
fresh
mkdir -p "$case_dir/proj/conf" "$case_dir/proj/src"
echo '{}' >"$case_dir/proj/conf/claude.json"
run_dir="$case_dir/proj/src"
extra=(STUB_DEVENV_EXIT=3 settings_path=conf/claude.json)
run
check "(o2) custom settings path there: claude ran" runs claude 1
check "(o2) ... and stderr says they may be out of date" contains stderr "may be out of date"

# (o3) the custom file missing refuses, though .claude/settings.json is
# there, and names the custom file.
fresh
mkdir -p "$case_dir/proj/.claude"
echo '{}' >"$case_dir/proj/.claude/settings.json"
extra=(STUB_DEVENV_EXIT=3 settings_path=conf/claude.json)
run
check "(o3) custom settings path missing: exit 1" exits 1
check "(o3) ... claude not started" absent claude
check "(o3) ... names the custom file" contains stderr "$case_dir/proj/conf/claude.json is missing"

# (p) no devenv on PATH is a failed refresh. PATH holds only the case's
# directories, so no outer devenv can answer.
fresh
rm "$case_dir/stubs/devenv"
mkdir -p "$case_dir/proj/.claude"
echo '{}' >"$case_dir/proj/.claude/settings.json"
path="$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin"
run
check "(p) no devenv: claude ran" runs claude 1
check "(p) ... and stderr has exit 127" contains stderr "exited 127"

# (q) a refresh that works is trusted, settings or not.
fresh
extra=(STUB_DEVENV_EXIT=0)
run
check "(q) refresh works, no settings: claude ran" runs claude 1
check "(q) ... and nothing on stderr, devenv's included" empty_file stderr
check "(q) ... and its file removed" tmp_clean

# (q2) without a file to hold it (mktemp fails), devenv's stderr goes
# straight through, and the refresh still runs.
fresh
extra=(mktemp_bin="$case_dir/no-mktemp")
run
check "(q2) no mktemp: devenv ran" runs devenv 1
check "(q2) ... claude ran" runs claude 1
check "(q2) ... devenv's stderr went through" has stderr devenv-stderr

# (r) the wrapper's directory twice on PATH.
fresh
path="$case_dir/wrap/bin:$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin:$outer_path"
run
check "(r) listed twice: claude ran once" runs claude 1
check "(r) ... devenv once" runs devenv 1

# (s) the wrapper's directory through a link.
fresh
mkdir -p "$case_dir/link"
ln -s "$case_dir/wrap/bin" "$case_dir/link/bin"
path="$case_dir/link/bin:$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin:$outer_path"
entry="$case_dir/link/bin/claude"
run
check "(s) through a link: claude ran once" runs claude 1

# (t) two wrappers: each runs once, the refresh once.
fresh
install_wrapper "$case_dir/wrap2/bin"
path="$case_dir/wrap/bin:$case_dir/wrap2/bin:$case_dir/stubs:$case_dir/real/bin:$outer_path"
run
check "(t) two wrappers: claude ran once" runs claude 1
check "(t) ... with both wrappers recorded" has claude "wrappers=$case_dir/wrap/bin/claude:$case_dir/wrap2/bin/claude"
check "(t) ... and devenv once" runs devenv 1

# (u) two wrappers and no Claude Code: no loop.
fresh
install_wrapper "$case_dir/wrap2/bin"
path="$case_dir/wrap/bin:$case_dir/wrap2/bin:$case_dir/stubs"
run
check "(u) two wrappers, no claude: exit 127, not a loop" exits 127

# (v) no Claude Code: nothing refreshed.
fresh
path="$case_dir/wrap/bin:$case_dir/stubs"
run
check "(v) no claude: exit 127" exits 127
check "(v) ... stderr says so" contains stderr "no Claude Code found"
check "(v) ... and no devenv" absent devenv

# (w) a non-executable file and a directory named claude are skipped.
fresh
mkdir -p "$case_dir/noexec" "$case_dir/isdir/claude"
: >"$case_dir/noexec/claude"
path="$case_dir/wrap/bin:$case_dir/noexec:$case_dir/isdir:$case_dir/stubs:$case_dir/real/bin:$outer_path"
run
check "(w) non-executable and directory skipped: claude ran" runs claude 1

# (x) the variables a session's Bash tool passes on.
fresh
extra=(COLDLOGIC_WRAPPERS_RUN="$case_dir/wrap/bin/claude" COLDLOGIC_DEVENV_SESSION=1)
run
check "(x) from a session: claude ran once" runs claude 1
check "(x) ... and no devenv" absent devenv

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
