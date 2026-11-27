# Design

## Context

See proposal.md for the motivation (issue #133).

Checked in the code and with the tools:

- The template is the heredoc at `scripts/adopt.sh:162-168`: two comment lines, `{ pkgs, ... }:`, a blank line, `{ }`. It is the only Nix file the script writes; the other files it creates are `devenv.yaml`, `.gitignore`, the workflow copy and `.envrc`.
- With the shell's nixfmt (1.5.0), `nixfmt --check` reports the current template text "not formatted", and passes the same text with the blank line removed. Both were run on scratch copies of the text, not through `adopt.sh`.
- `tests/fixtures/rust-lib/devenv.nix` and `tests/fixtures/rust-worker/devenv.nix` have a comment, `{ ... }:` and `{ }` on consecutive lines, and pass the gate's nixfmt check today.
- The module enables the hook with `git-hooks.hooks.nixfmt.enable = true` (`devenv.nix:615`). The gate's nixfmt comes from `scripts/check-tools.nix`, which imports `scripts/pinned-nixpkgs.nix` (the root `nixpkgs` node of `devenv.lock`).
- `adopt.sh` takes its workflow template from `<script dir>/../templates/update-coldlogic-devenv.yaml` when that file exists, and otherwise downloads it with curl (`adopt.sh:99-104`, `240-252`). When `yq` on `PATH` isn't mikefarah's, it re-executes itself through `nix shell` (`adopt.sh:32-43`), and without `nix` it exits 1.
- With `--no-update` the script never calls `devenv` (`adopt.sh:295`).
- `scripts/check.sh` has `step NAME COMMAND...` for checks that need no gate tools and `with_tools` for those that do. It runs under bash 3.2 on macOS and is itself covered by the shellcheck check.
- `packages/session-shell.nix:12-25` is the existing pattern for a `runCommand` test with explicit `nativeBuildInputs`.

Assumed, not run (task 2.2 settles each):

- `adopt.sh --no-update` runs to the end in a repository with no commits and no remote, inside a Nix build.
- nixpkgs' `yq-go` prints a version line containing `mikefarah`, so the script doesn't try to re-execute.
- The shell's nixfmt and `check-tools.nix`'s nixfmt are the same version (both come from the lock's root `nixpkgs`).

## Goals / Non-Goals

**Goals:**

- A project adopted from this revision can make its first commit without touching `devenv.nix`.
- The gate fails if the script ever again creates a Nix file the module's nixfmt would rewrite.

**Non-Goals:**

- Testing anything else the adoption script does.
- Reformatting `devenv.nix` in projects already adopted.
- Guaranteeing cleanliness against whatever nixfmt an adopted project's own `nixpkgs` pin has (see Risks).

## Decisions

### 1. Remove the blank line; keep `{ }`

The template becomes:

```nix
# Git hooks and the Claude Code setup come from coldlogic-devenv
# (devenv.yaml). This adds only what this project needs.
{ pkgs, ... }:
{ }
```

It matches the fixtures, keeps the comments and the `pkgs` argument a developer will want when they add packages, and nixfmt accepts it.

Alternatives rejected:

- Write the braces as nixfmt rewrites them (`{` and `}` on separate lines, blank line kept). Also clean, but it is the less usual shape and differs from the fixtures for no gain.
- Run `nixfmt` on the file inside `adopt.sh`. The script runs on machines with only `git` and `yq`, often piped from curl; a new runtime tool is a new way for adoption to fail, to fix five fixed lines.
- Stop creating `devenv.nix`. devenv needs the file, and the spec requires the script to create it.

### 2. The test is a Nix build over the script's real output

`scripts/adopt-test.nix` is a `runCommand` on `import ./pinned-nixpkgs.nix` that makes a fresh repository, runs the real script, and checks what it left. Shape (the coder may adjust wording, not behavior):

```nix
let
  pkgs = import ./pinned-nixpkgs.nix;
in
pkgs.runCommand "coldlogic-adopt-test"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      git
      yq-go
      nixfmt
    ];
  }
  ''
    export HOME=$TMPDIR/home
    mkdir -p "$HOME" src/scripts src/templates project
    cp ${./adopt.sh} src/scripts/adopt.sh
    cp ${../templates/update-coldlogic-devenv.yaml} src/templates/update-coldlogic-devenv.yaml
    cd project
    git init -q
    bash ../src/scripts/adopt.sh --no-update
    test -f devenv.nix
    find . -name .git -prune -o -name '*.nix' -exec nixfmt --check {} +
    touch $out
  ''
```

Points that matter:

- `scripts/adopt.sh` and `templates/update-coldlogic-devenv.yaml` are laid out as `src/scripts` and `src/templates`, so the script finds its template beside it and never reaches for curl. Only those two files are build inputs, so the test rebuilds only when one of them changes.
- `yq-go` is on `PATH`, so the script doesn't re-execute through `nix shell`. If that check ever fails in the build, there is no `nix` there and the script exits 1 with its "needs yq-go" message: a loud failure, not a hang.
- `HOME` points at a directory that exists, so git has nowhere odd to read or write.
- `bash <script>` rather than executing it: the Linux build sandbox has no `/usr/bin/env` for the shebang.
- `test -f devenv.nix` makes the check fail if the script stops creating the file, instead of passing with nothing to check. `find ... -exec ... {} +` exits non-zero when nixfmt does.
- `--no-update` keeps `devenv` and the network out of the build.

Alternatives rejected:

- A bash test script run by `check.sh` outside a Nix build. It would need git, yq-go and nixfmt from `PATH` or added to `check-tools.nix`, would write a scratch repository from a sandboxed session, and wouldn't be cached. The build is hermetic and matches how the packages' tests already run.
- Extract the template into a file and check that file with the gate's existing nixfmt check. It tests the template, not what the script writes: a later `sed` or a second generated Nix file would slip through. It also makes the curl-piped script fetch one more file.
- Hang the test on the shell build, as the packages do with `# Tested by ${tested}`. `adopt.sh` isn't a package of the module; adopted projects would then build the test in their own shells for no benefit.
- Source the whole repository into the build. Every unrelated edit would rerun it.

### 3. A named gate step that needs no gate tools

`check.sh` gets a function and a step after `openspec validate`, before the shell builds:

```bash
# Runs adopt.sh in a fresh repository and checks the .nix files it creates
# (scripts/adopt-test.nix).
adopt_output_formatted() {
  nix build --impure --no-link -L -f scripts/adopt-test.nix
}
...
step "adopt: nixfmt" adopt_output_formatted
```

`step`, not `with_tools`: the build brings its own inputs, so it still runs when `check-tools.nix` fails to build. `--impure` for the same reason the tools build has it (`pinned-nixpkgs.nix` fetches from the lock). `-L` so nixfmt's "not formatted" line shows in the gate's output. No new bash features, so bash 3.2 is fine.

Alternative rejected: add the test to `check-tools.nix`'s `buildEnv` so the existing tools build runs it. A failing adoption test would then mark every tool-dependent check "tools unavailable" and hide their real results.

### 4. A new project-adoption requirement, not an edit to "The project is wired to the module"

The formatting rule is added as its own requirement with its own "Tested by" line. Folding it into the existing requirement would force that requirement's single "Tested by" line to claim a test that covers one clause of five. The existing requirement's text and its "Tested by: none" stay true as they are.

## Risks / Trade-offs

- [The adopted project's hook runs the nixfmt of the project's own `nixpkgs`, which `devenv update` sets to current unstable, not this module's pin. A newer nixfmt could format the template differently.] → The test proves cleanliness against the pinned nixfmt only, and the spec's "Tested by" line says so. The pin moves with the regular dependency updates, whose PRs run the gate, so a formatter change shows up there within one update cycle. The template is the plainest shape nixfmt has (the fixtures use it), which makes a change unlikely.
- [The test passes vacuously if the script writes nothing.] → `test -f devenv.nix` before the format check; task 2.3 proves the check fails on the old template.
- [An assumption about running `adopt.sh` in a build is wrong (yq version text, empty repository, sandbox).] → Task 2.2 builds it on macOS; the PR's `check` job builds it in the Linux sandbox. Any of these fails the build with the script's own message.
- [One more build in the gate.] → Small, cached after the first run, inputs from the public cache.
- [`check.sh`'s header says its tools come from `check-tools.nix`; the new step's come from `adopt-test.nix`.] → Task 3.1 updates the comment. Both use the same pinned nixpkgs, so the gate spec's "tools from the pinned revision" still holds.

## Migration Plan

None. Merging is the rollout: `adopt.sh` is run from a checkout or from `main`. Rollback is a revert.

## Open Questions

- Should projects adopted before this fix be told to reformat? They don't need it: each already reformatted `devenv.nix` to get its first commit through. Left as is unless someone reports otherwise.
