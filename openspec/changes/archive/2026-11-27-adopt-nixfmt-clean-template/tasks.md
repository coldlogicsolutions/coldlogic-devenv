# Tasks

Run every command through `devenv shell --quiet -- <cmd>`. Scratch files go under `$TMPDIR`, never in the repository.

## 1. The template

- [x] 1.1 In `scripts/adopt.sh`, in the `devenv.nix` heredoc (lines 162-168), delete the empty line between `{ pkgs, ... }:` and `{ }`. Change nothing else in the heredoc. Verify: write the four resulting lines to a scratch `devenv.nix` and run `nixfmt --check` on it; it exits 0. If it doesn't, stop and report rather than trying another shape (design.md, decision 1).

## 2. The test

- [x] 2.1 Add `scripts/adopt-test.nix` as in design.md, decision 2: a header comment saying what it tests and how to build it (`nix build --impure --no-link -L -f scripts/adopt-test.nix`), `pkgs = import ./pinned-nixpkgs.nix`, a `runCommand "coldlogic-adopt-test"` with `nativeBuildInputs` bash, coreutils, findutils, gnugrep, gnused, git, yq-go, nixfmt, and a script that sets `HOME` to a directory it creates, copies `./adopt.sh` to `src/scripts/adopt.sh` and `../templates/update-coldlogic-devenv.yaml` to `src/templates/`, runs `git init -q` in an empty `project` directory, runs `bash ../src/scripts/adopt.sh --no-update` there, requires `devenv.nix` to exist, runs `nixfmt --check` on every `*.nix` outside `.git`, and touches `$out`. Verify: `nixfmt --check scripts/adopt-test.nix` exits 0.
- [x] 2.2 Build it: `nix build --impure --no-link -L -f scripts/adopt-test.nix`. Verify it exits 0 and the log shows the script's "Changed:" list with `devenv.nix (new)` and the workflow copied (no curl, no `nix shell`). If the script fails inside the build, fix the test's setup (inputs, `HOME`, layout), not `adopt.sh`'s behavior; report anything that would need a change to `adopt.sh` beyond task 1.1.
- [x] 2.3 Prove the test catches the bug: put the blank line back in the heredoc, rebuild, and verify the build fails with nixfmt naming `devenv.nix` as not formatted. Remove the blank line again and verify the build passes. Then prove it isn't vacuous: temporarily change the test's `test -f devenv.nix` target to a name the script doesn't create, verify the build fails, and restore it.

## 3. The gate

- [x] 3.1 In `scripts/check.sh`, add the function `adopt_output_formatted` (it runs `nix build --impure --no-link -L -f scripts/adopt-test.nix`) with a one-line comment, next to the other check functions, and the line `step "adopt: nixfmt" adopt_output_formatted` after the `openspec validate` step and before `build: shell`. Use `step`, not `with_tools` (design.md, decision 3). Update the header comment (lines 10-11) to say the adoption test's tools come from the same pinned nixpkgs through `scripts/adopt-test.nix`. Keep it bash 3.2 compatible. Verify: `shellcheck --shell=bash scripts/check.sh` exits 0.
- [x] 3.2 In `README.md`, add the adoption check to the `scripts/check.sh` row (line 186), after `openspec validate --all --strict`: it runs `scripts/adopt.sh` in a fresh repository and checks the `.nix` files it creates with `nixfmt --check` (`scripts/adopt-test.nix`). Add a `scripts/adopt-test.nix` row to the same table beside the `scripts/adopt.sh` row. Verify both rows read correctly against the code.

## 4. Verification

- [x] 4.1 Run `openspec validate adopt-nixfmt-clean-template --strict` and verify it passes.
- [x] 4.2 Run the gate: `devenv shell --quiet -- scripts/check.sh`. Verify the summary lists `adopt: nixfmt` as passed, every other check passed, and the exit code is 0.

## Workflow follow-up

- On the PR, confirm the `check` job's log shows `adopt: nixfmt` passing in the Linux build sandbox.
