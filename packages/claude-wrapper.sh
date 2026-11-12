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
#                              with no .claude/settings.json
#   COLDLOGIC_WRAPPERS_RUN     the wrappers already run in this launch, which
#                              are never started again
# It sets, for the real `claude`:
#   COLDLOGIC_DEVENV_SESSION=1, which marks the session and all it runs
#   COLDLOGIC_WRAPPERS_RUN, with its own path added
#
# Exit codes: Claude Code's own; 1 when it refuses to start a session with
# no settings; 127 when there is no Claude Code behind it on PATH.
#
# It uses only bash builtins, `git` (`$git_bin`, a store path in the built
# application) and `devenv` (the developer's own, from PATH).
set -euo pipefail

self="${BASH_SOURCE[0]}"
if [ "${self#/}" = "$self" ]; then
  self="$PWD/$self"
fi
git_bin="${git_bin:-git}"
seen="${COLDLOGIC_WRAPPERS_RUN:-}"

# Read before the marker is exported below. CLAUDECODE is not part of this
# test: an IDE extension sets it in its terminals, where no session runs yet
# and the refresh must.
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

# The checkout: the top of the git checkout here when it is a devenv
# project, else the shell's own. Not DEVENV_ROOT first: a shell entered in
# the main checkout and moved into a worktree still names the main checkout,
# and `claude` reads the worktree's settings.
top="$("$git_bin" rev-parse --show-toplevel 2>/dev/null)" || top=""
checkout=""
if [ -n "$top" ] && { [ -f "$top/devenv.nix" ] || [ -f "$top/devenv.yaml" ]; }; then
  checkout="$top"
elif [ -n "${DEVENV_ROOT:-}" ] && [ -d "$DEVENV_ROOT" ]; then
  checkout="$DEVENV_ROOT"
fi

if [ -z "$checkout" ]; then
  echo "coldlogic: no devenv project found from $PWD, so the generated files weren't refreshed." >&2
  exec "$real" "$@"
fi

# The refresh, in a subshell, so this directory and environment never
# change. The two variables are cleared so the shell's session test lets the
# file tasks run. It can't read the wrapper's input (a prompt piped to
# `claude -p`) or write to its output (often captured); its stderr is what
# the developer needs when it fails.
code=0
(cd "$checkout" && unset CLAUDECODE COLDLOGIC_DEVENV_SESSION && exec devenv --quiet tasks run devenv:files) </dev/null >/dev/null || code=$?

# A refresh that succeeds is trusted: nothing printed, the link not looked
# at. One that fails starts a session only with settings in place.
if [ "$code" != 0 ]; then
  settings="$checkout/.claude/settings.json"
  if [ -e "$settings" ]; then
    echo "coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code). Starting claude with the settings already there, which may be out of date. To see why, run there: devenv shell" >&2
  elif [ -n "${COLDLOGIC_START_WITHOUT_SETTINGS:-}" ]; then
    echo "coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing. Starting claude anyway, as COLDLOGIC_START_WITHOUT_SETTINGS is set: this session has none of the module's guard hook, sandbox settings or permissions." >&2
  else
    echo "coldlogic: not starting claude. Couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing, so the session would have none of the module's guard hook, sandbox settings or permissions. To see why, run there: devenv shell. To start it anyway: COLDLOGIC_START_WITHOUT_SETTINGS=1 claude" >&2
    exit 1
  fi
fi

exec "$real" "$@"
