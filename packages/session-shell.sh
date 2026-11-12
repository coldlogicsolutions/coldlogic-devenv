#!/usr/bin/env bash
# What a `devenv shell` does differently inside a Claude Code session, for
# the tasks in devenv.nix to call and go by its exit code. Built as
# `coldlogic-session-shell` (session-shell.nix), whose build runs the cases
# in session-shell-test.sh.
#
#   own-checkout                 10: this checkout isn't the one the session
#                                reads its Claude Code files from.
#                                0: it is, or that can't be told. Callers
#                                treat any code but 10 (a crash's 1
#                                included) as a doubt.
#   notice <key> <text>          Prints <text> on stderr unless this session
#                                was already shown it here. 0; 2 on bad usage.
#   clear <key>                  Forgets what was shown for <key>. 0; 2 on
#                                bad usage.
#   skip-hooks-install [<hook>...]
#                                The status of devenv:git-hooks:install.
#                                0: skip it (a session that can't write the
#                                hooks directory). 1: run it. Prints nothing.
#   hooks-check [<hook>...]      Says when commits here run no <hook>, via
#                                notice. Always 0.
#
# The hooks default to pre-commit. Nothing here writes git config or under a
# git directory.
set -euo pipefail

usage() {
  echo "usage: coldlogic-session-shell own-checkout | notice <key> <text> | clear <key> | skip-hooks-install [<hook>...] | hooks-check [<hook>...]" >&2
  exit 2
}

# Whether this is a Claude Code session: the script's only session test, and
# the only place it reads the session variables. It is the same condition as
# `inSession` in devenv.nix, which a script can't use: the `claude` wrapper's
# marker (packages/claude-wrapper.sh), or Claude Code's own variable, for a
# session the wrapper didn't start. Change both together, and never make
# either narrower than CLAUDECODE alone.
in_session() {
  [ -n "${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "${CLAUDECODE:-}" ]
}

# Every doubt answers "this is the session's own checkout", so a file that
# matters is still reported. Only two paths that resolve and differ exit 10,
# a code no failing command gives by accident (set -e's exit is 1).
own_checkout() {
  in_session || exit 0
  [ -n "${COLDLOGIC_SESSION_ROOT:-}" ] || exit 0
  [ -n "${DEVENV_ROOT:-}" ] || exit 0
  local session here
  session=$(CDPATH='' cd -- "$COLDLOGIC_SESSION_ROOT" 2>/dev/null && pwd -P) || exit 0
  here=$(CDPATH='' cd -- "$DEVENV_ROOT" 2>/dev/null && pwd -P) || exit 0
  if [ -n "$session" ] && [ -n "$here" ] && [ "$session" != "$here" ]; then
    exit 10
  fi
  exit 0
}

# A key names a file in the notices directory and nothing else: no `/`, no
# `..`, no leading `-` or `.`.
valid_key() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

notices_dir() {
  printf '%s\n' "${DEVENV_STATE:-${DEVENV_ROOT:-.}/.devenv/state}/coldlogic-notices"
}

# The text is printed before any write is tried, so a refused or failed write
# can't lose it. Only a record holding exactly this session and this text is
# silent. Nothing here fails but bad usage.
notice() {
  [ "$#" = 2 ] || usage
  local key=$1 text=$2
  valid_key "$key" || usage
  # Reading the record back with $(cat) drops trailing newlines, so drop them
  # from the text first: else a text ending in one never matches its record
  # and is printed on every shell.
  while [[ $text == *$'\n' ]]; do
    text=${text%$'\n'}
  done
  if ! in_session; then
    printf '%s\n' "$text" >&2 || true
    return 0
  fi
  local dir record tmp
  dir=$(notices_dir)
  record="${CLAUDE_CODE_SESSION_ID:--}"$'\n'"$text"
  if [ "$(cat -- "$dir/$key" 2>/dev/null || true)" = "$record" ]; then
    return 0
  fi
  printf '%s\n' "$text" >&2 || true
  tmp="$dir/.$key.$$"
  if ! {
    mkdir -p -- "$dir" 2>/dev/null &&
      printf '%s\n' "$record" 2>/dev/null >"$tmp" &&
      mv -f -- "$tmp" "$dir/$key" 2>/dev/null
  }; then
    rm -f -- "$tmp" 2>/dev/null || true
  fi
  return 0
}

clear_key() {
  [ "$#" = 1 ] || usage
  valid_key "$1" || usage
  rm -f -- "$(notices_dir)/$1" 2>/dev/null || true
  return 0
}

# The hooks directory git resolves for $DEVENV_ROOT (it follows
# core.hooksPath). Only reads.
hooks_dir() {
  git -C "$DEVENV_ROOT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null
}

# can_write <path>: whether <path>, or where it doesn't exist yet its nearest
# existing parent, is writable.
can_write() {
  local path=$1 up
  while [ ! -e "$path" ]; do
    up=$(dirname -- "$path")
    [ "$up" != "$path" ] || break
    path=$up
  done
  [ -w "$path" ]
}

# install_blocked <dir> <hook>...: true only in a session where <dir>, or an
# expected hook already in it, can't be written.
install_blocked() {
  local dir=$1 hook
  shift
  in_session || return 1
  can_write "$dir" || return 0
  for hook in "$@"; do
    if [ -e "$dir/$hook" ] && [ ! -w "$dir/$hook" ]; then
      return 0
    fi
  done
  return 1
}

# Exit 0 means "skip the install", so every error and every doubt exits 1,
# which runs devenv's install as it is defined. Outside a session it never
# exits 0.
skip_hooks_install() {
  [ "$#" -gt 0 ] || set -- pre-commit
  [ -n "${DEVENV_ROOT:-}" ] || exit 1
  local dir
  dir=$(hooks_dir) || exit 1
  [ -n "$dir" ] || exit 1
  if install_blocked "$dir" "$@"; then
    exit 0
  fi
  exit 1
}

# A worktree whose commits will run no hook is always told; with every
# expected hook in place nothing is printed.
hooks_check() {
  [ "$#" -gt 0 ] || set -- pre-commit
  [ -n "${DEVENV_ROOT:-}" ] || exit 0
  local dir hook text
  dir=$(hooks_dir) || exit 0
  [ -n "$dir" ] || exit 0
  local missing=()
  for hook in "$@"; do
    if ! { [ -f "$dir/$hook" ] && [ -x "$dir/$hook" ]; }; then
      missing+=("$hook")
    fi
  done
  if [ "${#missing[@]}" = 0 ]; then
    clear_key hooks-missing
    exit 0
  fi
  if in_session; then
    text="coldlogic: commits here run no ${missing[*]} hook: there is none in $dir, and this Claude Code session can't install one there. Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell."
  else
    text="coldlogic: commits here run no ${missing[*]} hook: there is none in $dir, and the install didn't add one."
  fi
  notice hooks-missing "$text"
  exit 0
}

cmd="${1:-}"
[ "$#" = 0 ] || shift
case "$cmd" in
  own-checkout)
    [ "$#" = 0 ] || usage
    own_checkout
    ;;
  notice) notice "$@" ;;
  clear) clear_key "$@" ;;
  skip-hooks-install) skip_hooks_install "$@" ;;
  hooks-check) hooks_check "$@" ;;
  *) usage ;;
esac
