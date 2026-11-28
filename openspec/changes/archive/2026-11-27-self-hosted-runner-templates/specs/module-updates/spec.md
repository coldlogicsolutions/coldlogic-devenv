# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
