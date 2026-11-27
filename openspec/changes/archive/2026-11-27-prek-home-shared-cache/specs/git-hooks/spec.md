# Spec Delta

## ADDED Requirements

### Requirement: prek keeps its state in the user cache
The developer profile SHALL set `PREK_HOME` to `<home>/.cache/prek`, one path from every checkout and worktree, which the sandbox allows writing, not a path under a checkout's `.devenv`. A commit from a session's worktree SHALL run the pre-commit hook, bare or inside `devenv shell`.

Tested by: a Nix assertion beside the definition in `devenv.nix`, evaluated by the gate's shell builds; the worktree commit manually.

#### Scenario: The developer shell's PREK_HOME
- **WHEN** a developer or a session enters the developer shell in the main checkout or in any worktree
- **THEN** `PREK_HOME` is `<home>/.cache/prek` and that directory exists

#### Scenario: A commit from a session's worktree
- **WHEN** a session started from the main checkout's shell moves into `.claude/worktrees/<name>` with EnterWorktree and commits there, with a bare `git commit` or through `devenv shell --quiet -- git commit`
- **THEN** the pre-commit hook runs, writing its log and lock under `<home>/.cache/prek`, and nothing under the main checkout's `.devenv`
