# Tasks

## 1. The gate's tools

- [x] 1.1 Add `scripts/check-tools.nix`: imports the nixpkgs node `devenv.lock`'s root names (via `builtins.fetchTree` on its `locked` attrs) and returns a `buildEnv` of `python3`, `nixfmt`, `shellcheck`, `openspec`. Verify `nix build --impure --no-link --print-out-paths -f scripts/check-tools.nix` prints a path whose `bin/nixfmt` and `bin/openspec` are the same store paths as in `devenv shell`.

## 2. Make the source checks pass

- [x] 2.1 Fix `scripts/adopt.sh`'s SC2016 (deliberate literal `$schema`: a `# shellcheck disable=SC2016` with a reason) and SC2001 (rewrite or disable with a reason). Verify `shellcheck --shell=bash packages/*.sh scripts/*.sh`, with the tools from 1.1, exits 0, and that `scripts/adopt.sh --help` still prints its usage.

## 3. scripts/check.sh

- [x] 3.1 Write `scripts/check.sh` (executable, `set -uo pipefail`, no `-e`, no `| tail`): build the tools (1.1) and put their `bin` first on `PATH`; a `step` helper that runs each check, records pass/fail and never stops the script; steps for `python3 -I packages/claude-guard-test.py`, `nixfmt --check` over `git ls-files '*.nix'`, `shellcheck --shell=bash packages/*.sh scripts/*.sh`, `openspec validate --all --strict`, `devenv build shell` at the root, and, after copying `devenv.lock` into each, `devenv --profile ci build shell` and `devenv --profile developer build shell` in every `tests/fixtures/*/`. Tool-dependent steps fail as "tools unavailable" if 1.1's build fails. End with one line per step and exit 1 if any failed. Verify with the session run in 6.1.
- [x] 3.2 Make check.sh pass its own checks: it is covered by the shellcheck glob and `check-tools.nix` by the nixfmt step. Verify both steps pass.
- [x] 3.3 README: add `scripts/check.sh` and `.github/workflows/check.yaml` rows to "What's here", and under "Working on the module" say to run `devenv shell --quiet -- scripts/check.sh` before each commit. Verify the commands as written run.

## 4. PR CI

- [ ] 4.1 Add `.github/workflows/check.yaml`: `pull_request` and `push` to main; top-level `permissions: {}`, job `check` with `contents: read`; `ubuntu-latest`; checkout (persist-credentials false), install-nix-action, cachix-action (`name: coldlogic`, no token), `nix profile add nixpkgs#devenv`, `scripts/check.sh`; the same action SHAs and version comments as `dispatch-updates.yaml`; per-ref concurrency cancelling superseded PR runs. Verify the file passes `nix run nixpkgs#actionlint` or an equivalent YAML check, and by its run in 6.1.

## 5. adopt.sh and its spec

- [x] 5.1 In `scripts/adopt.sh`, when `scripts/check.sh` is missing, add a "Needs you" note: the conventions expect `scripts/check.sh` as the gate; it must run the project's tests, formatters and linters and exit non-zero on any failure; coldlogic-devenv's is an example. Verify in a scratch git repo (`git init` under `$TMPDIR`, `--no-update --no-workflow --no-envrc`) that the note appears and no `scripts/check.sh` is created, and that with an existing `scripts/check.sh` the note is absent.

## 6. Verification

- [x] 6.1 In a Claude Code session, in this fresh worktree, run `devenv shell --quiet -- scripts/check.sh`. Verify every step passes, the summary lists each, and the exit code is 0 despite the shell's own task failures.
- [x] 6.2 Break one check on purpose (misformat a `.nix` file, for example add stray spaces in `packages/gh-app.nix`), rerun the gate, and verify the nixfmt step fails, the later steps still run, and the exit code is non-zero. Revert and verify it passes again.
- [x] 6.3 Run `openspec validate check-gate --strict` and verify it passes.
- [ ] 6.4 Open the PR and verify the `check` job runs on it and passes (`gh-app pr checks`). Read its log to confirm each step ran and the fixture shells substituted from the cache.
- [ ] 6.5 Open an issue (`gh-app issue create`) asking Derek to add `check` as a required status check to the main ruleset once the workflow has run on main, linking this PR. Verify the issue exists.

## Workflow follow-up

- Archive the change after the PR merges.
- After the ruleset issue is done, confirm a PR shows `check` as required.
