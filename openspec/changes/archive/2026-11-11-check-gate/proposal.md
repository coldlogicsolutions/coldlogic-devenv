# Proposal

## Why

The plugin conventions make `scripts/check.sh` the gate every commit passes, but this repository has none (#63), so implementers run the pieces by hand or skip them. There is also no PR CI: `dispatch-updates.yaml` runs only after a push to main, so PRs such as #74 report no checks and nothing builds the module's build-time tests (claude-guard, session-relink) or its profiles before a merge.

## What Changes

- New `scripts/check.sh`, the one gate, run locally as `devenv shell --quiet -- scripts/check.sh` (already allowed by the module's `scripts/check.sh` rule) and in CI. It runs every step even after one fails, prints a pass/fail summary, and exits non-zero if any step failed. The steps:
  - the guard's test cases (`python3 -I packages/claude-guard-test.py`);
  - `nixfmt --check` over every tracked `.nix` file;
  - `shellcheck` over `packages/*.sh` and `scripts/*.sh`;
  - `openspec validate --all --strict`;
  - `devenv build shell` for this repository's own shell, which builds every module package and so runs claude-guard's and session-relink's build-time tests;
  - `devenv --profile <ci|developer> build shell` for each fixture under `tests/fixtures`, so a broken profile fails the gate, not main's cache job.
- The gate takes its tools (python3, nixfmt, shellcheck, openspec) from the nixpkgs revision `devenv.lock` pins, not from whatever is on `PATH`, so a session, a terminal and CI run the same versions.
- `scripts/adopt.sh` fixes for the two shellcheck findings it has today (SC2016, SC2001), so the new step starts green.
- New `.github/workflows/check.yaml`: on `pull_request` and on push to main, one `check` job on Linux runs the gate with the same Nix, cachix and devenv setup and action pins as `dispatch-updates.yaml`, with `contents: read` only.
- `scripts/adopt.sh` lists a missing `scripts/check.sh` under "Needs you", saying what a gate must do, and README documents the gate. It doesn't write a stub.
- A follow-up issue asks Derek to make `check` a required status check in the main ruleset. The ruleset itself isn't changed here.

## Capabilities

### New Capabilities

- `gate`: the repository's pre-commit gate (`scripts/check.sh`): what it checks, where its tools come from, how it reports, and the PR workflow that runs it.

### Modified Capabilities

- `project-adoption`: adoption lists a missing `scripts/check.sh` among the steps left for the developer.

## Impact

- New: `scripts/check.sh`, the Nix expression for its tools, `.github/workflows/check.yaml`.
- Changed: `scripts/adopt.sh` (shellcheck fixes, the new note), README ("What's here", "Working on the module").
- CI minutes: one Linux job per PR push. The fixture shells substitute from the `coldlogic` cache that main's cache job fills, so a PR that doesn't touch the toolchain builds little.
- Projects that import the module see no change to their shells. Only adopt.sh's output gains a line.
- Out of scope: changing the ruleset (manual, Derek); a macOS PR job (see design.md).
