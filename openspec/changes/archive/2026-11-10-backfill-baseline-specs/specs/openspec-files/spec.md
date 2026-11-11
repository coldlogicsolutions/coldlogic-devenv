# Spec Delta

## Purpose

Every developer shell provides `openspec`, and generates OpenSpec's Claude Code skills and commands from it rather than tracking them, because a session's sandbox can't write `.claude/skills` or `.claude/commands` and tracked copies broke git (#32).

## ADDED Requirements

### Requirement: The developer shell provides openspec
The developer profile SHALL put the module's `openspec` on the PATH and allow `openspec *` without a prompt.

Tested by: none.

#### Scenario: Validating specs in a session
- **WHEN** a session runs `openspec validate --strict`
- **THEN** it runs the module's `openspec` with no permission prompt

### Requirement: Skills are generated only where the project opts in
The shell SHALL generate OpenSpec's Claude Code skills and commands only when `openspec/config.yaml` exists and git ignores both `.claude/skills/openspec-explore/SKILL.md` and `.claude/commands/opsx/explore.md`. Otherwise it SHALL change nothing, so a project that still tracks them keeps its tree unchanged. It SHALL leave other tools' files to the project.

Tested by: none.

#### Scenario: No OpenSpec in the project
- **WHEN** a project has no `openspec/config.yaml`
- **THEN** the shell generates nothing

#### Scenario: Project still tracks the skills
- **WHEN** `.claude/skills/openspec-explore/SKILL.md` is tracked rather than ignored
- **THEN** the shell leaves `.claude/` untouched

### Requirement: Generation runs only when openspec changes or files are missing
The shell SHALL run `openspec init --tools claude` non-interactively and with telemetry off, and record the `openspec` store path in `$DEVENV_STATE/coldlogic-openspec`. It SHALL skip generation while that stamp matches and at least one OpenSpec skill and one `opsx` command exist.

Tested by: none.

#### Scenario: Unchanged openspec
- **WHEN** the stamp matches the module's `openspec` and the skills are present
- **THEN** the shell doesn't run `openspec init`

#### Scenario: openspec upgraded
- **WHEN** a module update changes the `openspec` store path
- **THEN** the next shell regenerates the skills and commands

### Requirement: Generation never fails the shell
When `openspec init` fails, as it does inside a sandboxed session, the shell SHALL warn and continue. The warning SHALL say the skills may be out of date if both a skill and a command exist, or otherwise that they couldn't be generated, and tell the developer to enter the shell from a terminal.

Tested by: none.

#### Scenario: First shell inside a session
- **WHEN** a session enters the shell in a project with OpenSpec and no generated skills
- **THEN** stderr shows `coldlogic: couldn't generate OpenSpec's Claude Code skills; enter the shell from a terminal, outside a Claude Code session`, and the shell starts
