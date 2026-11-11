#!/usr/bin/env bash
# The gate: every check a change to this repository passes before a commit and
# before a merge. Run it as
#
#   devenv shell --quiet -- scripts/check.sh
#
# or, with nix and devenv on PATH, directly (CI does). It runs every check even
# after one fails, prints a summary, and exits 1 if any check failed.
#
# Its tools (python3, nixfmt, shellcheck, openspec) come from the nixpkgs
# revision devenv.lock pins (scripts/check-tools.nix), not from PATH.
#
# No `set -e`: a failing check must not stop the ones after it.
set -uo pipefail

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

names=()
results=()

# step NAME COMMAND...: runs the command with its output on the terminal and
# records whether it passed.
step() {
  local name=$1
  shift
  echo
  echo "=== $name"
  if "$@"; then
    names+=("$name")
    results+=(pass)
  else
    echo "--- $name failed"
    names+=("$name")
    results+=(FAIL)
  fi
}

# skip NAME REASON: records a check that couldn't run as failed.
skip() {
  echo
  echo "=== $1"
  echo "--- $1 failed: $2"
  names+=("$1")
  results+=(FAIL)
}

# ------------------------------------------------------------------- tools --
tools_ok=1
echo "=== tools (scripts/check-tools.nix)"
if tools=$(nix build --impure --no-link --print-out-paths -f scripts/check-tools.nix) && [[ -d $tools/bin ]]; then
  export PATH=$tools/bin:$PATH
else
  tools_ok=0
  echo "--- the tools failed to build" >&2
fi

# with_tools NAME COMMAND...: a step that needs the tools.
with_tools() {
  if ((tools_ok)); then
    step "$@"
  else
    skip "$1" "tools unavailable"
  fi
}

# Runs a command on the tracked and untracked, non-ignored files matching a
# pathspec, skipping paths deleted from the working tree. Passes with a note
# when none match. (bash 3.2 has no mapfile, and expanding an empty array
# fails under set -u, so this reads into the array and guards its length.)
# files_check PATTERN COMMAND...
files_check() {
  local pattern=$1 file
  shift
  local files=()
  while IFS= read -r file; do
    [[ -e $file ]] && files+=("$file")
  done < <(git ls-files --cached --others --exclude-standard -- "$pattern")
  if ((${#files[@]} == 0)); then
    echo "no $pattern files"
    return 0
  fi
  "$@" "${files[@]}"
}

nix_files_formatted() {
  files_check '*.nix' nixfmt --check
}

shell_scripts_lint() {
  files_check '*.sh' shellcheck --shell=bash
}

# Builds a fixture's shell on one profile, with the module's lock, as the
# cache job does. The copy of devenv.lock is gitignored.
fixture_builds() {
  local fixture=$1 profile=$2
  cp devenv.lock "$fixture" && (cd "$fixture" && devenv --profile "$profile" build shell)
}

# ------------------------------------------------------------------ checks --
with_tools "guard tests" python3 -I packages/claude-guard-test.py
with_tools "nixfmt" nix_files_formatted
with_tools "shellcheck" shell_scripts_lint
with_tools "openspec validate" openspec validate --all --strict

# Builds this repository's shell, which builds every module package and so
# runs claude-guard's and session-relink's build-time tests.
step "build: shell" devenv build shell

for fixture in tests/fixtures/*/; do
  fixture=${fixture%/}
  for profile in ci developer; do
    step "build: ${fixture##*/} ($profile)" fixture_builds "$fixture" "$profile"
  done
done

# ----------------------------------------------------------------- summary --
echo
echo "=== summary"
failed=0
for i in "${!names[@]}"; do
  printf '%-4s  %s\n' "${results[$i]}" "${names[$i]}"
  [[ ${results[$i]} == pass ]] || failed=1
done
if ((failed)); then
  echo "check: FAILED"
  exit 1
fi
echo "check: all passed"
