# Spec Delta

## MODIFIED Requirements

### Requirement: A terminal shell prunes in the background
Entering the shell outside a Claude Code session (the shell's shared session test, in generated-files: neither `COLDLOGIC_DEVENV_SESSION` nor `CLAUDECODE` set) and outside CI (`CI` unset) SHALL start the command detached, without delaying the shell or failing it. Inside a session, the task SHALL do nothing.

Tested by: the terminal run in the change's tasks.

#### Scenario: Terminal shell
- **WHEN** Derek runs `devenv shell` from a terminal in a project with a merged, idle worktree
- **THEN** the shell starts as fast as before and the worktree is removed shortly after

#### Scenario: Shell inside a session
- **WHEN** a session runs `devenv shell --quiet -- true`
- **THEN** the task starts no prune

#### Scenario: A session marked only by the wrapper
- **WHEN** a shell runs with `COLDLOGIC_DEVENV_SESSION=1` and no `CLAUDECODE`
- **THEN** the task starts no prune
