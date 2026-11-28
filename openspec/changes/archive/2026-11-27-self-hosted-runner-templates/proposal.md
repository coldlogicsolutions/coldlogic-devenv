# Proposal

## Why

The organization's self-hosted runner (`coldlogic-k3s`, arm64, named by the organization variable `RUNNER_LINUX`) is live for private repositories, but the update workflow every project copies from this repository still names `ubuntu-latest` on both jobs, and its steps can't run on the cluster: `nix profile add` conflicts with the devenv in the runner's image. The `coldlogic` cache also holds no aarch64-linux shells, so the first job on each cluster node builds them cold. infrastructure is waiting on the template to re-copy its own copy (coldlogicsolutions/coldlogic-devenv#143, follow-up of coldlogicsolutions/infrastructure#63).

## What Changes

- `templates/update-coldlogic-devenv.yaml`: both jobs run on `${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}`, never a literal label. A public repository reads the variable empty and stays on a GitHub-hosted runner.
- The template's steps pass unchanged on both kinds of runner: no `sudo`, nothing installed into the runner's Nix profile, no `if:` on the runner's kind.
- The `update` job takes devenv from the nixpkgs revision the project's own `devenv.lock` pins, with `nix shell "github:<owner>/<repo>/<rev>#devenv" -c devenv update coldlogic-devenv`, as infrastructure's `check.yaml` does. `cachix/install-nix-action` stays for the hosted fallback (it is a no-op on the cluster).
- The `update` job's Nix gets the job's read-only `github.token` for github.com through `NIX_CONFIG`, against the rate limit the cluster's shared address would otherwise hit.
- Both template jobs get `timeout-minutes` (15 for `update`, 10 for `pull-request`).
- `.github/workflows/dispatch-updates.yaml`: the cache matrix gains a literal third entry, `ubuntu-24.04-arm`, so the aarch64-linux shells are built and pushed next to x86_64-linux and macOS.
- Docs: the template's header comment, the cache matrix's comment, and README's adoption line and `dispatch-updates.yaml` row.

Not in this change:

- `gh` in the `pull-request` job comes from the runner's image, which carries it (gh 2.104.0, a dotfiles change reported on #143). The template's `gh` calls stay as they are.
- PR CI on arm (`.github/workflows/check.yaml` is unchanged).
- A workflow linter (actionlint) in the gate: a follow-up issue.
- Making the repositories private, and with it an App token in place of `github.token` for Nix.
- Re-copying the template into each adopting repository: `scripts/adopt.sh` copies it only when it is missing, so each repository's own PR does that.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `module-updates`: the cache requirement names x86_64 Linux, aarch64 Linux and macOS; new requirements say which runner the update workflow's jobs use and where its `update` job gets devenv and its GitHub token.
- `toolchain-profiles`: the fixture builds that test the profile layering run on three platforms, not two.

## Impact

- `templates/update-coldlogic-devenv.yaml`, `.github/workflows/dispatch-updates.yaml`, `README.md`.
- Every adopting repository, once it re-copies the template: a private one runs both jobs, the one holding the coldlogic-ai App key included, on the cluster.
- The `coldlogic` cachix cache: a third platform's store paths.
- The cache job: a third leg, on a GitHub-hosted arm64 runner. A failure of any leg still holds back the dispatch to every project.
- Depends on the runner image keeping `gh`, `jq`, `git` and Nix: the template takes all four from it on the cluster.
- Nothing in the gate (`scripts/check.sh`) reads workflow files, so none of this is tested before it runs.
