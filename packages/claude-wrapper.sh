#!/usr/bin/env bash
# `claude`, as the developer shell puts it on PATH, ahead of the real Claude
# Code (packages/claude-wrapper.nix). Outside a session it first refreshes
# the generated files of the checkout the current directory is in:
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
# no settings; 127 when there is no Claude Code behind it on PATH; the
# refresh's own, 128 or more, when a signal stopped it.
#
# It uses only bash builtins, `git` (`$git_bin`, a store path in the built
# application), `mktemp` and `rm` (`$mktemp_bin` and `$rm_bin`, likewise)
# and `devenv` (the developer's own, from PATH). The built application also
# sets `$settings_path`, the module's `claude.code.settingsPath` relative to
# the checkout.
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
refresh() {
  local -a shell_vars=("${!DEVENV_@}")
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
code=0
if [ -n "$errlog" ]; then
  (refresh) </dev/null >"$errlog" 2>&1 || code=$?
else
  (refresh) </dev/null >&2 || code=$?
fi

# 128 and up: devenv was stopped by a signal (Ctrl-C, SIGTERM, an OOM
# kill). The developer meant to stop, or the machine did: start nothing,
# and pass the code on. Its output isn't shown; it is only the interruption.
if [ "$code" -ge 128 ]; then
  echo "coldlogic: not starting claude: the refresh of the generated files in $checkout was interrupted (devenv tasks run devenv:files exited $code)." >&2
  exit "$code"
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
