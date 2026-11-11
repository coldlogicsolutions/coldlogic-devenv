#!/usr/bin/env bash
# The status checks of devenv:files and devenv:files:cleanup inside a Claude
# Code session, and the comparison behind coldlogic:generated-files-stale
# (devenv.nix calls it only in a session, from $DEVENV_ROOT).
#
#   coldlogic-session-relink [--check-only] [--print] [--state <files.json>]
#                            <path> <target> [<path> <target> ...]
#
# A <path> is stale when it is missing or a link to anything but <target>. A
# <path> that exists and isn't a link is never stale: it is left to
# devenv:files to report. By default, for each stale <path>, it tries the
# relink itself, so that the sandbox, not a guess, decides whether the
# session may write it. The relink is atomic: a new link at a temporary name
# beside <path>, renamed over it. `ln -sf` would unlink the old link first,
# and the sandbox lets that unlink through while denying the create, which
# deleted the very link this protects (#68). If any step fails, the temporary
# link is removed and <path> stays stale, with its old link still in place. A
# link that resolves to a directory is stale and left alone, since renaming
# over it would move the new link into the directory.
#
# Before that, for every <path>, it removes temporary links left by a shell
# killed between the link and the rename: only ones into /nix/store, whose
# process is gone and which are more than a minute old.
#
# --check-only: no relink and no sweep; only compares.
# --print: print the stale <path>s, one per line.
# --state: devenv's files.json (read by devenv:files:cleanup) is checked too.
#   Cleanup removes the link at each recorded entry that isn't exactly a
#   current name, so an entry naming a <path> under another spelling marks a
#   skip. So does a state file that can't be read as {"managedFiles":
#   [<string>...]}, since it can't be checked.
#
# Exits 1 (run the task) only when nothing is stale and no skip is marked,
# and 0 (skip it) when something is. Anything else is an error: 2 on bad
# usage, 3 when a command fails. Callers must run the task only on 1. Needs
# GNU realpath (coreutils) and find (findutils).
set -eEuo pipefail
trap 'exit 3' ERR

usage() {
  echo "usage: coldlogic-session-relink [--check-only] [--print] [--state <files.json>] <path> <target> ..." >&2
  exit 2
}

check_only=""
print=""
state=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) check_only=1 ;;
    --print) print=1 ;;
    --state)
      [ $# -ge 2 ] || usage
      state="$2"
      shift
      ;;
    --) shift && break ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done
[ $(($# % 2)) -eq 0 ] || usage

# Whether recorded entry $1 names current name $2 under another spelling.
# Paths are normalised without resolving any link. A relative current name
# is taken from $PWD. The entry is read both ways devenv could join it to
# the checkout, "$PWD/<entry>" and, when it starts with /, as it is, so
# this doesn't depend on which one cleanup uses.
#
# It runs as an `if` condition, where bash ignores errexit and the ERR trap,
# so a failed realpath exits explicitly.
respells() {
  local entry="$1" name="$2" path joined
  [ "$entry" != "$name" ] || return 1
  case "$name" in
    /*) path="$(realpath -ms -- "$name")" || exit 3 ;;
    *) path="$(realpath -ms -- "$PWD/$name")" || exit 3 ;;
  esac
  joined="$(realpath -ms -- "$PWD/$entry")" || exit 3
  [ "$joined" != "$path" ] || return 0
  case "$entry" in
    /*)
      joined="$(realpath -ms -- "$entry")" || exit 3
      [ "$joined" != "$path" ] || return 0
      ;;
  esac
  return 1
}

# Whether leftover temporary link $1 may go: its PID suffix isn't this run's,
# its process is gone, and the link is more than a minute old, so a shell
# that has just made it (or whose PID was reused) still has time to rename
# it. Only "No such process" counts as gone: the sandbox can refuse to signal
# a running process.
abandoned() {
  local pid="${1##*.}" err
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1
  if err="$(LC_ALL=C kill -0 "$pid" 2>&1)"; then
    return 1
  fi
  case "$err" in *"No such process"*) ;; *) return 1 ;; esac
  [ -n "$(find "$1" -maxdepth 0 -type l -mmin +1 2>/dev/null)" ]
}

sweep() {
  local dir base old
  dir="$(dirname -- "$1")"
  base="$(basename -- "$1")"
  for old in "$dir/.$base.coldlogic-relink."*; do
    [ -L "$old" ] || continue
    case "$(readlink -- "$old" 2>/dev/null || true)" in
      /nix/store/*) ;;
      *) continue ;;
    esac
    if abandoned "$old"; then
      rm -f -- "$old" 2>/dev/null || true
    fi
  done
}

skip=""
stale=()
pairs=("$@")

if [ -n "$state" ] && [ -e "$state" ]; then
  # Slurped, so an empty file or several documents count as the wrong shape.
  if ! entries="$(jq -rs '
      if length == 1 and (.[0] | type) == "object"
        and (.[0].managedFiles | type) == "array"
        and all(.[0].managedFiles[]; type == "string")
      then .[0].managedFiles[] else error("unexpected shape") end
    ' "$state" 2>/dev/null)"; then
    skip=1
    entries=""
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    for ((i = 0; i < ${#pairs[@]}; i += 2)); do
      if respells "$entry" "${pairs[i]}"; then
        skip=1
      fi
    done
  done <<<"$entries"
fi

for ((i = 0; i < ${#pairs[@]}; i += 2)); do
  f="${pairs[i]}"
  want="${pairs[i + 1]}"
  if [ -z "$check_only" ]; then
    sweep "$f"
  fi
  if [ "$(readlink -- "$f" 2>/dev/null || true)" = "$want" ]; then
    continue
  fi
  if [ ! -L "$f" ] && [ -e "$f" ]; then
    continue
  fi
  if [ -n "$check_only" ] || [ -d "$f" ]; then
    stale+=("$f")
    continue
  fi
  dir="$(dirname -- "$f")"
  tmp="$dir/.$(basename -- "$f").coldlogic-relink.$$"
  made=""
  if mkdir -p -- "$dir" 2>/dev/null && ln -s -- "$want" "$tmp" 2>/dev/null; then
    made=1
    if mv -f -- "$tmp" "$f" 2>/dev/null; then
      continue
    fi
  fi
  # Only a link this run made; a name it found already taken isn't its own.
  if [ -n "$made" ]; then
    rm -f -- "$tmp" 2>/dev/null || true
  fi
  stale+=("$f")
done

if [ -n "$print" ] && [ ${#stale[@]} -gt 0 ]; then
  printf '%s\n' "${stale[@]}"
fi
if [ ${#stale[@]} -gt 0 ] || [ -n "$skip" ]; then
  exit 0
fi
exit 1
