# Spec Delta

## MODIFIED Requirements

### Requirement: Generation never fails the shell
When `openspec init` fails, as it does inside a sandboxed session, the shell SHALL warn and continue. The warning SHALL say the skills may be out of date if both a skill and a command exist, or otherwise that they couldn't be generated, and tell the developer to enter the shell from a terminal. Inside a session the warning SHALL follow the session-notices once-per-session rule.

Tested by: `packages/session-shell-test.sh` for the once-per-session rule; the `devenv.nix` task is untested.

#### Scenario: First shell inside a session
- **WHEN** a session enters the shell in the checkout it started in, in a project with OpenSpec and no generated skills
- **THEN** stderr shows `coldlogic: couldn't generate OpenSpec's Claude Code skills; enter the shell from a terminal, outside a Claude Code session`, and the shell starts

#### Scenario: Later shells in that session
- **WHEN** the same session enters the shell there again and generation fails the same way
- **THEN** the shell prints nothing about the skills, and starts

#### Scenario: A terminal shell
- **WHEN** generation fails in a shell entered from a terminal
- **THEN** the warning is printed on that shell and on every later one that fails

## ADDED Requirements

### Requirement: A session generates skills only where it reads them
Inside a session that reads its Claude Code files from another checkout (session-notices), the shell SHALL NOT run `openspec init` and SHALL print nothing about the skills: that session's skills and commands come from the checkout it started in. Where the session's own checkout is this one, or can't be told, and outside a session, generation SHALL run as before.

Tested by: `packages/session-shell-test.sh` for the decision; the `devenv.nix` task is untested.

#### Scenario: A worktree the session entered
- **WHEN** a session started in the main checkout enters the shell in an EnterWorktree worktree or a subagent's worktree that has no generated skills
- **THEN** the shell doesn't run `openspec init`, creates nothing under `.claude/`, and prints nothing about the skills

#### Scenario: The checkout the session started in
- **WHEN** a session enters the shell in the checkout it started in and the stamp doesn't match
- **THEN** the shell runs `openspec init` as before

#### Scenario: A terminal shell in a worktree
- **WHEN** a developer enters the shell from a terminal in a worktree
- **THEN** the skills are generated there as before
