#!/usr/bin/env bash
# The session's own linking of the generated files, run by the
# coldlogic:session-files task, and the comparison behind
# coldlogic:generated-files-stale. devenv.nix calls it only in a Claude Code
# session, from $DEVENV_ROOT.
#
#   coldlogic-session-relink [--check-only] [--print] [--]
#                            <path> <target> [<path> <target> ...]
#
# A <path> is stale when it is missing or a link to anything but <target>. A
# <path> that exists and isn't a link (a real file or directory) is a
# conflict: it is never touched, only reported, as devenv:files would report
# it from a terminal shell. By default, for each stale <path>,
# it tries the relink itself, so the sandbox decides whether the session may
# write it. The relink is atomic: a new link at a temporary name beside
# <path>, renamed over it. `ln -sf` would unlink the old link first, and the
# sandbox lets that unlink through while denying the create, which deleted
# the very link this protects (#68). If any step fails, the temporary link is
# removed and <path> stays stale, with its old link still in place, and the
# next <path> is still tried. A link that resolves to a directory is stale and
# left alone, since renaming over it would move the new link into the
# directory.
#
# Before that, for every <path>, it removes temporary links left by a shell
# killed between the link and the rename: only ones into /nix/store, whose
# process is gone and which are more than a minute old.
#
# --check-only: no relink and no sweep; only compares.
# --print: print each <path> that isn't current, one per line, as
#   `missing <path>` when nothing is there, `stale <path>` when a link to
#   something else is, or `conflict <path>` when something that isn't a link is.
#
# Exits 1 when every <path> is current, and 0 when any is missing, stale or a
# conflict. Anything else is an
# error: 2 on bad usage, 3 when a command fails. Needs GNU coreutils and
# findutils.
set -eEuo pipefail
trap 'exit 3' ERR

usage() {
  echo "usage: coldlogic-session-relink [--check-only] [--print] [--] <path> <target> ..." >&2
  exit 2
}

check_only=""
print=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) check_only=1 ;;
    --print) print=1 ;;
    --) shift && break ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done
[ $(($# % 2)) -eq 0 ] || usage

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

stale=()
kinds=()
pairs=("$@")

for ((i = 0; i < ${#pairs[@]}; i += 2)); do
  f="${pairs[i]}"
  want="${pairs[i + 1]}"
  if [ -z "$check_only" ]; then
    sweep "$f"
  fi
  if [ "$(readlink -- "$f" 2>/dev/null || true)" = "$want" ]; then
    continue
  fi
  # Something that isn't a link: never touched, only reported.
  if [ ! -L "$f" ] && [ -e "$f" ]; then
    stale+=("$f")
    kinds+=(conflict)
    continue
  fi
  # Taken before any relink attempt; a failed attempt leaves $f as it was.
  kind=stale
  [ -L "$f" ] || kind=missing
  if [ -n "$check_only" ] || [ -d "$f" ]; then
    stale+=("$f")
    kinds+=("$kind")
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
  kinds+=("$kind")
done

if [ -n "$print" ]; then
  for ((i = 0; i < ${#stale[@]}; i++)); do
    printf '%s %s\n' "${kinds[i]}" "${stale[i]}"
  done
fi
if [ ${#stale[@]} -gt 0 ]; then
  exit 0
fi
exit 1
