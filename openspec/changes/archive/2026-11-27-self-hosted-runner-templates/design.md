# Design

## Context

See proposal.md for the motivation. What shapes the approach:

**Checked in this repository**

- `templates/update-coldlogic-devenv.yaml` is the only template. Both jobs name `runs-on: ubuntu-latest` (lines 32 and 58). The `update` job runs `cachix/install-nix-action` (38), `nix profile add nixpkgs#devenv` (41) and `devenv update coldlogic-devenv` (44). The `pull-request` job (environment `coldlogic-ai`, main only) uses `jq` and `gh api` (90, 96, 121) and `gh pr merge --auto --squash` (186). Neither job has `timeout-minutes`. The workflow's token is `contents: read`.
- `.github/workflows/dispatch-updates.yaml`: the `cache` job's matrix is `runner: [ubuntu-latest, macos-latest]` (48), under a three-line comment (45-47); it installs devenv with `nix profile add nixpkgs#devenv` (65), is main-only and uses the `cachix` environment. Its `dispatch` job names `ubuntu-latest` (86).
- `scripts/adopt.sh:236-253` copies the template only when the project has none.
- `scripts/check.sh` runs guard tests, nixfmt, shellcheck, `openspec validate --all --strict`, the adoption build and the shell and fixture builds. It reads no workflow file.
- This repository's `devenv.lock` has `nixpkgs` as a direct input of the root, locked as `type: github` with `owner`, `repo` and `rev`, so infrastructure's `jq` expression yields `NixOS/nixpkgs/<rev>` here.
- No Nix file under `profiles/`, `packages/` or `tests/fixtures/` branches on the system or fetches a per-platform binary (a search for `system`, `hostPlatform`, `aarch64`, `x86_64`, `fetchurl` finds nothing).
- Specs: `module-updates` ("Main's shells are cached before projects are told" says "Linux and macOS"; "Projects get a checked update PR" is `Tested by: none`) and `toolchain-profiles` (line 11's Tested-by and line 15's scenario say Linux and macOS, "both platforms").
- Docs that describe this: `README.md` line 72 (the adoption line) and the `dispatch-updates.yaml` row of its table (line 187), the template's header comment, and the matrix comment.

**Checked in infrastructure's checkout** (`.github/workflows/check.yaml`, `README.md`, the `self-hosted-runners` design)

- Its `check` job uses `runs-on: ${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}`, keeps `install-nix-action`, and runs the gate in one step: `ref=$(jq -r '.nodes as $n | $n[$n.root.inputs.nixpkgs].locked | "\(.owner)/\(.repo)/\(.rev)"' devenv.lock)` then `nix shell "github:${ref}#devenv" -c devenv ...`. So `jq`, `git` and Nix with flakes work on the cluster runner.
- Its README: each job gets its own pod, destroyed after the job, with Nix, devenv and cachix in the image; no `sudo`; public repositories read the variable empty, and the Default runner group refuses them anyway. One repository can fall back by setting its own `RUNNER_LINUX` to `ubuntu-latest`.
- Its design (D6) rejects the image's devenv, changing the runner's profile, and an `if:` on the runner's kind. D9 leaves its copy of this template alone until this change; U3 accepts that jobs holding the App key run on the cluster.

**Reported by others, not re-checked here**

- From the researcher: `install-nix-action` exits early when Nix is present, so on the cluster it configures nothing, an access token included.
- From the dotfiles session, relayed by the coordinator and commented on #143: the `coldlogic-k3s` runner image now carries `gh` 2.104.0.

**Assumed**

- `install-nix-action` on a hosted runner already gives Nix `github.token` (its `github_access_token` input's default), so the `NIX_CONFIG` line adds nothing new there.
- The devenv of a project's locked nixpkgs downloads from a binary cache on both architectures. infrastructure's `check` relies on the same thing on both runners.
- `ubuntu-24.04-arm` is available to this repository because it is public.

## Goals / Non-Goals

**Goals:**

- One template file that passes unchanged on the cluster runner and on a hosted runner.
- The `update` job's devenv is the project's own locked one on both.
- aarch64-linux shells in the `coldlogic` cache before projects are told of a module update.
- Keep the template's trust split exactly as it is: the first job has no secret, the second takes three checked values from it.

**Non-Goals:**

- Providing `gh` to the `pull-request` job (the runner image does), PR CI on arm, a workflow linter in the gate, private repositories, and refreshing the template in adopting repositories. See proposal.md.
- Any change to `scripts/adopt.sh`, `.github/workflows/check.yaml`, or the `dispatch` job.

## Decisions

### D1. `runs-on` reads the variable, with the hosted label as its fallback

Both jobs: `runs-on: ${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}` (the user's decision 1, infrastructure's expression). A public repository reads the variable empty and gets `ubuntu-latest`.

The variable only routes jobs. It is not what keeps the App key from a stranger: that is the `coldlogic-ai` environment (main only), the runner group's refusal of public repositories, and the pods being single-use (infrastructure's U3 and R5).

Rejected:

- **The literal label `coldlogic-k3s`.** A public repository's job would be refused by the runner group and wait forever, and renaming the scale set would mean re-copying every template.
- **A matrix or a second job per runner kind.** Two PRs' worth of runs for one lock update.
- **Only the `update` job on the cluster, the `pull-request` job hosted.** It would keep the App key off the cluster, but the user settled that the key-holding job moves too (U3), and a split leaves a private repository still spending hosted minutes.

### D2. One step reads the locked nixpkgs and runs devenv through `nix shell`

"Install devenv" and "Update the pin" become one step, "Update the pin":

```yaml
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

The `jq` expression is infrastructure's plus a `strings` guard and `select(.type == "github")` (added in review): a lock locked through another forge, such as `gitlab`, also has `owner`, `repo` and `rev`, and would otherwise pass the pattern and be fetched from GitHub; so would a `github` node on an Enterprise `host`. With the filter it yields nothing, and the pattern stops it with the message. `nix shell` installs nothing, so it doesn't conflict with the image's devenv, and it is the same line on a hosted runner.

The shape check is this template's addition. infrastructure's workflow reads its own lock; this file is copied into projects whose locks vary. A root `nixpkgs` that is missing or a `follows` (a list) is dropped by `strings`, and one locked some other way (a tarball, a path, another forge) by the `select`, so `jq` prints nothing, which the pattern refuses. Either way the job stops with a message before Nix sees a strange flake reference. It is a guard against a malformed lock, not a boundary: whoever can change the lock on a branch can change the workflow there too.

Rejected:

- **The image's devenv on the cluster.** The update would run under whatever the image was built with, and differ from the hosted run (infrastructure D6).
- **`nix profile add` with `--priority`, or removing the image's devenv first.** Both change the runner's profile and need a branch for hosted runners.
- **`nix run nixpkgs#devenv`.** The registry's nixpkgs is unpinned and needs GitHub's API to resolve.
- **Dropping `install-nix-action`.** The hosted fallback has no Nix without it.
- **An `if:` that skips `install-nix-action` on the cluster.** It is a no-op there, and a condition on the runner's kind is one more difference between the two paths (the user's decision 1).
- **`jq -e`.** With the `select`, an empty result already fails the pattern with the job's own message.

### D3. Nix's GitHub token is set on that one step

`NIX_CONFIG: access-tokens = github.com=${{ github.token }}` goes on the "Update the pin" step, not the job or the workflow. `devenv update coldlogic-devenv` asks GitHub's API for the branch's head; from the cluster every job shares one address, and the unauthenticated limit is per address. The token is the job's own: the workflow's `permissions: contents: read` bounds it, and it dies with the job.

On the step, the token is in the environment of `jq`, Nix and devenv only, not of `actions/upload-artifact`. This job is the one the template calls untrusted (it runs Nix and devenv), so what it can read matters: with this token, the repository's own contents, which it has just checked out. It gains no write and no other repository.

Rejected:

- **Job-level or workflow-level `env`.** Wider than the step that needs it; at workflow level the `pull-request` job would carry it for nothing.
- **Writing `~/.config/nix/nix.conf`.** A file on the runner; `NIX_CONFIG` leaves nothing behind.
- **An App token now.** It needs the `coldlogic-ai` environment, which would put the App key in the job that runs Nix. It belongs to the change that makes repositories private.
- **No token.** Works on a hosted runner (the action already sets one), fails by rate limit on the cluster at some load.

### D4. `gh` stays as it is, and comes from the image

The `pull-request` job's four `gh` calls are unchanged (the user's decision 4). A hosted runner has `gh`, and the cluster's image carries it now (2.104.0, from dotfiles), so the dependency is met and nothing in the rollout waits on it.

The image is still what the job depends on. If a later image dropped `gh`, the job would fail at the first `gh api` with "command not found". That fails closed: no lock is rewritten and no PR opens.

Rejected:

- **`nix shell nixpkgs#gh` in the `pull-request` job.** It runs Nix, and fetches from a registry, in the job that holds the App key. Today that job runs nothing but `jq`, `gh` and three pinned actions.
- **Replacing `gh` with `curl`.** The same calls, hand-rolled, in the security-sensitive job, to avoid a tool the image should have anyway.

### D5. Timeouts: 15 minutes for `update`, 10 for `pull-request`

Neither job builds anything. `update` installs Nix on a hosted runner, downloads devenv and resolves one input: a few minutes. `pull-request` makes a handful of API calls: under a minute. 15 and 10 leave room for a slow download and still free a runner pod long before GitHub's six-hour default. A timeout counts from when the job starts, so a job queued for an offline runner still waits.

Rejected: infrastructure's 30 for both (that job runs a whole gate), and 5 for `pull-request` (a slow GitHub API on a bad day would fail a run that would have finished).

### D6. The arm leg is the literal `ubuntu-24.04-arm`

The matrix becomes `runner: [ubuntu-latest, ubuntu-24.04-arm, macos-latest]`. This repository is public, so `vars.RUNNER_LINUX` is empty here: `${{ vars.RUNNER_LINUX || 'ubuntu-latest' }}` would give a second x86_64 leg and report success while caching nothing for arm. And the cluster refuses public repositories outright. A GitHub-hosted arm64 runner produces the same aarch64-linux store paths the cluster needs.

The job's `nix profile add nixpkgs#devenv` stays: every leg is a hosted runner with an empty profile (the user's decision 5).

Rejected:

- **The variable.** Silently wrong here, as above.
- **Cross-building aarch64-linux on the x86_64 leg** (emulation or a cross toolchain). Slow, and cross-built paths aren't the paths a native shell asks for.
- **Building on the cluster.** It refuses this repository, and the job holds the cache's write token.
- **A separate, non-blocking arm job.** Projects would be told before the arm shells are cached, which is the cold build this change removes.

### D7. Routing and the locked devenv are new requirements, not edits to "Projects get a checked update PR"

That requirement is about what the PR may contain and is near the 500-character limit `openspec validate --strict` enforces. Runner routing and the devenv's source are separate behaviors, so each is an ADDED requirement in `module-updates`. The cache requirement and `toolchain-profiles`' layering requirement are MODIFIED whole, with only the platforms changed. Every Tested-by says what is true: the cache job's own runs, a hand check of the arm64-runner scenario on the first private repository's CI run (tasks.md, Workflow follow-up), and nothing in the gate.

## Risks / Trade-offs

- **R1. The App key on the cluster.** The `pull-request` job runs where another job's code ran minutes earlier. → Accepted by the user (infrastructure U3). It rests on pods being single-use and sharing nothing, on the main-only environment, and on the runner group refusing public repositories. This change adds no step to that job and no new input to it. The template's header states that the self-hosted runners must be ephemeral.
- **R2. The template depends on the image's tools.** `gh` is in the image now, with `jq`, `git` and Nix, but a rebuilt image could lose one. → D4: fails closed. The template's header says what the runner must provide, and the first run in a private repository is watched (Migration Plan).
- **R3. Nothing tests the workflows.** The gate reads no workflow file, so a YAML or expression mistake shows only when the workflow runs. → Small, literal edits with the exact text in tasks.md; the first run of each is watched (Migration Plan); actionlint in the gate is a follow-up issue.
- **R4. A third leg can hold back every project.** An arm-only failure, or a hosted arm runner that is slow to start, delays the dispatch. → That is the cache job's existing rule ("rerun the failed job"), and the alternative is projects building cold. The matrix sets `fail-fast: false` (added in review), so an arm failure doesn't cancel the other legs before they fill the cache. No Nix file in the profiles or fixtures is platform-specific (Context), but worker-build and topcoat have not been built on aarch64-linux by this repository before: the first run after merge shows it.
- **R5. The first arm run is cold.** It compiles what the other legs took from the cache, on a small runner, with no timeout on the job. → One-time; later runs substitute. The job's timeout is out of this change's scope.
- **R6. A project whose nixpkgs isn't a direct GitHub input.** Its update job now fails where it used to pass with the registry's devenv. → It fails with a message naming the cause. Every project adopted with `scripts/adopt.sh` has the direct input; one that removed it is told to restore it.
- **R7. The locked devenv might not be in a binary cache.** Then `nix shell` builds it and the job times out at 15 minutes. → infrastructure's gate takes devenv the same way on both architectures. If it happens, the run fails visibly and the pin stays where it was.
- **R8. The token in an untrusted job's environment.** → D3: read-only, this repository only, one step, and a hosted runner's Nix already had it.
- **R9. `ubuntu-24.04-arm` depends on the repository being public.** → Belongs to the change that makes repositories private, which must re-check the label then. Noted in the matrix comment.
- **R10. Copies drift.** `adopt.sh` never refreshes the template, so repositories run the old file until someone re-copies it. → The old file keeps working on hosted runners. README's adoption line says to re-copy after a template change.

## Migration Plan

1. Merge this change. The push to main runs `dispatch-updates.yaml` with the third leg: watch the `ubuntu-24.04-arm` job build and push, then the dispatch.
2. Each repository re-copies the template in its own PR, infrastructure first (its D9). Nothing else has to ship first: the runner image already carries `gh`. Public repositories stay on hosted runners.
3. In each private repository, run the workflow by hand once (`workflow_dispatch`) and check both jobs ran on `coldlogic-k3s`, the `pull-request` job's `gh` calls included.

Rollback: a repository sets its own `RUNNER_LINUX` variable to `ubuntu-latest` (infrastructure's README), which needs no commit; or it restores its previous copy. For the cache, remove the matrix entry.

## Open Questions

- Should the `cache` job get a timeout too? Not needed for this change; the cold arm run's duration, once seen, gives the number.
- Whether `scripts/adopt.sh` should refresh an existing template (or report a stale one) is a separate change.
