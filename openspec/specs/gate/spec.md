# gate Specification

## Purpose
`scripts/check.sh` is the one gate this repository's changes pass before a commit and before a merge: it runs the module's tests, formatters, linters, spec validation and builds, locally and in PR CI.

## Requirements

### Requirement: The gate runs every check and reports each
`scripts/check.sh` SHALL run each of its checks even when an earlier one fails, SHALL print a summary naming every check and whether it passed, and SHALL exit non-zero when any check failed and zero only when all passed.

Tested by: the deliberate-failure run in the change's tasks.

#### Scenario: One check fails
- **WHEN** a `.nix` file is misformatted and every other check passes
- **THEN** the gate still runs the later checks, its summary marks the formatting check failed and the rest passed, and it exits non-zero

#### Scenario: Everything passes
- **WHEN** every check passes
- **THEN** the summary marks each check passed and the gate exits 0

### Requirement: The gate checks sources, scripts and specs
The gate SHALL run the guard's test cases, check every tracked `.nix` file's formatting with the formatter the nixfmt hook uses, run shellcheck over `packages/*.sh` and `scripts/*.sh`, and run `openspec validate --all --strict`.

Tested by: the gate itself.

#### Scenario: A shellcheck finding
- **WHEN** a script under `scripts/` has a shellcheck finding
- **THEN** the shellcheck check fails and the gate exits non-zero

#### Scenario: An invalid spec
- **WHEN** a change's delta spec has a requirement without a scenario
- **THEN** the OpenSpec check fails

### Requirement: The gate builds the module and every profile
The gate SHALL build this repository's own shell, which builds the module's packages and so runs their build-time tests, and the `ci` and `developer` shells of every fixture under `tests/fixtures`, each with the module's `devenv.lock`, all with the memory variables unset. It SHALL also build its own shell with a placeholder memory store and with auto memory off, together and each alone, so every combination is evaluated.

Tested by: the gate itself.

#### Scenario: A guard test fails
- **WHEN** a change makes a case in `claude-guard-test.py` fail
- **THEN** the shell build fails and the gate exits non-zero

#### Scenario: A profile breaks
- **WHEN** a change makes a fixture's `ci` shell fail to evaluate or build
- **THEN** the gate fails for that fixture and profile

#### Scenario: The configured build
- **WHEN** the gate runs
- **THEN** one build of this repository's shell has `COLDLOGIC_MEMORY_URL` set to a placeholder host it never contacts, `COLDLOGIC_MEMORY_USER` set and `COLDLOGIC_DISABLE_AUTO_MEMORY=1`

#### Scenario: The mixed builds
- **WHEN** the gate runs
- **THEN** one build has only `COLDLOGIC_MEMORY_URL` and `COLDLOGIC_MEMORY_USER` set (`build: shell (memory store, auto memory on)`), and one only `COLDLOGIC_DISABLE_AUTO_MEMORY=1` (`build: shell (auto memory off)`)

#### Scenario: The memory settings break
- **WHEN** a change makes the settings generated with the memory store configured, or with only one of the store and the switch, fail to evaluate, and the shell without either still builds
- **THEN** the build for that combination fails and the gate exits non-zero

#### Scenario: The developer's own variable
- **WHEN** the gate runs on a machine, or in a session, where `COLDLOGIC_MEMORY_URL` or `COLDLOGIC_DISABLE_AUTO_MEMORY` is set
- **THEN** its ordinary shell and fixture builds still evaluate with neither, and its configured build uses the placeholder

### Requirement: The gate runs the same from a session, a terminal and CI
The gate SHALL take its tools from the nixpkgs revision `devenv.lock` pins rather than from `PATH`, and SHALL NOT need to write the shell's generated files, so it gives the same result inside a sandboxed Claude Code session, in a terminal and in CI.

Tested by: the session run in the change's tasks.

#### Scenario: Fresh worktree in a session
- **WHEN** a session runs `devenv shell --quiet -- scripts/check.sh` in a new worktree where the shell's git-hooks install and file tasks fail
- **THEN** the gate's checks run and its result reflects only the checks

#### Scenario: No tools on PATH
- **WHEN** the gate runs with only `nix`, `devenv`, `git` and a POSIX userland on `PATH`
- **THEN** every check runs

### Requirement: Pull requests and main run the gate
A workflow SHALL run the gate on every pull request and every push to main, as a job named `check` on Linux, with the repository token limited to `contents: read` and no secrets.

Tested by: the workflow's run on this change's PR.

#### Scenario: PR with a failing check
- **WHEN** a PR's head fails the gate
- **THEN** the PR shows the `check` job failed
