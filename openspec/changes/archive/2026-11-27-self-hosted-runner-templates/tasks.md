# Tasks

Run every command through `devenv shell --quiet -- <cmd>`, one per Bash call, unpiped. Edit files with the Edit and Write tools only. See design.md for the reasons behind each choice.

Nothing in the gate reads workflow files, so each task below is verified by reading the result back with `grep` or `git diff`. Take the YAML from these tasks exactly, indentation included: a mistake shows only when the workflow runs.

Don't touch `.github/workflows/check.yaml`, `scripts/adopt.sh`, the `dispatch` job, or any `gh` call in the template.

## 1. The template's `update` job

This job runs Nix and devenv, so it is the one the template treats as untrusted. The invariant to keep: it has no secret and no environment, its token is the workflow's `contents: read`, and it hands the next job nothing but `devenv.lock`.

- [x] 1.1 In `templates/update-coldlogic-devenv.yaml`, the `update` job: replace `runs-on: ubuntu-latest` with the lines below (design D1, D5). Verify `grep -n -A1 "^  update:" templates/update-coldlogic-devenv.yaml` shows the comment's first line after `update:`.

  ```yaml
      # The organization's self-hosted runner when RUNNER_LINUX is set, a
      # GitHub-hosted one when it's empty (public repositories). Never the
      # runner's label itself.
      runs-on: ${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}
      # Nothing here builds: a few minutes at most. Counts once the job starts.
      timeout-minutes: 15
  ```

- [x] 1.2 In the same job, add a comment above `- uses: cachix/install-nix-action@...`, leaving the `uses:` line and its pin unchanged: `# For the GitHub-hosted runner. The self-hosted runner's image has Nix, and` / `# the action does nothing there.` (two comment lines, indented like the step). Verify `grep -c "cachix/install-nix-action@75c75c31ebece974e48ebc36b4ad125bd97bd97b" templates/update-coldlogic-devenv.yaml` prints 1.

- [x] 1.3 Replace the two steps "Install devenv" and "Update the pin" (the lines from `- name: Install devenv` through `run: devenv update coldlogic-devenv`) with the single step below (design D2, D3). The `jq` expression is infrastructure's `check.yaml`'s plus a `strings` guard and `select(.type == "github")`, added in review. Threats this step answers: the pattern stops a lock whose nixpkgs isn't a GitHub revision from reaching Nix as a strange flake reference (a guard against a malformed lock, not a boundary); the token is the job's own read-only one and is set on this step only, so no other step of the job sees it in its environment. Don't move `NIX_CONFIG` to the job or the workflow, and don't add any other token.

  ```yaml
      # The devenv from the nixpkgs revision the project's devenv.lock pins,
      # not the registry's and not the runner image's. `nix shell` installs
      # nothing: `nix profile add` would conflict with the devenv already in
      # the self-hosted runner's image. The lock must name a GitHub revision.
      #
      # NIX_CONFIG gives Nix this job's read-only token for github.com:
      # `devenv update` asks GitHub's API for the module's latest revision,
      # and the self-hosted runner's jobs share one address and its
      # unauthenticated rate limit. Set on this step only.
      - name: Update the pin
        env:
          NIX_CONFIG: access-tokens = github.com=${{ github.token }}
        run: |
          set -euo pipefail
          ref=$(jq -r '.nodes as $n | ($n.root.inputs.nixpkgs | strings) as $k | $n[$k].locked | select(.type == "github" and (.host // "github.com") == "github.com") | "\(.owner)/\(.repo)/\(.rev)"' devenv.lock)
          [[ $ref =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[0-9a-f]{40}$ ]] ||
            { echo "devenv.lock: the root nixpkgs input must be a direct github input on github.com, locked to a revision" >&2; exit 1; }
          nix shell "github:${ref}#devenv" -c devenv update coldlogic-devenv
  ```

  Verify: `grep -n "nix profile" templates/update-coldlogic-devenv.yaml` finds comment lines only, no `run:`; `grep -c "NIX_CONFIG:" templates/update-coldlogic-devenv.yaml` prints 1; and the step's `jq` expression in this repository prints `NixOS/nixpkgs/` followed by 40 hex characters, which the pattern accepts.

- [x] 1.4 Check the invariant held: `git diff templates/update-coldlogic-devenv.yaml` shows no change to the workflow's `permissions:`, no `environment:` or `secrets.` added to the `update` job, and the `actions/upload-artifact` step unchanged.

## 2. The template's `pull-request` job

This job holds the coldlogic-ai App key. The invariant to keep: it runs no Nix and nothing from the first job, and takes only the three checked values from the first job's lock. Only its runner and its timeout change.

- [x] 2.1 Replace the `pull-request` job's `runs-on: ubuntu-latest` with the lines below (design D1, D4, D5), leaving `needs:`, `if:`, `environment:` and `permissions:` as they are.

  ```yaml
      # As the update job. On the self-hosted runner, `gh` and `jq` come from
      # its image.
      runs-on: ${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}
      # A handful of API calls. Counts once the job starts.
      timeout-minutes: 10
  ```

  Verify: `grep -n "runs-on:" templates/update-coldlogic-devenv.yaml` prints exactly two lines, both `runs-on: ${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}`; `grep -n "timeout-minutes:" templates/update-coldlogic-devenv.yaml` prints 15 then 10; `grep -c "ubuntu-latest" templates/update-coldlogic-devenv.yaml` prints 2.

- [x] 2.2 Check the invariant held: in `git diff templates/update-coldlogic-devenv.yaml`, the only changed lines of the `pull-request` job are those of 2.1. `grep -c "gh api\|gh pr merge" templates/update-coldlogic-devenv.yaml` still prints 4, and `grep -n "sudo\|nix " templates/update-coldlogic-devenv.yaml` finds nothing below the `pull-request:` line.

## 3. The template's header and README's adoption line

- [x] 3.1 In the template's header comment, after the paragraph that ends "hands over nothing but devenv.lock." and before `name: Update coldlogic-devenv`, add a `#` line and this paragraph. Verify by reading the header back.

  ```yaml
  #
  # Both jobs run on the organization's self-hosted runner when the RUNNER_LINUX
  # variable is set (private repositories), and on a GitHub-hosted one when it
  # is empty (public ones). The steps must pass unchanged on both: no `sudo`,
  # nothing installed into the runner's Nix profile (`nix shell`, not
  # `nix profile add`), no `if:` on the runner's kind. The self-hosted runner's
  # image provides nix, jq, git and gh, and its runners must be ephemeral (one
  # pod per job, nothing shared), since the update job's Nix code and the
  # pull-request job's App key share that runner pool.
  ```

- [x] 3.2 In `README.md`, replace the line that starts "Copy `templates/update-coldlogic-devenv.yaml` to `.github/workflows/`" (line 72) with: "Copy `templates/update-coldlogic-devenv.yaml` to `.github/workflows/` and register the repository in the infrastructure stack, which shares the App credentials it needs. Its jobs run on the organization's self-hosted runner where the `RUNNER_LINUX` variable is set (private repositories) and on a GitHub-hosted one elsewhere. `scripts/adopt.sh` copies the workflow only when the project has none, so copy it again after the template changes." Verify `grep -c "RUNNER_LINUX" README.md` prints 1.

## 4. The aarch64-linux cache leg

This job holds the cache's write token (`cachix` environment, main only). Only its matrix, the matrix's comment and `fail-fast: false` (added in review, so one leg's failure doesn't cancel the others) change.

- [x] 4.1 In `.github/workflows/dispatch-updates.yaml`, replace the matrix's three comment lines and its `runner:` line (lines 45-48) with the lines below (design D6). The arm entry is the literal label: never `vars.RUNNER_LINUX`, which is empty in this public repository and would silently give a second x86_64 leg.

  ```yaml
          # CI's platforms (x86_64 on GitHub's runners, aarch64 on the
          # organization's self-hosted one) and the developers' machines. The
          # arm leg is a literal GitHub-hosted label, never vars.RUNNER_LINUX:
          # this repository is public, so it reads that variable empty, which
          # would run a second x86_64 leg and cache nothing for arm. Check the
          # label again if this repository is made private. A failure on any
          # leg holds back the dispatch to every project: rerun the failed job
          # once it's fixed or found to be transient.
          runner: [ubuntu-latest, ubuntu-24.04-arm, macos-latest]
  ```

  Verify: `grep -n "runner:" .github/workflows/dispatch-updates.yaml` prints that one line; `grep -n "nix profile add nixpkgs#devenv" .github/workflows/dispatch-updates.yaml` still finds the "Install devenv" step (it stays: every leg is a hosted runner); `git diff --stat .github/workflows/dispatch-updates.yaml` shows changes in that one hunk only.

- [x] 4.2 In `README.md`, the `.github/workflows/dispatch-updates.yaml` row of the "What's here" table: replace "on Linux and macOS" with "on x86_64 Linux, aarch64 Linux (a GitHub-hosted arm64 runner, for the organization's self-hosted one) and macOS". Leave the rest of the row. Verify `grep -c "on Linux and macOS" README.md` prints 0.

## 5. Gate

- [x] 5.1 Run `devenv shell --quiet -- openspec validate self-hosted-runner-templates --strict` and verify it reports the change valid.
- [x] 5.2 Run `devenv shell --quiet -- scripts/check.sh` and verify the summary shows every check passed. It doesn't read the two workflow files: say so in the PR's test plan, and list there what was checked by hand (tasks 1.4 and 2.2).

## Workflow follow-up

- After the merge, watch the `dispatch-updates.yaml` run on main: the `ubuntu-24.04-arm` leg builds and pushes (cold, the first time), and the dispatch follows. If the leg fails on something arm-specific, the dispatch is held back for every project until it is fixed.
- Each repository re-copies the template in its own PR, infrastructure first. The runner image already carries `gh`, so nothing else has to ship first. In a private repository, then run the workflow by hand once and check both jobs ran on `coldlogic-k3s`, the first downloaded devenv rather than building it, and the second's `gh` calls passed. Also check that the repository's first CI run on `coldlogic-k3s` downloads its `ci` shell from the `coldlogic` cache rather than building it (the arm64-runner scenario in `module-updates`).
- Follow-up issue: actionlint (or another workflow check) in the gate.
- Archive the change on the feature branch as the last commit before the PR merges.
