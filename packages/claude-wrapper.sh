#!/usr/bin/env bash
# `claude`, as the developer shell puts it on PATH, ahead of the real Claude
# Code (packages/claude-wrapper.nix). Outside a session, unless the command
# starts none (`--version`, `mcp` and the like), it first refreshes the
# generated files of the checkout the current directory is in:
#
#   devenv --quiet tasks run devenv:files
#
# run at the checkout's top, so the session starts with current settings
# (#101). Then it starts the real `claude` with the same arguments, working
# directory and standard streams, and is replaced by it.
#
# It reads:
#   COLDLOGIC_DEVENV_SESSION   set: a session is running, refresh nothing
#   CLAUDE_CODE_CHILD_SESSION  the same, for a session started another way
#   COLDLOGIC_START_WITHOUT_SETTINGS  set: after a failed refresh, start even
#                              with no settings file
#   COLDLOGIC_WRAPPERS_RUN     the wrappers already run in this launch, which
#                              are never started again
# It sets, for the real `claude`:
#   COLDLOGIC_DEVENV_SESSION=1, which marks the session and all it runs
#   COLDLOGIC_WRAPPERS_RUN, with its own path added
#
# Exit codes: Claude Code's own; 1 when it refuses to start a session with
# no settings; 127 when there is no Claude Code behind it on PATH; 130
# when SIGINT interrupted the refresh, 143 when SIGTERM did.
#
# It uses only bash builtins, `git` (`$git_bin`, a store path in the built
# application), `mktemp` and `rm` (`$mktemp_bin` and `$rm_bin`, likewise)
# and `devenv` (the developer's own, from PATH). The built application also
# sets `$settings_path`, the module's `claude.code.settingsPath` relative to
# the checkout, or absolute when a project sets it outside its root.
set -euo pipefail

self="${BASH_SOURCE[0]}"
if [ "${self#/}" = "$self" ]; then
  self="$PWD/$self"
fi
git_bin="${git_bin:-git}"
mktemp_bin="${mktemp_bin:-mktemp}"
rm_bin="${rm_bin:-rm}"
settings_path="${settings_path:-.claude/settings.json}"
seen="${COLDLOGIC_WRAPPERS_RUN:-}"

# Read before the marker is exported below. CLAUDECODE is not part of this
# test: an IDE extension sets it in its terminals, where no session runs yet
# and the refresh must. So it differs on purpose from the shell tasks'
# session test (`inSession` in devenv.nix), which counts CLAUDECODE.
nested=""
if [ -n "${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]; then
  nested=1
fi

# is_wrapper <file>: 0 when <file> is this wrapper, through any link, or one
# already run in this launch. Without the list, two wrappers on PATH would
# start each other forever.
is_wrapper() {
  local w
  local -a ws=()
  if [ "$1" -ef "$self" ]; then
    return 0
  fi
  if [ -n "$seen" ]; then
    IFS=: read -ra ws <<<"$seen"
  fi
  for w in ${ws[@]+"${ws[@]}"}; do
    if [ -n "$w" ] && [ "$1" -ef "$w" ]; then
      return 0
    fi
  done
  return 1
}

# The real `claude`: the first executable file on PATH that isn't a
# wrapper. An empty entry is skipped, not read as the current directory.
real=""
dirs=()
if [ -n "${PATH:-}" ]; then
  IFS=: read -ra dirs <<<"$PATH"
fi
for dir in ${dirs[@]+"${dirs[@]}"}; do
  if [ -z "$dir" ]; then
    continue
  fi
  cand="$dir/claude"
  if [ -f "$cand" ] && [ -x "$cand" ]; then
    if ! is_wrapper "$cand"; then
      real="$cand"
      break
    fi
  fi
done
if [ -z "$real" ]; then
  echo "coldlogic: no Claude Code found on PATH behind this wrapper ($self). Install Claude Code, or add it to PATH." >&2
  exit 127
fi

# From here every start of the real `claude` carries both.
export COLDLOGIC_WRAPPERS_RUN="${seen:+$seen:}$self"
export COLDLOGIC_DEVENV_SESSION=1

# Inside a session: no devenv, no write (#68, #94).
if [ -n "$nested" ]; then
  exec "$real" "$@"
fi

# Commands that start no session read no project settings, so they don't
# wait for a refresh or a settings check. Only the first argument counts:
# `claude -p --version` is a prompt. Anything not listed refreshes: skipping
# one that starts a session would start it on stale settings, while
# refreshing one that didn't need it costs only a wait. So only commands
# that plainly start none are listed; `attach`, `agents` and the other
# session commands refresh.
case "${1-}" in
  --version | -v | --help | -h | update | upgrade | doctor | mcp | config | auth | setup-token | install | migrate-installer | plugin | plugins)
    exec "$real" "$@"
    ;;
esac

# The checkout: the top of the git checkout here, only when it is a devenv
# project. Never DEVENV_ROOT: a shell entered in one checkout and moved
# elsewhere still names the first, and `claude` reads the settings of the
# one it starts in. Anywhere else there are no generated settings of ours
# to refresh or to be without, so `claude` starts at once, with no message.
top="$("$git_bin" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -z "$top" ] || { [ ! -f "$top/devenv.nix" ] && [ ! -f "$top/devenv.yaml" ]; }; then
  exec "$real" "$@"
fi
checkout="$top"

# The refresh, in a subshell, so this directory and environment never
# change. The two session variables are cleared so the shell's session test
# lets the file tasks run. So is every DEVENV_ variable of the shell this
# runs in: entered in another checkout, its DEVENV_ROOT, DEVENV_STATE and
# the rest name that checkout, and devenv must work out this one from the
# directory, as a terminal shell does. It can't read the wrapper's input (a
# prompt piped to `claude -p`) or write to its output (often captured). Its
# output, both streams (`devenv tasks run` prints a task's failure on
# stdout), is held in a file and shown on stderr only when it fails, when it
# is what the developer needs; a refresh that works prints nothing, warnings
# included. The file is removed before claude starts, or on any exit
# before. Without one (mktemp fails), both streams go straight to stderr.
#
# `tasks run` defaults to `--mode before`, so devenv:files:cleanup runs
# first, as in the shell (devenv rev 9655d32: src/modules/files.nix gives
# devenv:files `after = [ "devenv:files:cleanup" ]`).
refresh() {
  local -a shell_vars=("${!DEVENV_@}")
  # A background job of a script starts with SIGINT ignored; devenv gets
  # both signals as it would from a terminal.
  trap - INT TERM
  cd "$checkout" || return
  unset CLAUDECODE COLDLOGIC_DEVENV_SESSION ${shell_vars[@]+"${shell_vars[@]}"}
  exec devenv --quiet tasks run devenv:files
}
errlog=""
if errlog="$("$mktemp_bin" "${TMPDIR:-/tmp}/coldlogic-claude.XXXXXX" 2>/dev/null)" && [ -n "$errlog" ]; then
  trap '"$rm_bin" -f "$errlog"' EXIT
else
  errlog=""
fi
# An interruption is told by the signal reaching the wrapper, not by
# devenv's exit code: devenv may catch SIGINT and exit 1, and an ordinary
# failure may exit 255. The refresh runs in the background so the wrapper
# can take a signal at once, not only after devenv exits: it records the
# signal and passes it on to devenv, which a signal sent to the wrapper
# alone would otherwise miss. Ctrl-C reaches devenv too, from the terminal.
code=0
signal=""
child=""
on_signal() {
  signal="$1"
  if [ -n "$child" ]; then
    kill -"$1" "$child" 2>/dev/null || true
  fi
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
if [ -n "$errlog" ]; then
  (refresh) </dev/null >"$errlog" 2>&1 &
else
  (refresh) </dev/null >&2 &
fi
child=$!
# A signal before `child` was set was recorded but not passed on.
if [ -n "$signal" ]; then
  kill -"$signal" "$child" 2>/dev/null || true
fi
# A signal ends `wait` early, with devenv maybe still running: wait again,
# until devenv has exited and its code is known.
while :; do
  code=0
  wait "$child" || code=$?
  if ! kill -0 "$child" 2>/dev/null; then
    break
  fi
done
trap - INT TERM

# Interrupted: the developer meant to stop, or the machine did. Start
# nothing, whatever the refresh's exit code and the settings. Its output
# isn't shown; it is only the interruption, nor is its exit code, which may
# be `wait`'s own. 130 for SIGINT, 143 for SIGTERM.
if [ -n "$signal" ]; then
  echo "coldlogic: not starting claude: the refresh of the generated files in $checkout (devenv tasks run devenv:files) was interrupted by SIG$signal." >&2
  if [ "$signal" = TERM ]; then
    exit 143
  fi
  exit 130
fi

# A refresh that succeeds is trusted: nothing printed, the link not looked
# at. One that fails starts a session only with settings in place.
if [ "$code" != 0 ]; then
  if [ -n "$errlog" ] && [ -s "$errlog" ]; then
    printf '%s\n' "$(<"$errlog")" >&2
  fi
  case "$settings_path" in
    /*) settings="$settings_path" ;;
    *) settings="$checkout/$settings_path" ;;
  esac
  if [ -e "$settings" ]; then
    echo "coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code). Starting claude with the settings already there, which may be out of date. To see why, run there: devenv shell" >&2
  elif [ -n "${COLDLOGIC_START_WITHOUT_SETTINGS:-}" ]; then
    echo "coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing. Starting claude anyway, as COLDLOGIC_START_WITHOUT_SETTINGS is set: this session has none of the module's guard hook, sandbox settings or permissions." >&2
  else
    echo "coldlogic: not starting claude. Couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing, so the session would have none of the module's guard hook, sandbox settings or permissions. To see why, run there: devenv shell. To start it anyway: COLDLOGIC_START_WITHOUT_SETTINGS=1 claude" >&2
    exit 1
  fi
fi

# exec runs no EXIT trap.
if [ -n "$errlog" ]; then
  "$rm_bin" -f "$errlog"
fi
trap - EXIT
exec "$real" "$@"
