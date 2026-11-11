# Design

## Context

See proposal.md for why. What shapes the approach:

- `devenv shell -- true` builds the module's packages, but inside a sandboxed Claude Code session it fails in a fresh worktree: `devenv:git-hooks:install` can't find `.pre-commit-config.yaml`, which the session can't write, and `devenv:files` and the plugin install hit EPERM. The command after `--` still runs, but `-- true` as a build check reports the tasks' failures, not the build's.
- `devenv build shell` (devenv 2.4) evaluates and builds the shell without running any task. Probed in a session, from a fresh worktree: it builds this repository's shell in seconds, and its closure holds `coldlogic-claude-guard`, `coldlogic-session-relink-test`, `gh-app` and `claude-plugins-install`, so the build-time tests run. `devenv --profile ci|developer build shell` in a fixture works the same, also nested inside `devenv shell`.
- `dispatch-updates.yaml`'s cache job builds each fixture's `ci` and `developer` shells with `devenv shell -- true`, but only on main, on Linux and macOS, after the merge.
- The shell's `PATH` has `nixfmt` (1.5.0, the hook's), `prek` and `openspec`, but no `shellcheck`, and `python3` there is whatever the machine has. `prek run --all-files` needs the generated `.pre-commit-config.yaml`, so it fails in a fresh session worktree.
- shellcheck at default severity today: `packages/{claude-plugins-install,gh-app,gh-app-token}.sh` have no shebang (they become `writeShellApplication` bodies), so SC2148; `scripts/adopt.sh` has SC2016 (an intentional literal `$schema`) and SC2001.

## Goals / Non-Goals

**Goals:**
- One command that gives the same verdict in a session, a terminal and CI.
- PR CI that a ruleset can require.

**Non-Goals:**
- Changing the module's shells or what importing projects get.
- Replacing the cache job: it still pushes to cachix and gates the dispatch.
- Editing the ruleset.

## Decisions

**Build with `devenv build shell`, not `devenv shell -- true` or `nix build` over `packages/*.nix`.** `devenv build` runs no tasks, so the sandbox's write limits don't matter, and it evaluates the module the way a project's shell does (the `checkoutFromDotGit` assertions included). Building `packages/*.nix` with `nix build --impure --expr` would miss `claude-plugins-install` and `topcoat-cli`, which are defined inline or need devenv's `config`, and wouldn't evaluate the profiles at all. The gate builds:
- the root (`devenv build shell`, this repository's developer shell);
- each `tests/fixtures/*/` × `ci`, `developer`, after copying `devenv.lock` in, as the cache job does. The fixture copies are gitignored.

**Tools from the lock, not from `PATH`.** A small Nix expression beside the script (`scripts/check-tools.nix`) imports the nixpkgs node `devenv.lock`'s root points at (`builtins.fetchTree` on its `locked` attrs) and returns a `buildEnv` of `python3`, `nixfmt`, `shellcheck` and `openspec`. The script builds it with `nix build --impure --no-link --print-out-paths` and puts its `bin` first on `PATH`. Probed: the store paths match the shell's `nixfmt` and `openspec`, so there is no second version to drift. This keeps shellcheck out of every project's developer shell, and lets CI run `scripts/check.sh` without entering the shell (no git-hooks install, no plugin install on the runner). `fetchTree` needs the `flakes` feature, which local Nix and `install-nix-action` both enable. Alternative considered: adding `shellcheck` and `python3` to the module's developer packages, rejected because it changes every project's shell for one repository's gate.

**nixfmt directly, not prek.** `nixfmt --check $(git ls-files '*.nix')` uses the hook's formatter without the generated config prek needs.

**shellcheck with `--shell=bash`, default severity.** The `packages/*.sh` bodies have no shebang by design, so the shell is given. Default severity matches what `writeShellApplication` already enforces at build time. adopt.sh's two findings are fixed in the same change (a `# shellcheck disable=SC2016` on the deliberate literal, and the `sed` prefixing kept with a disable or rewritten), so the step starts green.

**Script shape.** `set -uo pipefail`, no `-e`. A `step <name> <command...>` helper runs each check, prints a header, records pass/fail, and never stops the script. Output goes straight to the terminal, never through `| tail`. If the tools build fails, the checks that need those tools are recorded as failed ("tools unavailable") and the build steps still run. The end prints one line per step and exits 1 if any failed.

**CI: `.github/workflows/check.yaml`.** Triggers `pull_request` and `push: branches: [main]`. Top-level `permissions: {}`, job-level `contents: read`. One job, `check`, on `ubuntu-latest`: `actions/checkout` (persist-credentials false), `cachix/install-nix-action`, `cachix/cachix-action` with `name: coldlogic` and no auth token (pull only, `skipPush: true`), devenv installed from the nixpkgs revision `devenv.lock` pins (`nix profile add --impure --expr '(import ./scripts/pinned-nixpkgs.nix).devenv'`, the same node `check-tools.nix` uses), then `scripts/check.sh`. Same SHAs and version comments as `dispatch-updates.yaml`. `concurrency` per ref with `cancel-in-progress: true` for PRs, since only the latest head matters. Linux only: the gate runs locally on macOS before every commit, and the cache job still builds macOS on main before any project is told. A macOS PR job can be added later as a matrix without changing the gate.

**Ruleset.** Once the workflow has run on main, the `main` ruleset can require the `check` status check, so neither auto-merge nor a manual merge lands a PR that fails the gate. Changing the ruleset is Derek's, so the change opens an issue for it and leaves the ruleset alone.

**adopt.sh: a note, not a stub.** What a gate runs is project-specific (cargo test and clippy for a Rust worker, nothing of the sort here). A stub that passes would be a gate that checks nothing; one that fails would block the adopting project's first commit. So when `scripts/check.sh` is missing, adopt.sh adds a "Needs you" line saying the conventions expect one, that it must run the project's checks and exit non-zero on failure, and that this repository's is an example. It writes no file, so the idempotency requirement is unaffected.

## Risks / Trade-offs

- [Fixture builds are slow on a cold cache] → they substitute from `coldlogic`, which the cache job fills on every main push; a PR that moves the toolchain builds it once, as the cache job would after the merge.
- [`dispatch-updates.yaml` still installs `nixpkgs#devenv` unpinned] → `check.yaml` pins devenv to the lock's nixpkgs; pinning the cache job the same way is a separate change.
- [bash 3.2 on macOS can run the gate when `env bash` finds `/bin/bash`] → the script avoids bash-4 features (`mapfile`, empty-array expansion under `set -u`). The root `nixpkgs` input must be a plain node name in `devenv.lock`; a follows list makes `pinned-nixpkgs.nix` throw.
- [The gate's devenv may differ from a developer's] → `devenv build` output format is stable enough for an exit-code check; the script relies on exit codes only.
- [Ruleset not yet requiring `check`] → until the follow-up lands, a failing PR can still be merged by hand; the check is visible either way.
