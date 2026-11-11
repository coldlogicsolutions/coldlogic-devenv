# Spec Delta

## Purpose

How projects stay on the module's latest revision. Each project pins the module in `devenv.lock`. The shell warns when that pin is behind, and the module's main pushes cached shells and asks every project to open an update PR.

## ADDED Requirements

### Requirement: The shell warns when the pin is behind
On each `developer` shell, the module SHALL compare the project's locked `coldlogic-devenv` revision with the remote's HEAD. When they differ it SHALL print `coldlogic-devenv is behind (locked <rev>, latest <rev>); run: devenv update coldlogic-devenv`. It SHALL stay silent for a local `path:` input, with no lock, or when offline, and SHALL never fail the shell.

Tested by: none.

#### Scenario: Behind the remote
- **WHEN** the lock pins an older revision than the remote's HEAD
- **THEN** the shell prints the behind warning with both short revisions

#### Scenario: Developing the module locally
- **WHEN** the project points `coldlogic-devenv` at a `path:` input
- **THEN** the shell prints nothing about freshness

### Requirement: The freshness check caches the remote for an hour
The check SHALL remember the remote's HEAD in `$DEVENV_STATE/coldlogic-freshness` for an hour, and use that entry only when it confirms the lock is current. It SHALL time out the network lookup after three seconds.

Tested by: none.

#### Scenario: Repeated shells
- **WHEN** a developer enters the shell twice within an hour with a current lock
- **THEN** the second shell doesn't contact the remote

### Requirement: Main's shells are cached before projects are told
On every push to main, the dispatch workflow SHALL build each fixture's `ci` and `developer` shells with the module's `devenv.lock` on Linux and macOS and push them to the `coldlogic` cachix cache. Only then SHALL it send the `coldlogic-devenv-updated` event. Every shell SHALL substitute from that cache.

Tested by: the workflow itself.

#### Scenario: A profile breaks
- **WHEN** a commit on main makes a fixture's shell fail to build
- **THEN** no project receives the update event

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
