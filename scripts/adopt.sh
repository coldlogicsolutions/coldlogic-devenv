#!/usr/bin/env bash
# Moves a project onto coldlogic-devenv, or sets up a new one with it.
#
# Run it from the project's root, from a checkout of this repository:
#
#   ../coldlogic-devenv/scripts/adopt.sh [options]
#
# or straight from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/coldlogicsolutions/coldlogic-devenv/main/scripts/adopt.sh | bash -s -- [options]
#
# It changes only files in the working tree, never commits, and can run again
# safely: each step skips what is already in place. What it can't do for you
# (porting a flake's dev shell, moving settings out of a tracked
# .claude/settings.json) it lists at the end.
#
# Options:
#   --profile NAME   rust-lib, rust-worker or none. Default: rust-worker for a
#                    Cargo project with a wrangler config, rust-lib for any
#                    other Cargo project, none otherwise.
#   --no-workflow    Don't add .github/workflows/update-coldlogic-devenv.yaml.
#   --no-envrc       Don't add an .envrc that loads the shell through direnv.
#   --no-update      Don't lock the new inputs (run `devenv update` yourself).
#   --allow-dirty    Run even with uncommitted changes.
#   -h, --help       Show this help.
set -euo pipefail

repo=coldlogicsolutions/coldlogic-devenv
raw="https://raw.githubusercontent.com/$repo/main"

# yq here is mikefarah's yq-go, which keeps comments when it edits YAML.
if ! command -v yq >/dev/null || ! yq --version 2>&1 | grep -q mikefarah; then
  if [[ -z ${COLDLOGIC_ADOPT_REEXEC:-} ]] && command -v nix >/dev/null; then
    export COLDLOGIC_ADOPT_REEXEC=1
    self=${BASH_SOURCE[0]:-}
    if [[ ! -f $self ]]; then # piped from curl: fetch a copy to run
      self=$(mktemp "${TMPDIR:-/tmp}/adopt.XXXXXX")
      curl -fsSL "$raw/scripts/adopt.sh" -o "$self"
      # exec leaves no trap here, so the re-executed copy removes itself.
      export COLDLOGIC_ADOPT_TMP=$self
    fi
    exec nix shell nixpkgs#yq-go --command bash "$self" "$@"
  fi
  echo "adopt: needs yq-go (mikefarah/yq): nix profile install nixpkgs#yq-go" >&2
  exit 1
fi
if [[ -n ${COLDLOGIC_ADOPT_TMP:-} && ${BASH_SOURCE[0]:-} == "$COLDLOGIC_ADOPT_TMP" ]]; then
  trap 'rm -f -- "$COLDLOGIC_ADOPT_TMP"' EXIT
fi

profile=auto
workflow=1
envrc=1
update=1
allow_dirty=0
while (($#)); do
  case $1 in
    --profile) profile=${2:?--profile needs a name}; shift 2 ;;
    --profile=*) profile=${1#*=}; shift ;;
    --no-workflow) workflow=0; shift ;;
    --no-envrc) envrc=0; shift ;;
    --no-update) update=0; shift ;;
    --allow-dirty) allow_dirty=1; shift ;;
    -h | --help)
      if [[ -f ${BASH_SOURCE[0]:-} ]]; then
        sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}" 2>/dev/null || echo "see $raw/scripts/adopt.sh"
      else
        echo "see $raw/scripts/adopt.sh"
      fi
      exit 0
      ;;
    *) echo "adopt: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "adopt: run it inside the project's git repository" >&2; exit 1; }
cd "$root"
if ((!allow_dirty)) && [[ -n $(git status --porcelain) ]]; then
  echo "adopt: the working tree has uncommitted changes; commit or stash them, or pass --allow-dirty" >&2
  exit 1
fi

if [[ $profile == auto ]]; then
  profile=none
  if [[ -f Cargo.toml ]]; then
    profile=rust-lib
    if find . -maxdepth 3 \( -name node_modules -o -name target -o -name .git \) -prune \
      -o \( -name 'wrangler.toml' -o -name 'wrangler.json' -o -name 'wrangler.jsonc' \) -print | grep -q .; then
      profile=rust-worker
    fi
  fi
  echo "profile: $profile (pass --profile to change it)"
fi
case $profile in
  rust-lib | rust-worker | none) ;;
  *) echo "adopt: unknown profile $profile (rust-lib, rust-worker or none)" >&2; exit 2 ;;
esac

# Where the template comes from: this checkout when run from one, else main.
here=
if [[ -f ${BASH_SOURCE[0]:-} ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  [[ -f $here/templates/update-coldlogic-devenv.yaml ]] || here=
fi

notes=()
note() { notes+=("$1"); }
changed=()

# ------------------------------------------------------------- devenv.yaml --
added_inputs=()
new_yaml=0
if [[ ! -f devenv.yaml ]]; then
  # shellcheck disable=SC2016 # $schema is literal text for the YAML language server
  printf '# yaml-language-server: $schema=https://devenv.sh/devenv.schema.json\ninputs: {}\n' >devenv.yaml
  new_yaml=1
fi
had_yaml=$(cat devenv.yaml)

ensure_input() { # name, yq value
  if [[ $(yq ".inputs[\"$1\"] | type" devenv.yaml) == '!!null' ]]; then
    yq -i ".inputs[\"$1\"] = $2" devenv.yaml
    added_inputs+=("$1")
  fi
}
ensure_input nixpkgs '{"url": "github:NixOS/nixpkgs/nixpkgs-unstable"}'
# coldlogic-devenv uses these, and devenv doesn't take inputs from an
# imported module, so the project declares them.
ensure_input git-hooks '{"url": "github:cachix/git-hooks.nix"}'
ensure_input rust-overlay '{"url": "github:oxalica/rust-overlay", "inputs": {"nixpkgs": {"follows": "nixpkgs"}}}'
ensure_input coldlogic-devenv "{\"url\": \"github:$repo\", \"flake\": false}"
if [[ " ${added_inputs[*]} " == *" coldlogic-devenv "* ]]; then
  yq -i '(.inputs["coldlogic-devenv"] | key) head_comment = "The shared Cold Logic setup: git hooks, Claude Code settings, guard hook\nand plugin, gh-app, openspec."' devenv.yaml
fi
url=$(yq '.inputs["coldlogic-devenv"].url' devenv.yaml)
[[ $url == "github:$repo" ]] || note "devenv.yaml points coldlogic-devenv at $url, not github:$repo. Never commit a path: input."
[[ $(yq '.inputs.openspec | type' devenv.yaml) == '!!null' ]] || note "devenv.yaml has its own openspec input; the module provides openspec, so it can probably go."

want='["coldlogic-devenv"]'
[[ $profile == none ]] || want="[\"coldlogic-devenv\", \"coldlogic-devenv/profiles/$profile\"]"
yq -i "(.imports // []) as \$have | .imports = \$have + ($want - \$have)" devenv.yaml
for p in rust-lib rust-worker; do
  if [[ $p != "$profile" ]] && [[ $(yq ".imports[] | select(. == \"coldlogic-devenv/profiles/$p\")" devenv.yaml) ]]; then
    note "devenv.yaml also imports coldlogic-devenv/profiles/$p; keep only one profile."
  fi
done

current=$(yq '.profile // ""' devenv.yaml)
if [[ -z $current ]]; then
  yq -i '.profile = "developer"' devenv.yaml
elif [[ $current != developer ]]; then
  note "devenv.yaml sets profile: $current; the module's tools and Claude Code setup are in the developer profile."
fi
if ((new_yaml)); then
  changed+=("devenv.yaml (new)")
elif [[ $(cat devenv.yaml) != "$had_yaml" ]]; then
  changed+=(devenv.yaml)
fi

# -------------------------------------------------------------- devenv.nix --
if [[ ! -f devenv.nix ]]; then
  cat >devenv.nix <<'EOF'
# Git hooks and the Claude Code setup come from coldlogic-devenv
# (devenv.yaml). This adds only what this project needs.
{ pkgs, ... }:

{ }
EOF
  changed+=("devenv.nix (new)")
else
  # The module sets these; a project's own copy may duplicate or fight it.
  overlap=$(grep -nE 'claude\.code|git-hooks|pre-commit|openspec|\bgit\b *$|languages\.rust' devenv.nix || true)
  # shellcheck disable=SC2001 # prefixes every line of a multi-line value; ${//} would miss the first
  [[ -z $overlap ]] || note "devenv.nix sets things the module or a profile may already provide; check each and drop what's duplicated (README, 'Using it'):
$(sed 's/^/      /' <<<"$overlap")"
fi

# --------------------------------------------------------------- .gitignore --
# The files devenv generates: settings.json and .mcp.json are Nix store
# symlinks written by `claude.code`, .pre-commit-config.yaml by git-hooks,
# and OpenSpec's Claude Code skills and commands by the shell (devenv.nix,
# coldlogic:openspec-files).
ignore=('.devenv*' devenv.local.nix devenv.local.yaml /.claude/settings.json /.claude/worktrees/ .mcp.json .pre-commit-config.yaml '/.claude/skills/openspec-*/' /.claude/commands/opsx/)
missing=()
touch .gitignore
for line in "${ignore[@]}"; do grep -qxF -- "$line" .gitignore || missing+=("$line"); done
if ((${#missing[@]})); then
  sep=
  [[ -s .gitignore ]] && sep=$'\n'
  [[ -s .gitignore && -n $(tail -c1 .gitignore) ]] && sep=$'\n\n'
  {
    printf '%s' "$sep"
    echo "# devenv. settings.json and .mcp.json are Nix store symlinks generated by"
    echo "# \`claude.code\` in coldlogic-devenv: change Claude Code settings there or in"
    echo "# devenv.nix, not here. The shell generates OpenSpec's Claude Code skills"
    echo "# and commands."
    printf '%s\n' "${missing[@]}"
  } >>.gitignore
  changed+=(.gitignore)
fi

# Files devenv now generates must not be tracked. The old copies go to
# .devenv/adopt-backup/ so their settings can be ported.
for f in .claude/settings.json .mcp.json .pre-commit-config.yaml; do
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    # Backed up first: if that fails the file stays tracked, so a rerun
    # tries again rather than skipping it.
    if [[ -e $f && ! -L $f ]]; then
      if ! { mkdir -p ".devenv/adopt-backup/$(dirname "$f")" && mv -- "$f" ".devenv/adopt-backup/$f"; }; then
        note "$f is tracked but couldn't be moved to .devenv/adopt-backup/; move it and \`git rm --cached $f\`, then port its settings into devenv.nix."
        continue
      fi
    fi
    if ! git rm --cached -q -- "$f"; then
      note "$f couldn't be untracked; run \`git rm --cached $f\`."
    fi
    changed+=("$f (untracked)")
    case $f in
      .pre-commit-config.yaml) note "$f was tracked; git-hooks now generates it. Port any hooks it had to git-hooks.hooks in devenv.nix (old copy: .devenv/adopt-backup/$f)." ;;
      *) note "$f was tracked; devenv now generates it. Port anything project-specific into devenv.nix (README, 'Using it'), e.g. extra allow rules or plugins (old copy: .devenv/adopt-backup/$f)." ;;
    esac
  fi
done

# OpenSpec's Claude Code skills and commands: the shell generates them now,
# from the module's openspec. Nothing to port, and the working copies stay
# until it rewrites them. Only where it will: a project with openspec/.
if [[ -f openspec/config.yaml && -n $(git ls-files -- '.claude/skills/openspec-*' .claude/commands/opsx) ]]; then
  if git rm -r --cached -q --ignore-unmatch -- '.claude/skills/openspec-*' .claude/commands/opsx; then
    changed+=(".claude/skills/openspec-*, .claude/commands/opsx (untracked)")
  else
    note "OpenSpec's Claude Code skills and commands couldn't be untracked; run \`git rm -r --cached '.claude/skills/openspec-*' .claude/commands/opsx\`."
  fi
fi

# ----------------------------------------------------------------- workflow --
wf=.github/workflows/update-coldlogic-devenv.yaml
if ((workflow)) && [[ ! -f $wf ]]; then
  mkdir -p .github/workflows
  if [[ -n $here ]]; then
    cp "$here/templates/update-coldlogic-devenv.yaml" "$wf"
  else
    # Downloaded beside it and moved in whole, so a failed download leaves
    # nothing for a rerun to skip.
    tmp=$(mktemp "$wf.XXXXXX")
    if ! curl -fsSL "$raw/templates/update-coldlogic-devenv.yaml" -o "$tmp"; then
      rm -f -- "$tmp"
      echo "adopt: couldn't download the update workflow" >&2
      exit 1
    fi
    mv -- "$tmp" "$wf"
  fi
  changed+=("$wf (new)")
fi

# -------------------------------------------------------------------- .envrc --
# An existing one is the project's own and is only checked, never rewritten.
if ((envrc)) && [[ ! -e .envrc ]]; then
  cat >.envrc <<'EOF'
# Loads the devenv shell (devenv.nix, devenv.yaml) through direnv.
eval "$(devenv direnvrc)"
use devenv
EOF
  changed+=(".envrc (new)")
  note "Run \`direnv allow\` once to let direnv load the new .envrc."
elif [[ -f .envrc ]] && grep -qE '^\s*use[ _]flake' .envrc; then
  note ".envrc uses the flake; replace it with \`use devenv\` (or remove .envrc if nobody uses direnv here)."
elif [[ -f .envrc ]] && ! grep -qE '^\s*use devenv' .envrc; then
  note ".envrc doesn't load devenv; add \`eval \"\$(devenv direnvrc)\"\` and \`use devenv\` if direnv should load the shell."
fi

# ------------------------------------------------------------ what's left --
if [[ -f flake.nix ]]; then
  note "flake.nix is still here. The guard hook denies a flake's dev shell, so move its devShell packages and env into devenv.nix, then remove the dev shell (and flake.nix and flake.lock if that's all it was for)."
fi
if [[ ! -f scripts/check.sh ]]; then
  note "There is no scripts/check.sh. The conventions expect it as the gate every commit passes: it must run the project's tests, formatters and linters, and exit non-zero on any failure. coldlogic-devenv's is an example: https://github.com/coldlogicsolutions/coldlogic-devenv/blob/main/scripts/check.sh"
fi
default_branch=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [[ -n $default_branch && $default_branch != origin/main ]]; then
  note "The default branch is ${default_branch#origin/}, not main; the update workflow and the coldlogic-ai environment need main."
fi

# --------------------------------------------------------------- the lock --
# Whether devenv.yaml declares an input devenv.lock doesn't have, as when an
# earlier run added inputs but couldn't lock them.
unlocked_inputs() {
  local locked
  locked=$(yq -p json -o y '.nodes.root.inputs // {} | keys | .[]' devenv.lock 2>/dev/null) || return 0
  while IFS= read -r input; do
    [[ -n $input ]] && ! grep -qxF -- "$input" <<<"$locked" && return 0
  done < <(yq '.inputs // {} | keys | .[]' devenv.yaml)
  return 1
}
if ((update)); then
  if ! command -v devenv >/dev/null; then
    note "devenv isn't installed, so the new inputs aren't locked; run \`devenv update\` once it is."
  elif [[ ! -f devenv.lock ]] || ((${#added_inputs[@]})) || unlocked_inputs; then
    [[ -f devenv.lock ]] && changed+=(devenv.lock) || changed+=("devenv.lock (new)")
    # `devenv update <input>` moves every pin anyway (devenv 2.4), so this
    # updates them all at once; the PR's CI is the check.
    echo "locking inputs (devenv update)..."
    devenv update
    note "devenv update moved every pin in devenv.lock, nixpkgs included; check the build."
  fi
fi

# ------------------------------------------------------------------ report --
echo
if ((${#changed[@]})); then
  echo "Changed:"
  printf '  - %s\n' "${changed[@]}"
else
  echo "Nothing to change: the project already uses coldlogic-devenv."
fi
if ((${#notes[@]})); then
  echo
  echo "Needs you:"
  for n in "${notes[@]}"; do printf '  - %s\n' "$n"; done
fi
name=$(basename "$(git remote get-url origin 2>/dev/null || echo "$root")" .git)
cat <<EOF

Next:
  1. Run \`devenv shell\` (or \`direnv reload\`) to generate the Claude Code
     settings and git hooks, and check that the project builds and its hooks pass.
  2. Register $name in the infrastructure stack (projects.ts) if it isn't
     already, so it gets the coldlogic-ai environment the update workflow uses.
  3. Commit the changes and open a PR.
EOF
