# Spec Delta

## Purpose

`scripts/adopt.sh` moves an existing project onto the module, or sets up a new one with it. It changes only the working tree and the index (untracking generated files), never commits, and lists what it couldn't do for the developer.

## ADDED Requirements

### Requirement: Adoption starts from a clean tree in the project's repository
The script SHALL refuse to run outside a git repository, and SHALL refuse a working tree with uncommitted changes unless `--allow-dirty` is passed.

Tested by: none.

#### Scenario: Uncommitted changes
- **WHEN** a developer runs `scripts/adopt.sh` with modified files
- **THEN** it exits non-zero and suggests committing, stashing or `--allow-dirty`

### Requirement: The profile is chosen from the project
Unless `--profile rust-lib|rust-worker|none` is given, the script SHALL choose `rust-worker` for a Cargo project with a wrangler config, `rust-lib` for any other Cargo project, and `none` otherwise.

Tested by: none.

#### Scenario: Cargo project with wrangler
- **WHEN** the project has `Cargo.toml` and a wrangler config and no `--profile`
- **THEN** `devenv.yaml` imports `coldlogic-devenv/profiles/rust-worker`

### Requirement: The project is wired to the module
The script SHALL add the `nixpkgs`, `git-hooks`, `rust-overlay` and `coldlogic-devenv` inputs, the imports and `profile: developer` to `devenv.yaml`, leaving existing inputs alone. It SHALL create an empty `devenv.nix` if missing. It SHALL copy the update workflow and add a direnv `.envrc` unless `--no-workflow` or `--no-envrc` is passed.

Tested by: none.

#### Scenario: Existing nixpkgs input
- **WHEN** the project's `devenv.yaml` already declares `nixpkgs`
- **THEN** the script leaves that declaration as it was

### Requirement: New inputs are locked when needed
Unless `--no-update` is passed, the script SHALL run `devenv update` when `devenv.lock` is missing or lacks a declared input, and SHALL otherwise leave the lock alone. When devenv isn't installed it SHALL list locking among the remaining steps.

Tested by: none.

#### Scenario: Lock already covers every input
- **WHEN** the project's `devenv.lock` locks every input `devenv.yaml` declares and the script adds none
- **THEN** the script doesn't run `devenv update`

### Requirement: Generated files are ignored and untracked
The script SHALL add the generated files (`.devenv*`, `devenv.local.*`, `.claude/settings.json`, `.claude/worktrees/`, `.mcp.json`, `.pre-commit-config.yaml`, OpenSpec's Claude Code skills and commands) to `.gitignore`. It SHALL untrack a committed `.claude/settings.json`, `.mcp.json` or `.pre-commit-config.yaml`, moving it to `.devenv/adopt-backup/` so it can be ported.

Tested by: none.

#### Scenario: Tracked settings
- **WHEN** the project tracks `.claude/settings.json`
- **THEN** the script untracks it, keeps a copy in `.devenv/adopt-backup/`, and lists porting its rules among the remaining steps

### Requirement: Committed OpenSpec skills are untracked where the shell regenerates them
In a project with `openspec/config.yaml`, the script SHALL untrack committed OpenSpec skills and commands, leaving the working copies for the shell to regenerate. Elsewhere it SHALL leave them tracked.

Tested by: none.

#### Scenario: Project without OpenSpec
- **WHEN** the project tracks `.claude/commands/opsx/explore.md` and has no `openspec/config.yaml`
- **THEN** the script leaves the file tracked

### Requirement: Adoption is idempotent
Running the script again on an adopted project whose adoption is committed SHALL change nothing.

Tested by: none.

#### Scenario: Second run
- **WHEN** a developer commits the first run's changes and runs `scripts/adopt.sh --no-update` again
- **THEN** `git status` shows no new changes
