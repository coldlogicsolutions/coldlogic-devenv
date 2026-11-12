#!/usr/bin/env bash
# Removes a repository's merged, idle worktrees and branches, outside the
# Claude Code sandbox (#73). The developer profile runs it from the
# SessionStart and Stop hooks and from a terminal `devenv shell`.
#
#   coldlogic-prune-worktrees [--dry-run] [--background] [--hook]
#                             [--session-dir <dir>] [--idle-minutes <n>]
#
# The repository is the one <dir> (the session dir, else $PWD) is in; run
# from a linked worktree, it acts on the same worktrees as from the main
# checkout. Candidates are the linked worktrees under <main>.worktrees/ or
# <main>/.claude/worktrees/, and the local branches no worktree has checked
# out, except the default branch. A worktree is removed only when it is:
#   - not locked, and clean: no staged, unstaged or untracked change, no
#     skip-worktree or assume-unchanged file, no ignored file outside a list
#     of regenerable or generated ones (at the top: target, node_modules,
#     result* links into /nix/store, .devenv.flake.nix and the other files
#     devenv and openspec generate;
#     anywhere: .direnv, __pycache__, and a .devenv whose state dirs hold
#     only devenv's bookkeeping, not a service's data; `git worktree remove`
#     deletes ignored files, so `.env` keeps it), and no rebase, merge,
#     cherry-pick, revert or bisect in progress, checked without writing its
#     index;
#   - not in use: neither the session dir nor $PWD is in it, no process
#     lsof can see has its working directory in it (lsof, under a timeout, and
#     again just before the removal, with HEAD and its branch re-read and
#     the clean check run again too;
#     when lsof fails, nothing is removed), and nothing in its git dir or
#     its .devenv
#     (`.devenv`, `.devenv/state`, `.devenv/profiles/*` and
#     `.devenv/profiles/*/state`, which every `devenv shell` touches) changed
#     within the idle period (360 minutes by default);
#   - in main: HEAD is an ancestor of origin/HEAD (else origin/main), or a
#     PR merged into the default branch has its branch as head and HEAD as
#     (or an ancestor of) its head commit, which covers squash merges; for a
#     detached HEAD, the head commit must be HEAD itself. Either way, every
#     commit in its HEAD reflog must be held by a ref or a merged PR's head
#     (checked again before removal), so work abandoned there isn't lost.
#     The merged PRs come
#     from one `gh-app pr list` per run, made when the first candidate needs
#     it; when it fails, nothing counts as merged by a PR. It never fetches.
#     This check runs first, so an unmerged worktree costs no status scan.
# Removal is `git worktree remove` without --force, then the branch, unless
# another worktree holds it (read again just before the decision), it is
# long-lived (the default branch, or main, master, develop, dev, staging,
# production, prod, release/*, hotfix/*, in any case), its name has a `]` (which
# `git config --remove-section` can't address), or no merged PR covers it (the exact head, or a head
# containing commits past origin/main), only if it still points at the
# commit that was checked (`update-ref -d <ref> <old>`), and its config
# section. `git worktree prune` runs only when every worktree whose
# directory is gone lies under the two roots, and its root and parent dir
# still exist, the root on the main checkout's device, nothing is at any
# prunable one's path, and no gone one's admin dir holds something prune
# would lose (staged changes, an unheld HEAD or HEAD reflog commit: a
# worktree moved by hand looks gone). A branch with no worktree is deleted only when it isn't
# long-lived, is idle (its reflog), and is, by name and commit, the exact
# head of a PR merged into the default branch; being an ancestor of main
# isn't enough.
#
# --dry-run prints `worktree <path> (<branch>)` and `branch <name>` for what
#   would go (a worktree's branch with it), and why each other candidate stays (on stderr), and writes
#   nothing.
# --background starts the run detached (nohup, stdin from /dev/null, output
#   to the log) and returns at once, unless a run started within the last 10
#   minutes. It stamps the start before detaching. With a fresh stamp it
#   exits before forking git or jq, finding the common dir from the session
#   dir's .git with builtins (with --hook, $CLAUDE_PROJECT_DIR's, but only
#   when the input's .cwd is in it or there is none).
# --hook reads Claude Code's hook input on stdin and takes its .cwd as the
#   session dir (else $CLAUDE_PROJECT_DIR, else $PWD).
#
# In the git common dir: coldlogic-prune.lock/ (one run at a time; a lock
# whose process is gone or started at another time than recorded (a reused
# pid), or that names none and is over an hour old, is taken over, by one
# run at a time, under coldlogic-prune.lock.takeover/; a live owner's never
# is, and a run skipped for one over an hour old logs it once; a run that
# can't write its owner removes the lock again and logs that once),
# coldlogic-prune.stamp (the last background start or completed run),
# coldlogic-prune.log (each removal with its commit and how to restore it,
# and the intent line written before it, kept for good unless a later line
# repeats it, and each reason for keeping a candidate when it changes, cut
# to the last 1000 such lines) and
# coldlogic-prune.kept (the last run's reasons, to tell what changed). It
# prints nothing else, except one line on stderr when the log can't be used
# (below), and exits 0 except on bad usage (2).
#
# A sandboxed session can write the common dir too, and this runs outside
# the sandbox (#82), so it never writes through a link or into a file that
# isn't a regular one of the user's with a single name: such a log is left
# alone, and the run removes nothing (no removal without its restore
# record), printing one line on stderr; a dry run is unaffected. Each
# removal's "removing ...; to restore: ..." line is written before the
# removal, and one that can't be written is skipped, kept for the next run.
# A kept file or lock owner that isn't such a file is neither read nor
# followed. The log is made
# with noclobber (O_EXCL, which a link fails), and opened again if a trim
# by another run has replaced it; the stamp, kept file and trimmed log are
# written to a mktemp file renamed into place. Paths and names in log lines
# are shell-quoted (%q); a git error or lock owner is cleaned instead
# (control characters to spaces, $( and backquotes defused).
set -euo pipefail

usage() {
  echo "usage: coldlogic-prune-worktrees [--dry-run] [--background] [--hook] [--session-dir <dir>] [--idle-minutes <n>]" >&2
  exit 2
}

dry_run=""
background=""
hook=""
session_dir=""
idle_minutes=360
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --background) background=1 ;;
    --hook) hook=1 ;;
    --session-dir)
      [ $# -ge 2 ] || usage
      session_dir="$2"
      shift
      ;;
    --idle-minutes)
      [ $# -ge 2 ] || usage
      idle_minutes="$2"
      shift
      ;;
    *) usage ;;
  esac
  shift
done
# No leading zero: bash arithmetic reads 010 as octal 8, and 08 not at all.
# At most 6 digits (about two years), so minutes * 60 can't overflow.
case "$idle_minutes" in '' | *[!0-9]* | 0?* | ???????*) usage ;; esac

# macOS keeps lsof in /usr/sbin, which a hook's PATH may lack. Last, so a
# PATH entry (the tests' stub) wins.
PATH="$PATH:/usr/sbin"
# A hook or a git alias could hand these down; they would point every git
# call below at one repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

# A file's mtime in epoch seconds, as a base-10 number arithmetic can use
# (anything else fails). GNU stat only: the package's runtimeInputs hold
# coreutils, and the script needs its `mv -fT` and `realpath -m` anyway.
mtime() {
  local t
  t="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1
  case "$t" in '' | *[!0-9]*) return 1 ;; esac
  echo "$((10#$t))"
}
# Whether $1 is a regular file of the user's, not a link, with one name (a
# hard link would let a write reach another file). GNU stat, as mtime's.
own_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] &&
    [ "$(stat -c %h -- "$1" 2>/dev/null)" = 1 ]
}
printf -v now '%(%s)T' -1

# The git common dir of checkout $1, from its .git with builtins only, into
# fc. Fails on anything unusual; the full lookup below then decides.
fast_common() {
  local d="$1" line g c
  if [ -d "$d/.git" ]; then
    fc="$d/.git"
    return 0
  fi
  [ -f "$d/.git" ] || return 1
  IFS= read -r line <"$d/.git" || return 1
  g="${line#gitdir: }"
  [ "$g" != "$line" ] || return 1
  case "$g" in /*) ;; *) g="$d/$g" ;; esac
  if [ -f "$g/commondir" ]; then
    IFS= read -r c <"$g/commondir" || return 1
    case "$c" in /*) fc="$c" ;; *) fc="$g/$c" ;; esac
  else
    fc="$g"
  fi
}

input=""
if [ -n "$hook" ]; then
  IFS= read -r -d '' input || true
fi

# The Stop hook runs after every turn: when the stamp is fresh, exit before
# forking git or jq. A hook's run acts on its .cwd, so the project dir
# stands in for it only when .cwd (read with a builtin match) is in the
# project dir, or the input has none (the run then falls back to the
# project dir too). Anything else takes the full lookup below, which reads
# the stamp of the repository the run acts on.
fast_dir=""
if [ -n "$background" ] && [ -z "$dry_run" ]; then
  fast_dir="$session_dir"
  if [ -z "$fast_dir" ] && [ -n "$hook" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    fast_re='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
    fast_proj="${CLAUDE_PROJECT_DIR%/}"
    if [[ $input =~ $fast_re ]]; then
      fast_cwd="${BASH_REMATCH[1]}"
      if [ "$fast_cwd" = "$fast_proj" ] || [ "${fast_cwd#"$fast_proj"/}" != "$fast_cwd" ]; then
        fast_dir="$fast_proj"
      fi
    elif [[ $input != *'"cwd"'* ]]; then
      fast_dir="$fast_proj"
    fi
  fi
  if [ -n "$fast_dir" ] && fast_common "$fast_dir" && own_file "$fc/coldlogic-prune.stamp" &&
    t="$(mtime "$fc/coldlogic-prune.stamp")" && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt 600 ]; then
    exit 0
  fi
fi

if [ -n "$hook" ]; then
  if [ -z "$session_dir" ]; then
    session_dir="$(jq -r '.cwd // empty | strings' <<<"$input" 2>/dev/null || true)"
  fi
  [ -n "$session_dir" ] || session_dir="${CLAUDE_PROJECT_DIR:-}"
fi
[ -n "$session_dir" ] || session_dir="$PWD"
start_pwd="$PWD"

# Not in a git repository, or a bare one: nothing to do.
common="$(git -C "$session_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ "$(git -C "$session_dir" rev-parse --is-bare-repository 2>/dev/null)" = false ] || exit 0

log="$common/coldlogic-prune.log"
stamp="$common/coldlogic-prune.stamp"
lock="$common/coldlogic-prune.lock"
kept_file="$common/coldlogic-prune.kept"

# $1 shell-quoted, for a path or name in a log line: no line then carries a
# live $( ) or backquote, whatever a branch or directory is called.
q() { printf '%q' "$1"; }

# $1 as free text for a log line: control characters, newlines too, become
# spaces, and a backquote or $( is defused, so the line stays readable (%q
# would escape every space) and carries no live substitution.
clean() {
  local s="${1//[[:cntrl:]]/ }"
  # shellcheck disable=SC2016 # literal text, never expanded
  local bq='`' sq="'" dc='$(' dd='$ ('
  s="${s//"$bq"/"$sq"}"
  printf '%s' "${s//"$dc"/"$dd"}"
}

# Makes file $1 if nothing, not even a dangling link, is there: noclobber
# opens it with O_EXCL, which fails on a link. Mode 600.
make_new() {
  (
    umask 077
    set -o noclobber
    : >"$1"
  ) 2>/dev/null
}

# Writes file $1 from stdin, atomically: into a new mktemp file beside it,
# then renamed over it, which replaces a link rather than following it (-T:
# nor moves into a directory there). Reads all of stdin whatever fails, so
# the writer feeding it never dies of SIGPIPE, which under pipefail and set
# -e would end the run non-zero.
replace_file() {
  local tmp
  # Mode 600 whatever the umask, so this run can write it.
  if ! tmp="$(
    umask 077
    mktemp "$1.XXXXXX" 2>/dev/null
  )"; then
    cat >/dev/null 2>&1 || true
    return 0
  fi
  if cat 2>/dev/null >"$tmp"; then
    mv -fT -- "$tmp" "$1" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
  else
    cat >/dev/null 2>&1 || true
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

# Opens the log, for appending, on log_fd, and sets log_ok: made when
# absent, used only when own_file. Fails, with no log_fd, for anything else:
# a run that can't record its removals makes none (log_unusable).
log_ok=""
open_log() {
  [ -z "${log_fd-}" ] || { exec {log_fd}>&-; } 2>/dev/null || true
  log_fd=""
  log_ok=""
  if [ ! -e "$log" ] && [ ! -L "$log" ]; then
    make_new "$log" || true
  fi
  if own_file "$log" && { exec {log_fd}>>"$log"; } 2>/dev/null; then
    log_ok=1
  else
    log_fd=""
    return 1
  fi
}
log_unusable() {
  echo "coldlogic-prune-worktrees: removed nothing: the log $(q "$log") isn't a regular file of yours with one name (a link, a hard link or another user's file, from a sudo run, say), so removals couldn't be logged; remove or fix that file" >&2
  exit 0
}

# Stamps a run: a new empty file renamed over the stamp, so a link there,
# soft or hard, is replaced rather than touched through.
touch_stamp() {
  local tmp
  tmp="$(mktemp "$stamp.XXXXXX" 2>/dev/null)" || return 0
  mv -fT -- "$tmp" "$stamp" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
}

if [ -n "$background" ] && [ -z "$dry_run" ]; then
  # A stamp that is a link, or another user's, counts as none: it's replaced.
  if own_file "$stamp" && t="$(mtime "$stamp")" && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt 600 ]; then
    exit 0
  fi
  # Stamped now, so the hooks and shells that start while this run works
  # don't each start one.
  touch_stamp
  open_log || log_unusable
  {
    nohup "$BASH" "$0" --session-dir "$session_dir" --idle-minutes "$idle_minutes" \
      </dev/null >&"$log_fd" 2>&1 &
  } 2>/dev/null || true
  exit 0
fi

[ -n "$dry_run" ] || open_log || log_unusable

# Appends line $1 to the log; fails when it wasn't recorded (the log can't
# be used now, or the write failed).
log_line() {
  # Another run's trim renames a new file over the log, leaving this
  # descriptor on the old one: open the path again (checked as at the
  # start) when it no longer names the file open here.
  if ! [ "$log" -ef "/dev/fd/$log_fd" ] 2>/dev/null; then
    open_log || {
      exec {log_fd}>/dev/null
      return 1
    }
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" 1>&"$log_fd" 2>/dev/null
}
say() {
  if [ -n "$dry_run" ]; then
    echo "$*" >&2
  else
    log_line "$*" || true
  fi
}
# Records an intended removal before it is made: fails, and the caller skips
# the removal, when the line can't be written.
intend() {
  [ -n "$dry_run" ] || log_line "$*"
}

# Why each candidate was kept: the last run's (prev_kept, from kept_file)
# and this run's (kept). `keep <key> <message>` records one and logs it only
# when it differs from the last run's, so an hourly run doesn't log the same
# reasons again. A dry run prints every one.
declare -A prev_kept=() kept=()
# Not through a link: a run that skips writes the reasons back, so a link to
# a file the sandbox can't read would copy it where the sandbox can.
if [ -z "$dry_run" ] && own_file "$kept_file"; then
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] || prev_kept["$k"]="$v"
  done <"$kept_file" 2>/dev/null || true
fi
keep() {
  local k="${1//[$'\t\n']/ }" m="${2//[$'\t\n']/ }"
  # Once per run too: a branch can be kept after its worktree's removal and
  # again by the orphan sweep.
  if [ "${kept[$k]-}" = "$m" ]; then
    return 0
  fi
  if [ -n "$dry_run" ]; then
    echo "$m" >&2
  elif [ "${prev_kept[$k]-}" != "$m" ] && ! log_line "$m"; then
    # Not logged: left out of kept, so the next run logs it.
    return 0
  fi
  kept["$k"]="$m"
}
# Writes this run's reasons to kept_file.
save_kept() {
  local k
  {
    # Each array expansion is guarded: bash before 4.4 calls an empty one
    # unbound under set -u.
    for k in ${kept[@]+"${!kept[@]}"}; do
      printf '%s\t%s\n' "$k" "${kept[$k]}"
    done
  } | replace_file "$kept_file" || true
}

# The worktrees, from `git worktree list --porcelain`, into wt_paths,
# wt_heads, wt_branches (empty when detached) and wt_flags. The first is the
# main checkout.
parse_worktrees() {
  local list line path="" head="" branch="" flags=""
  wt_paths=()
  wt_heads=()
  wt_branches=()
  wt_flags=()
  list="$(git -C "$1" worktree list --porcelain 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      bare) flags+=" bare" ;;
      locked | "locked "*) flags+=" locked" ;;
      prunable | "prunable "*) flags+=" prunable" ;;
      "")
        if [ -n "$path" ]; then
          wt_paths+=("$path")
          wt_heads+=("$head")
          wt_branches+=("$branch")
          wt_flags+=("$flags")
        fi
        path="" head="" branch="" flags=""
        ;;
    esac
  done <<<"$list"$'\n'
}

parse_worktrees "$session_dir" || exit 0
[ ${#wt_paths[@]} -gt 0 ] || exit 0
case "${wt_flags[0]}" in *bare*) exit 0 ;; esac
main="${wt_paths[0]}"
main_real="$(realpath -e -- "$main" 2>/dev/null)" || exit 0
# Before the cd: a relative --session-dir is relative to where the run began.
session_real="$(realpath -m -- "$session_dir" 2>/dev/null || true)"
pwd_real="$(realpath -m -- "$start_pwd" 2>/dev/null || true)"
cd "$main_real" || exit 0
roots=("$(realpath -m -- "$main_real.worktrees")" "$(realpath -m -- "$main_real/.claude/worktrees")")
roots_desc="$(q "$main_real.worktrees") and $(q "$main_real/.claude/worktrees")"

# One run at a time. A lock whose owner is gone ("No such process": the
# sandbox, or another user, can refuse a signal to a live one), or that
# names no owner and is over an hour old, is taken over; a live owner's
# never is, however old. Taking over happens under a second lock, so two
# runs can't both judge the same lock stale and replace it, and the lock is
# judged again once that is held. The pid file holds a token unique to
# this run, then the run's process start time; the exit trap removes the
# lock only while it still holds the token. A pid whose process started at
# another time than recorded is a later process given the same pid (after a
# reboot, say), so its lock is stale too.
# A process's start time, tagged with its source: on Linux, the start time
# in clock ticks since boot, field 22 of /proc/<pid>/stat (exact, and not
# subject to clock changes as ps's lstart is); elsewhere (macOS) `ps -o
# lstart=`. Two start times are compared only when their tags match. The
# environment variable is for the tests.
proc_dir="${COLDLOGIC_PRUNE_PROC:-/proc}"
proc_start() {
  local s
  local -a f
  if [ -d "$proc_dir" ]; then
    IFS= read -r s <"$proc_dir/$1/stat" 2>/dev/null || return 1
    # Fields after the command name, which is in parentheses and may hold
    # spaces: the state is field 3, so the start time (22) is index 19.
    read -r -a f <<<"${s##*) }"
    [ -n "${f[19]-}" ] || return 1
    echo "ticks:${f[19]}"
  else
    s="$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" && [ -n "$s" ] || return 1
    echo "lstart:$s"
  fi
}
takeover="$lock.takeover"
token="$$-$(date +%s%N)"
my_start="$(proc_start $$ || true)"
# The lock's owner token and start time, into owner and owner_start. Read
# only from a file of the user's with one name: the owner reaches the log,
# so a pid planted as a link would copy its target's first line there. Any
# other pid counts as no owner recorded.
read_owner() {
  owner="" owner_start=""
  own_file "$lock/pid" || return 0
  { IFS= read -r owner && IFS= read -r owner_start; } 2>/dev/null <"$lock/pid" || true
}
lock_stale() {
  local pid err t start
  read_owner
  pid="${owner%%-*}"
  case "$pid" in
    '' | *[!0-9]*)
      # No owner recorded (a run died between mkdir and writing it).
      t="$(mtime "$lock")" && [ $((now - t)) -ge 3600 ]
      ;;
    *)
      # A live owner keeps it whatever its age; "operation not permitted"
      # means alive too.
      if ! err="$(LC_ALL=C kill -0 "$pid" 2>&1)"; then
        case "$err" in *"No such process"*) return 0 ;; esac
      fi
      if [ -n "$owner_start" ] && start="$(proc_start "$pid")" &&
        [ "${start%%:*}" = "${owner_start%%:*}" ] && [ "$start" != "$owner_start" ]; then
        return 0
      fi
      return 1
      ;;
  esac
}
# Writes this run's token and start time into the lock just made. When that
# fails, an ownerless lock would block every run for an hour: it is removed
# again, and lock_unwritable set.
lock_unwritable=""
write_owner() {
  # noclobber: the lock is new, so a pid file already there is a link put
  # there since, never to be written through.
  if (
    set -o noclobber
    printf '%s\n%s\n' "$token" "$my_start" >"$lock/pid"
  ) 2>/dev/null; then
    return 0
  fi
  rm -rf -- "$lock" 2>/dev/null || true
  lock_unwritable=1
  return 1
}
take_lock() {
  local t ok=""
  if mkdir -- "$lock" 2>/dev/null; then
    write_owner
    return
  fi
  lock_stale || return 1
  if ! mkdir -- "$takeover" 2>/dev/null; then
    # A taker that died holding it: the takeover takes milliseconds.
    t="$(mtime "$takeover")" && [ $((now - t)) -ge 60 ] || return 1
    rm -rf -- "$takeover" 2>/dev/null || true
    mkdir -- "$takeover" 2>/dev/null || return 1
  fi
  if lock_stale; then
    rm -rf -- "$lock" 2>/dev/null || true
    if mkdir -- "$lock" 2>/dev/null && write_owner; then
      ok=1
    fi
  fi
  rmdir -- "$takeover" 2>/dev/null || true
  [ -n "$ok" ]
}
# shellcheck disable=SC2329 # the exit trap calls it
release_lock() {
  read_owner
  if [ "$owner" = "$token" ]; then
    rm -rf -- "$lock" 2>/dev/null || true
  fi
}

if [ -z "$dry_run" ]; then
  if ! take_lock; then
    # Skipping because the owner can't be written, or for a lock this old,
    # is worth a line, once until it changes: the last run's reasons are
    # kept, so the next full run logs nothing new.
    for k in ${prev_kept[@]+"${!prev_kept[@]}"}; do
      kept["$k"]="${prev_kept[$k]}"
    done
    if [ -n "$lock_unwritable" ]; then
      keep lock-write "skipped: couldn't write the lock's owner in $(q "$lock")"
      save_kept
    elif t="$(mtime "$lock")" && [ $((now - t)) -ge 3600 ]; then
      read_owner
      by="with no owner recorded"
      [ -z "$owner" ] || by="$(clean "$owner")"
      keep lock "skipped: run $by has held the lock for over an hour"
      save_kept
    fi
    exit 0
  fi
  trap release_lock EXIT
fi
# Read again under the lock: the first read only found the main checkout, and
# a run that held the lock meanwhile may have removed worktrees since.
parse_worktrees "$main_real" || exit 0
[ ${#wt_paths[@]} -gt 0 ] || exit 0

# Whether path $2 is $1 or inside it.
contains() { [ "$2" = "$1" ] || [ "${2#"$1"/}" != "$2" ]; }
# Whether real path $1 lies below one of the roots.
under_roots() {
  local r
  for r in ${roots[@]+"${roots[@]}"}; do
    if [ "$1" != "$r" ] && contains "$r" "$1"; then
      return 0
    fi
  done
  return 1
}

# What main is: origin/HEAD's target, else origin/main. Without either,
# nothing counts as merged.
base=""
if ref="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" &&
  git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
  base="$ref"
elif git rev-parse -q --verify "refs/remotes/origin/main^{commit}" >/dev/null 2>&1; then
  base=refs/remotes/origin/main
fi
default_branch=main
[ -z "$base" ] || default_branch="${base#refs/remotes/origin/}"

# The PRs merged into the default branch, as `<headRefOid> <headRefName>`
# lines, from one gh-app call, made when the first candidate needs it.
# pr_state: "" not fetched, ok, none (no gh-app, or it failed).
pr_state=""
prs=""
# How many to ask for; the environment variable is for the tests.
pr_limit="${COLDLOGIC_PRUNE_PR_LIMIT:-200}"
case "$pr_limit" in '' | *[!0-9]* | 0*) pr_limit=200 ;; esac
fetch_prs() {
  local out
  pr_state=none
  if ! command -v gh-app >/dev/null 2>&1; then
    keep gh-app "gh-app isn't installed: nothing counts as merged by a PR"
    return
  fi
  if out="$(timeout 15 gh-app pr list --state merged --base "$default_branch" \
    --json headRefName,headRefOid,baseRefName --limit "$pr_limit" </dev/null 2>/dev/null)" &&
    prs="$(jq -r --arg b "$default_branch" '.[]
      | select(.baseRefName == $b and (.headRefOid | type) == "string" and (.headRefName | type) == "string")
      | "\(.headRefOid) \(.headRefName)"' <<<"$out" 2>/dev/null)"; then
    pr_state=ok
    if [ "$(jq length <<<"$out" 2>/dev/null)" = "$pr_limit" ]; then
      keep gh-app-limit "gh-app returned $pr_limit merged PRs, its limit: older ones don't count"
    fi
  else
    prs=""
    keep gh-app "gh-app failed: nothing counts as merged by a PR this run"
  fi
}

# Whether a PR merged into the default branch has commit $1 as its work: on
# branch $2, a PR with that head branch whose head commit is $1 or, unless
# $3 is "exact", contains it; detached ($2 empty), a PR whose head commit is
# $1. Returns 2 when the PRs aren't known.
merged_pr() {
  local c="$1" b="$2" mode="${3:-}" oid name
  [ -n "$pr_state" ] || fetch_prs
  [ "$pr_state" = ok ] || return 2
  while read -r oid name; do
    case "$oid" in '' | *[!0-9a-f]*) continue ;; esac
    if [ -n "$b" ] && [ "$name" != "$b" ]; then
      continue
    fi
    if [ "$oid" = "$c" ]; then
      return 0
    fi
    if [ -n "$b" ] && [ "$mode" != exact ] &&
      git merge-base --is-ancestor "$c" "$oid" 2>/dev/null; then
      return 0
    fi
  done <<<"$prs"
  return 1
}

# Whether worktree HEAD $1 (on branch $2, empty when detached) is in main.
# Sets `why` when it isn't.
in_main() {
  local rc=0
  if [ -z "$base" ]; then
    why="no origin/HEAD or origin/main"
    return 1
  fi
  if git merge-base --is-ancestor "$1" "$base" 2>/dev/null; then
    return 0
  fi
  merged_pr "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) why="not in $(q "$base"), and the merged PRs aren't known" ;;
    *) why="not in $(q "$base"), and no PR merged into $(q "$default_branch") has it" ;;
  esac
  return 1
}

# Whether devenv dotfile dir $1 holds only caches: its state dirs (`state`,
# and `profiles/*/state` with a profile) hold services' data, such as a
# postgres cluster, so anything there but devenv's and this module's own
# bookkeeping keeps the worktree. Sets `lost` to the first such entry.
devenv_disposable() {
  local s e
  for s in "$1/state" "$1"/profiles/*/state; do
    [ -d "$s" ] || continue
    for e in "$s"/* "$s"/.[!.]* "$s"/..?*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      case "${e##*/}" in
        tasks.db | tasks.db-wal | tasks.db-shm | tasks.db-journal | tasks.db.init.lock | \
          files.json | prek | coldlogic-freshness | coldlogic-openspec) ;;
        *)
          lost="$e"
          return 1
          ;;
      esac
    done
  done
}

# Whether $1 is a real directory (not a link) holding at least one entry and
# only regular files whose names match glob $2.
only_files() {
  local e n=0
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    # shellcheck disable=SC2053 # $2 is a glob.
    [ -f "$e" ] && [ ! -L "$e" ] && [[ "${e##*/}" == $2 ]] || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# Whether ignored path $2 (from git status, relative to worktree $1) is
# regenerable, or generated by devenv, so removing it loses nothing. Sets
# `lost` to what would be lost when it isn't.
regenerable() {
  local wt="$1" p="${2%/}" b
  lost="$p"
  b="${p##*/}"
  # Build output and dependencies, and what devenv generates, at the
  # worktree's top only. A case glob's `*` matches `/` too, so a path inside
  # a `result-*` or `openspec-*` directory is not that entry: status lists
  # such a path alone only when the directory itself isn't ignored.
  case "$p" in
    result-*/* | .claude/skills/openspec-*/*) ;;
    target | node_modules | .devenv.flake.nix | .mcp.json | \
      .pre-commit-config.yaml | .claude/settings.json)
      return 0
      ;;
    # Nix's out-links: only a link into the store, so a real directory
    # someone named result-<something> keeps the worktree.
    result | result-*)
      local t
      [ -L "$wt/$p" ] && t="$(readlink -- "$wt/$p")" && [[ "$t" == /nix/store/* ]] && return 0
      ;;
    # openspec init's output: a directory holding only SKILL.md, and one
    # holding only command files. Anything else in them keeps the worktree.
    .claude/skills/openspec-*)
      only_files "$wt/$p" 'SKILL.md' && return 0
      ;;
    .claude/commands/opsx)
      only_files "$wt/$p" '*.md' && return 0
      ;;
  esac
  # Caches, at any depth: each is matched by the entry's own name, so a path
  # inside one is never mistaken for it.
  case "$b" in
    .devenv)
      devenv_disposable "$wt/$p"
      return
      ;;
    .direnv | __pycache__ | .DS_Store) return 0 ;;
    # devenv's own files beside a devenv.nix (a test fixture's, say).
    devenv.lock | .devenv.flake.nix)
      [ -e "$wt/${p%"$b"}devenv.nix" ] && return 0
      ;;
  esac
  return 1
}

# Whether worktree $1 is clean. Sets `why` when it isn't. GIT_OPTIONAL_LOCKS
# keeps status from refreshing the index, which would also reset the idle
# clock. --ignored=matching lists an ignored directory once, not its files.
is_clean() {
  local wt="$1" out line gd f
  if ! out="$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain=v1 \
    --ignored=matching --untracked-files=all 2>/dev/null)"; then
    why="git status failed"
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      '!! '*)
        if ! regenerable "$wt" "${line#!! }"; then
          why="ignored files that would be lost ($(q "${lost#"$wt"/}"))"
          return 1
        fi
        ;;
      *)
        why="uncommitted or untracked changes"
        return 1
        ;;
    esac
  done <<<"$out"
  # A skip-worktree (S) or assume-unchanged (lowercase) entry hides its
  # changes from status.
  if ! out="$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" ls-files -v 2>/dev/null)"; then
    why="git ls-files failed"
    return 1
  fi
  if [[ $'\n'"$out" =~ $'\n'([a-z]|S)\  ]]; then
    why="a skip-worktree or assume-unchanged file, whose changes status doesn't show"
    return 1
  fi
  if ! gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"; then
    why="no git dir"
    return 1
  fi
  for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ -e "$gd/$f" ]; then
      why="$f: an operation is in progress"
      return 1
    fi
  done
}

# The newest mtime among the paths given (missing ones are skipped).
newest() {
  local p t n=0
  for p in "$@"; do
    t="$(mtime "$p")" || continue
    [ "$t" -le "$n" ] || n="$t"
  done
  echo "$n"
}
cutoff=$((now - idle_minutes * 60))

# The working directories of every process lsof can see (any user's, so a
# shell another account has in a worktree counts), read once, when the
# first candidate needs them. lsof_state: "" not read, ok, failed.
lsof_state=""
cwds=()
read_cwds() {
  local out line
  cwds=()
  if out="$(timeout 20 lsof -a -d cwd -Fn 2>/dev/null)"; then
    lsof_state=ok
    while IFS= read -r line; do
      case "$line" in n/*) cwds+=("${line#n}") ;; esac
    done <<<"$out"
  else
    lsof_state=failed
    keep lsof "lsof failed or timed out: keeping every worktree this run"
  fi
}

# Whether a process works in worktree $1. With $2 "fresh", lsof is read
# again, as just before a removal: the first read can be minutes old after a
# slow gh-app call. Sets `why` when one does, or when lsof fails.
cwd_in() {
  local d
  if [ -z "$lsof_state" ] || [ "${2:-}" = fresh ]; then
    read_cwds
  fi
  if [ "$lsof_state" != ok ]; then
    why="lsof failed"
    return 0
  fi
  for d in ${cwds[@]+"${cwds[@]}"}; do
    if contains "$1" "$d"; then
      why="a process works in it ($(q "$d"))"
      return 0
    fi
  done
  return 1
}

# Whether worktree $1 (real path) is in use. Sets `why` when it is.
in_use() {
  local wt="$1" gd
  if [ -n "$session_real" ] && contains "$wt" "$session_real"; then
    why="the session's directory is in it"
    return 0
  fi
  if [ -n "$pwd_real" ] && contains "$wt" "$pwd_real"; then
    why="the run's working directory is in it"
    return 0
  fi
  if cwd_in "$wt"; then
    return 0
  fi
  if ! gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"; then
    why="no git dir"
    return 0
  fi
  if [ "$(newest "$gd" "$gd/HEAD" "$gd/index" "$gd/logs/HEAD" "$gd/ORIG_HEAD" \
    "$wt" "$wt/.devenv" "$wt/.devenv/state" "$wt"/.devenv/profiles/* \
    "$wt"/.devenv/profiles/*/state)" -gt "$cutoff" ]; then
    why="active within the last $idle_minutes minutes"
    return 0
  fi
  return 1
}

# Deletes branch $1 if it still points at $2, with its config section.
delete_branch() {
  local err
  # The intent first: with no record the branch stays for the next run.
  if ! intend "deleting branch $(q "$1") (was $2); to restore: $(printf 'git branch %q %q' "$1" "$2")"; then
    keep "branch $1" "kept branch $(q "$1"): the log couldn't be written"
    return 0
  fi
  if err="$(git update-ref -d "refs/heads/$1" "$2" 2>&1)"; then
    git config --remove-section "branch.$1" 2>/dev/null || true
    # %q: the restore command pastes safely, whatever the name holds.
    say "deleted branch $(q "$1") (was $2); to restore: $(printf 'git branch %q %q' "$1" "$2")"
  else
    keep "branch $1" "kept branch $(q "$1"): it moved or couldn't be deleted: $(clean "$err")"
  fi
}

# The branches the worktrees (main checkout included) hold, read afresh
# from `git worktree list --porcelain` into held: branch -> the paths
# holding it, one per line. A worktree holds the branch it has checked out,
# and one it is rebasing or bisecting, which shows a detached HEAD while
# the branch is still in use (`git branch -d` holds the same). One git call
# per read; each worktree's git dir is found from its .git with builtins.
# held_ok is empty when the list couldn't be read, so nothing is deleted.
declare -A held=()
held_ok=""
read_held() {
  local list line path="" branch="" gd f b
  held=()
  held_ok=""
  list="$(git -C "$main_real" worktree list --porcelain 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "")
        if [ -n "$path" ]; then
          [ -z "$branch" ] || held["$branch"]+="$path"$'\n'
          # The worktree's own git dir: its .git directory, or the gitdir a
          # linked worktree's .git file names.
          gd="$path/.git"
          if [ -f "$gd" ]; then
            b=""
            IFS= read -r b <"$gd" 2>/dev/null || true
            case "$b" in
              "gitdir: /"*) gd="${b#gitdir: }" ;;
              "gitdir: "?*) gd="$path/${b#gitdir: }" ;;
              *) gd="" ;;
            esac
          fi
          if [ -d "$gd" ]; then
            for f in rebase-merge/head-name rebase-apply/head-name BISECT_START; do
              b=""
              [ ! -f "$gd/$f" ] || IFS= read -r b <"$gd/$f" 2>/dev/null || true
              b="${b#refs/heads/}"
              [ -z "$b" ] || held["$b"]+="$path"$'\n'
            done
          fi
        fi
        path="" branch=""
        ;;
    esac
  done <<<"$list"$'\n'
  held_ok=1
}
# Whether a worktree other than the one at path $2 (none: any) holds branch
# $1, from the last read_held. Sets `why` when one does, or when the list
# couldn't be read.
held_elsewhere() {
  local p
  if [ -z "$held_ok" ]; then
    why="the worktree list couldn't be read"
    return 0
  fi
  while IFS= read -r p; do
    if [ -n "$p" ] && [ "$p" != "${2:-}" ]; then
      why="another worktree has it checked out"
      return 0
    fi
  done <<<"${held[$1]-}"
  return 1
}

# Whether branch $1 is long-lived, and so never deleted, whatever PR names
# it (a promotion PR from `staging` has its tip as head): the default
# branch, or a protected name in any case. Sets `why` when it is.
long_lived() {
  if [ "$1" = "$default_branch" ]; then
    why="it's the default branch"
    return 0
  fi
  # Any case: on a case-insensitive filesystem (core.ignorecase) `Staging`
  # may be the same ref as `staging`.
  case "${1,,}" in
    main | master | develop | dev | staging | production | prod | release/* | hotfix/*)
      why="a long-lived branch's name"
      return 0
      ;;
  esac
  return 1
}

# Whether branch $1 is kept for its name: long-lived, or one whose config
# section `git config --remove-section` can't address (a `]` in it, as of
# git 2.56), which would delete the ref and leave its config behind. Sets
# `why` when it is.
name_kept() {
  if long_lived "$1"; then
    return 0
  fi
  case "$1" in
    *]*)
      why="its name has a ']', so its config section couldn't be removed"
      return 0
      ;;
  esac
  return 1
}

# Whether branch $1, whose worktree was removed at commit $2, goes too: not
# kept for its name (name_kept), and either the exact head of a PR merged into the default
# branch, or past origin/main with a merged PR containing it. A branch that
# only trails origin/main stays. Sets `why` when it stays.
branch_goes() {
  local rc=0
  if name_kept "$1"; then
    return 1
  fi
  merged_pr "$2" "$1" exact || rc=$?
  [ "$rc" != 0 ] || return 0
  if [ "$rc" = 1 ] && [ -n "$base" ] && ! git merge-base --is-ancestor "$2" "$base" 2>/dev/null &&
    merged_pr "$2" "$1"; then
    return 0
  fi
  if [ "$rc" = 2 ]; then
    why="the merged PRs aren't known"
  else
    why="no PR merged into $(q "$default_branch") has it as its head"
  fi
  return 1
}

# Whether branch $1 of the worktree at path $3, at commit $2, goes once that
# worktree is gone: no other worktree holds it (as of the last read_held),
# and branch_goes. Sets `why` when it stays.
branch_follows() {
  if held_elsewhere "$1" "$3"; then
    return 1
  fi
  branch_goes "$1" "$2"
}

# The head commits of the merged PRs that this repository has, as `^<oid>`
# lines for rev-list --stdin, in pr_negs; read once, when first needed.
pr_negs=""
pr_negs_read=""
merged_heads() {
  local oid name type list=""
  [ -z "$pr_negs_read" ] || return 0
  pr_negs_read=1
  [ -n "$pr_state" ] || fetch_prs
  [ "$pr_state" = ok ] || return 0
  while read -r oid name; do
    case "$oid" in '' | *[!0-9a-f]*) continue ;; esac
    list+="$oid"$'\n'
  done <<<"$prs"
  [ -n "$list" ] || return 0
  # A missing one prints `<oid> missing`, and ^<oid> would fail rev-list.
  list="$(git cat-file --batch-check='%(objectname) %(objecttype)' <<<"$list" 2>/dev/null)" || return 0
  while read -r oid type; do
    [ "$type" != commit ] || pr_negs+="^$oid"$'\n'
  done <<<"$list"
}

# Whether the HEAD reflog of the worktree git reaches with options $@ (-C
# <dir>, or --git-dir=<admin dir>) has a commit no ref or merged PR's head
# holds: the reflog may be the only record of work abandoned there, and it
# goes with the worktree.
# One that can't be read or checked counts. Sets `why` when it has.
reflog_unheld() {
  # Not `log`: that names the log file say writes to, and merged_heads can
  # log (a gh-app failure) while this is in scope.
  local hashes out gd
  # git reads a reflog it can't open as empty.
  if ! gd="$(git "$@" rev-parse --absolute-git-dir 2>/dev/null)" ||
    { [ -e "$gd/logs/HEAD" ] && [ ! -r "$gd/logs/HEAD" ]; } ||
    ! hashes="$(git "$@" reflog --format=%H HEAD 2>/dev/null)"; then
    why="its HEAD reflog couldn't be read"
    return 0
  fi
  [ -n "$hashes" ] || return 1
  # --stdin before --not: the reflog's commits are the positive side.
  if ! out="$(git "$@" rev-list --stdin --not --all <<<"$hashes" 2>/dev/null)"; then
    why="its HEAD reflog couldn't be checked"
    return 0
  fi
  # A merged PR holds its head's commits too: a branch reset behind its
  # squash-merged head left them in the reflog only.
  if [ -n "$out" ]; then
    merged_heads
    if [ -n "$pr_negs" ] &&
      ! out="$(git "$@" rev-list --stdin --not --all <<<"$out"$'\n'"$pr_negs" 2>/dev/null)"; then
      why="its HEAD reflog couldn't be checked"
      return 0
    fi
  fi
  if [ -n "$out" ]; then
    why="its HEAD reflog has commits no branch holds"
    return 0
  fi
  return 1
}

# Whether `git worktree prune` would lose something of the worktree once
# registered at $1, whose directory is gone (or was moved by hand): its admin
# dir in $common/worktrees holds its index, HEAD and HEAD reflog, so a
# staged change, or a HEAD or reflog commit no ref holds, would go with it.
# One whose admin dir can't be found or checked counts. Sets `why` when so.
admin_loses() {
  local d g admin="" h
  for d in "$common"/worktrees/*/; do
    g="$(cat -- "${d}gitdir" 2>/dev/null)" || continue
    if [ "$g" = "$1/.git" ]; then
      admin="${d%/}"
      break
    fi
  done
  if [ -z "$admin" ]; then
    why="its admin dir in $(q "$common/worktrees") couldn't be found"
    return 0
  fi
  if ! h="$(git --git-dir="$admin" rev-parse -q --verify HEAD 2>/dev/null)"; then
    why="its HEAD in $(q "$admin") couldn't be read"
    return 0
  fi
  if ! git --git-dir="$admin" diff-index --cached --quiet "$h" -- 2>/dev/null; then
    why="its index in $(q "$admin") has staged changes (or couldn't be read)"
    return 0
  fi
  # Not --all: that counts every worktree's HEAD, this one's too.
  if [ -n "$(git --git-dir="$admin" rev-list -n 1 "$h" --not --branches --tags --remotes 2>/dev/null || echo x)" ]; then
    why="its HEAD in $(q "$admin") is a commit no branch holds"
    return 0
  fi
  reflog_unheld --git-dir="$admin"
}

gone=()
present=""
# A dry run removes nothing, so one read serves all of it.
[ -z "$dry_run" ] || read_held || true
for ((i = 1; i < ${#wt_paths[@]}; i++)); do
  path="${wt_paths[i]}"
  head="${wt_heads[i]}"
  branch="${wt_branches[i]}"
  flags="${wt_flags[i]}"
  label="${branch:-detached}"
  # The log's name for it.
  desc="$(q "$path") ($(q "$label"))"
  key="worktree $path"
  why=""
  # Before prunable: git worktree prune leaves a locked one alone.
  case "$flags" in
    *locked*)
      keep "$key" "kept worktree $desc: locked"
      continue
      ;;
    *prunable*)
      # Gone only if nothing is at its path: git also calls one prunable
      # whose .git file alone is missing.
      if [ -e "$path" ] || [ -L "$path" ]; then
        present="$path"
      else
        gone+=("$path")
      fi
      continue
      ;;
  esac
  if ! real="$(realpath -e -- "$path" 2>/dev/null)"; then
    keep "$key" "kept worktree $desc: its directory can't be resolved"
    continue
  fi
  if ! under_roots "$real" || [ "$real" = "$main_real" ]; then
    keep "$key" "kept worktree $desc: outside $roots_desc"
    continue
  fi
  if [ -z "$head" ]; then
    keep "$key" "kept worktree $desc: no HEAD"
    continue
  fi
  # The in-main check first: it is cheap (the one gh-app call is made at
  # most once), and an unmerged worktree then skips the status scans.
  if ! in_main "$head" "$branch"; then
    keep "$key" "kept worktree $desc: $why"
    continue
  fi
  # On a branch too: a commit made detached and left by switching back is
  # in no branch's reflog.
  if reflog_unheld -C "$real"; then
    keep "$key" "kept worktree $desc: $why"
    continue
  fi
  if ! is_clean "$real"; then
    keep "$key" "kept worktree $desc: $why"
    continue
  fi
  if in_use "$real"; then
    keep "$key" "kept worktree $desc: $why"
    continue
  fi
  if [ -n "$dry_run" ]; then
    echo "worktree $path ($label)"
    if [ -n "$branch" ] && branch_follows "$branch" "$head" "$path"; then
      echo "branch $branch"
    fi
    continue
  fi
  # Just before the removal: no process has moved in, HEAD and the branch
  # are still what was checked, and the tree is still clean.
  if cwd_in "$real" fresh; then
    keep "$key" "kept worktree $desc: $why"
    continue
  fi
  now_head="$(git -C "$real" rev-parse -q --verify HEAD 2>/dev/null || true)"
  now_tip="$head"
  [ -z "$branch" ] || now_tip="$(git rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
  if [ "$now_head" != "$head" ] || [ "$now_tip" != "$head" ]; then
    keep "$key" "kept worktree $desc: HEAD or its branch moved since the check"
    continue
  fi
  if ! is_clean "$real"; then
    keep "$key" "kept worktree $desc: $why, found just before the removal"
    continue
  fi
  if reflog_unheld -C "$real"; then
    keep "$key" "kept worktree $desc: $why, found just before the removal"
    continue
  fi
  # The intent first: with no record the worktree stays for the next run.
  if ! intend "removing worktree $desc at $now_head; to restore: $(printf 'git worktree add %q %q' "$path" "$now_head")"; then
    keep "$key" "kept worktree $desc: the log couldn't be written"
    continue
  fi
  if err="$(git worktree remove "$path" 2>&1)"; then
    say "removed worktree $desc at $now_head; to restore: $(printf 'git worktree add %q %q' "$path" "$now_head")"
    if [ -n "$branch" ]; then
      # Who holds the branch now, not at the start of the run.
      read_held || true
      if branch_follows "$branch" "$now_head" "$path"; then
        delete_branch "$branch" "$now_head"
      else
        keep "branch $branch" "kept branch $(q "$branch"): $why"
      fi
    fi
  else
    keep "$key" "kept worktree $desc: git worktree remove failed: $(clean "$err")"
  fi
done

# The device number of path $1 (GNU stat, as mtime's).
device() { stat -c %d -- "$1" 2>/dev/null; }

# Worktrees whose directory is gone. `git worktree prune` unregisters every
# one, so it runs only when all of them lie under the roots, and each one's
# root and parent directory still exist, the root on the main checkout's
# device: otherwise the volume behind a linked root may just be unmounted.
# Nor when one that git calls prunable is still there, or prune would lose
# something in one's admin dir (a worktree moved by hand looks gone).
if [ ${#gone[@]} -gt 0 ] || [ -n "$present" ]; then
  outside=""
  missing=""
  elsewhere=""
  loses=""
  main_dev="$(device "$main_real" || true)"
  for p in ${gone[@]+"${gone[@]}"}; do
    rp="$(realpath -m -- "$p")"
    if [ -z "$loses" ] && admin_loses "$p"; then
      loses="$p"
      loses_why="$why"
    fi
    if ! under_roots "$rp"; then
      outside="$p"
      continue
    fi
    for r in ${roots[@]+"${roots[@]}"}; do
      contains "$r" "$rp" || continue
      if [ ! -d "$r" ] || [ ! -d "${rp%/*}" ] || [ ! -d "${p%/*}" ]; then
        missing="$p"
      elif ! r_dev="$(device "$r")" || [ -z "$main_dev" ] || [ "$r_dev" != "$main_dev" ]; then
        elsewhere="$p"
      fi
    done
  done
  if [ -n "$present" ]; then
    keep prune "skipped git worktree prune: git calls $(q "$present") prunable, but it's still there (its .git file is missing)"
  elif [ -n "$loses" ]; then
    keep prune "skipped git worktree prune: $(q "$loses") is gone, but $loses_why (moved by hand? git worktree repair <new path> re-registers it)"
  elif [ -n "$outside" ]; then
    keep prune "skipped git worktree prune: $(q "$outside"), outside $roots_desc, is gone too"
  elif [ -n "$missing" ]; then
    keep prune "skipped git worktree prune: the directory holding $(q "$missing") is gone too (an unmounted volume?)"
  elif [ -n "$elsewhere" ]; then
    keep prune "skipped git worktree prune: $(q "$elsewhere") is gone, and its root isn't on the main checkout's device (another volume?)"
  elif [ -n "$dry_run" ]; then
    for p in ${gone[@]+"${gone[@]}"}; do
      echo "unregister $p"
    done
  else
    # The intents first, as for a removal: with no record, no prune.
    intended=1
    for p in ${gone[@]+"${gone[@]}"}; do
      intend "unregistering worktree $(q "$p"): its directory was gone" || {
        intended=""
        break
      }
    done
    if [ -z "$intended" ]; then
      keep prune "skipped git worktree prune: the log couldn't be written"
    elif git worktree prune 2>/dev/null; then
      for p in ${gone[@]+"${gone[@]}"}; do
        say "unregistered worktree $(q "$p"): its directory was gone"
      done
    else
      keep prune "git worktree prune failed"
    fi
  fi
fi

# Branches no worktree holds (read after the removals, and again just
# before each deletion).
if read_held; then
  refs="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads 2>/dev/null || true)"
  while read -r ref sha; do
    [ -n "$ref" ] || continue
    name="${ref#refs/heads/}"
    # One a worktree has checked out is that worktree's business: no line.
    # Every other kept branch, the default one included, is logged.
    [ -z "${held[$name]-}" ] || continue
    qname="$(q "$name")"
    if name_kept "$name"; then
      keep "branch $name" "kept branch $qname: $why"
      continue
    fi
    if [ -e "$common/logs/$ref" ]; then
      t="$(newest "$common/logs/$ref")"
    elif [ -e "$common/$ref" ]; then
      t="$(newest "$common/$ref")"
    else
      t="$(newest "$common/packed-refs")"
    fi
    if [ "$t" -gt "$cutoff" ]; then
      keep "branch $name" "kept branch $qname: moved within the last $idle_minutes minutes"
      continue
    fi
    rc=0
    merged_pr "$sha" "$name" exact || rc=$?
    case "$rc" in
      0) ;;
      2)
        keep "branch $name" "kept branch $qname: the merged PRs aren't known"
        continue
        ;;
      *)
        keep "branch $name" "kept branch $qname: no PR merged into $(q "$default_branch") has it as its head"
        continue
        ;;
    esac
    if [ -n "$dry_run" ]; then
      echo "branch $name"
      continue
    fi
    # A worktree made on it since the first read holds it now.
    read_held || true
    if held_elsewhere "$name"; then
      keep "branch $name" "kept branch $qname: $why"
      continue
    fi
    delete_branch "$name" "$sha"
  done <<<"$refs"
fi

# Whether log line $1 records a removal, which trimming keeps.
is_removal() {
  case "${1#* }" in
    "removed worktree "* | "deleted branch "* | "unregistered worktree "*) return 0 ;;
  esac
  return 1
}
# Whether log line $1 records an intent to remove, written before it.
is_intent() {
  case "${1#* }" in
    "removing worktree "* | "deleting branch "* | "unregistering worktree "*) return 0 ;;
  esac
  return 1
}

# Keeps every removal and the last 1000 other lines. An intent line is kept
# like a removal, the record when its "removed ..." line couldn't be
# written, unless a later line says the same: its removal's line, or the
# same intent again (a removal that keeps failing writes one every run).
# Those are dropped once there are over 100 of them, or with a trim.
trim_log() {
  local -a lines mark
  local -A seen=()
  local l s n=0 i o=0 dropped=0
  # Only the log this run wrote to, and not through a link since: the
  # rewrite would copy the link's target where the sandbox can read it.
  { [ -n "$log_ok" ] && own_file "$log"; } || return 0
  mapfile -t lines <"$log" 2>/dev/null || return 0
  # Newest first, so a line's later copies are seen before it.
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    l="${lines[i]}"
    s="${l#* }"
    if is_intent "$l"; then
      case "$s" in
        "removing "*) s="removed ${s#removing }" ;;
        "deleting "*) s="deleted ${s#deleting }" ;;
        "unregistering "*) s="unregistered ${s#unregistering }" ;;
      esac
      if [ -n "${seen[$s]-}" ]; then
        mark[i]=drop
        dropped=$((dropped + 1))
      else
        seen["$s"]=1
        mark[i]=keep
      fi
    elif is_removal "$l"; then
      seen["$s"]=1
      mark[i]=keep
    else
      mark[i]=other
      n=$((n + 1))
    fi
  done
  [ "$n" -gt 1000 ] || [ "$dropped" -gt 100 ] || return 0
  for ((i = 0; i < ${#lines[@]}; i++)); do
    case "${mark[i]}" in
      keep) printf '%s\n' "${lines[i]}" ;;
      other)
        o=$((o + 1))
        [ "$o" -le $((n - 1000)) ] || printf '%s\n' "${lines[i]}"
        ;;
    esac
  done | replace_file "$log" || true
}

if [ -z "$dry_run" ]; then
  touch_stamp
  save_kept
  trim_log
fi
exit 0
