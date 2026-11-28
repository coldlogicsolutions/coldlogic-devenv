# module-updates Specification

## Purpose
How projects stay on the module's latest revision. Each project pins the module in `devenv.lock`. The shell warns when that pin is behind, and the module's main pushes cached shells and asks every project to open an update PR.

## Requirements

### Requirement: The shell warns when the pin is behind
On each `developer` shell, the module SHALL compare the project's locked `coldlogic-devenv` revision with the remote's HEAD. When they differ it SHALL print `coldlogic-devenv is behind (locked <rev>, latest <rev>); run: devenv update coldlogic-devenv`. It SHALL stay silent for a local `path:` input, with no lock, or when offline, and SHALL never fail the shell. In a session it SHALL print it once per session (session-notices).

Tested by: `packages/session-shell-test.sh`, the once rule only.

#### Scenario: Behind the remote
- **WHEN** the lock pins an older revision than the remote's HEAD
- **THEN** the shell prints the behind warning with both short revisions

#### Scenario: Developing the module locally
- **WHEN** the project points `coldlogic-devenv` at a `path:` input
- **THEN** the shell prints nothing about freshness

#### Scenario: A session's later shells
- **WHEN** a session's shell printed the behind warning, and the same session enters the shell again with the same two revisions
- **THEN** the second shell prints nothing about freshness

#### Scenario: A terminal's later shells
- **WHEN** a developer enters the shell from a terminal twice while the lock is behind
- **THEN** both shells print the warning

### Requirement: The freshness check caches the remote for an hour
The check SHALL remember the remote's HEAD in `$DEVENV_STATE/coldlogic-freshness` for an hour, and use that entry only when it confirms the lock is current. It SHALL time out the network lookup after three seconds.

Tested by: none.

#### Scenario: Repeated shells
- **WHEN** a developer enters the shell twice within an hour with a current lock
- **THEN** the second shell doesn't contact the remote

### Requirement: Main's shells are cached before projects are told
On every push to main, the dispatch workflow SHALL build each fixture's `ci` and `developer` shells with the module's `devenv.lock` on x86_64 Linux, aarch64 Linux and macOS and push them to the `coldlogic` cachix cache. Only then SHALL it send the `coldlogic-devenv-updated` event. Every shell SHALL substitute from that cache.

Tested by: the workflow's runs on main; the arm64-runner scenario by hand. Not the gate.

#### Scenario: A profile breaks
- **WHEN** a commit on main makes a fixture's shell fail to build
- **THEN** no project receives the update event

#### Scenario: A profile breaks on one platform only
- **WHEN** a commit on main makes a fixture's shell fail to build on aarch64 Linux and nowhere else
- **THEN** no project receives the update event

#### Scenario: A project's job on the organization's arm64 runner
- **WHEN** a project aligned with the module's lock enters its `ci` shell on an aarch64 Linux runner
- **THEN** the shell's store paths download from the `coldlogic` cache rather than build

### Requirement: Every repository with the update workflow is told
The dispatch job SHALL send `coldlogic-devenv-updated` to each non-archived repository the App is installed on that has `.github/workflows/update-coldlogic-devenv.yaml`. It SHALL skip repositories without it and fail the job if any check or send fails. It SHALL use an App token limited to Contents write.

Tested by: none.

#### Scenario: Repository without the workflow
- **WHEN** a repository has no update workflow
- **THEN** the job logs that it was skipped and continues

### Requirement: Projects get a checked update PR
The update workflow SHALL run weekly, by hand, and on `coldlogic-devenv-updated`. It SHALL take only the new revision, narHash and lastModified from an untrusted job. It SHALL refuse a revision that isn't on the module's main or is behind the current pin. It SHALL open or refresh one PR as the App, with auto-merge on.

Tested by: none.

#### Scenario: Revision off main
- **WHEN** the updated lock names a revision that isn't on coldlogic-devenv's main
- **THEN** the workflow fails without opening a PR

#### Scenario: Normal update
- **WHEN** the module's main has moved
- **THEN** the project gets an `Update coldlogic-devenv` PR (commit `chore(devenv): update coldlogic-devenv`) from `coldlogic-ai[bot]`, with `derekjw` requested as reviewer and auto-merge on

### Requirement: Shared inputs are aligned with the module's lock
The update workflow SHALL move the project's `nixpkgs`, `rust-overlay`, `git-hooks` and `devenv` to the revisions the module locks, but only for inputs the project declares the same way as the module. Others SHALL be left alone.

Tested by: none.

#### Scenario: Project pins its own nixpkgs branch
- **WHEN** the project declares `nixpkgs` differently from the module
- **THEN** the workflow logs `nixpkgs: declared differently from the module's, left alone` and doesn't change it

### Requirement: The update workflow runs on either kind of runner
Both jobs of the update workflow SHALL run on the runner the `RUNNER_LINUX` variable names, and on `ubuntu-latest` when it is empty; neither SHALL name a self-hosted label itself. The same steps SHALL run on both kinds of runner: none uses `sudo`, installs into the runner's Nix profile, or is conditional on the runner's kind. Each job SHALL have a timeout.

Tested by: none. Nothing in the gate reads workflow files.

#### Scenario: Private repository
- **WHEN** the workflow runs in a repository that reads `RUNNER_LINUX` as `coldlogic-k3s`
- **THEN** both jobs, the one that holds the App key included, run on that runner

#### Scenario: Public repository
- **WHEN** the workflow runs in a repository that reads `RUNNER_LINUX` as empty
- **THEN** both jobs run on `ubuntu-latest`

#### Scenario: A job hangs
- **WHEN** a step of either job never finishes
- **THEN** the job is cancelled at its timeout rather than at GitHub's six-hour default

### Requirement: The update job runs the project's locked devenv
The update job SHALL run `devenv update coldlogic-devenv` with the devenv of the nixpkgs revision the project's `devenv.lock` pins, not the registry's nor the runner image's, and without installing it. It SHALL fail when the lock names no GitHub nixpkgs revision. It SHALL give Nix the job's read-only token for github.com, and no other credential.

Tested by: none. Nothing in the gate reads workflow files.

#### Scenario: Runner with a devenv in its image
- **WHEN** the job runs on a runner whose Nix profile already holds a devenv
- **THEN** the pin is updated with the lock's devenv, and the runner's profile is unchanged

#### Scenario: Lock without a GitHub nixpkgs
- **WHEN** the project's `devenv.lock` has no direct `nixpkgs` input locked to a GitHub revision
- **THEN** the job fails before running devenv

#### Scenario: Nix asks GitHub for the module's latest revision
- **WHEN** `devenv update` resolves the module's branch through GitHub's API from an address other jobs share
- **THEN** the request carries the job's token rather than counting against the address's unauthenticated limit
