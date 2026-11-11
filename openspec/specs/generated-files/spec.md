# generated-files Specification

## Purpose
How `devenv shell` treats the generated `.claude/settings.json` and `.mcp.json` inside a Claude Code session, whose sandbox can't rewrite them. A stale link mustn't break the shell or leave the session with no settings (#37).

## Requirements

### Requirement: Generated settings are store links, not tracked files
The module SHALL generate the Claude Code settings file and `.mcp.json` as links into the Nix store, built per checkout. Projects SHALL change them through `devenv.nix`, not by editing the files.

Tested by: none.

#### Scenario: Entering the shell from a terminal
- **WHEN** a developer runs `devenv shell` outside a Claude Code session after the module changed the settings
- **THEN** `.claude/settings.json` points at the new store path

### Requirement: A session skips relinking it can't do
Inside a Claude Code session (`CLAUDECODE` set), when a protected link is missing or stale, the shell SHALL try the relink itself. If the sandbox refuses it, the shell SHALL skip `devenv:files` and `devenv:files:cleanup` without failing them, so the existing links stay and later tasks still run. Outside a session, both tasks SHALL run as usual.

Tested by: none.

#### Scenario: Stale settings in a session
- **WHEN** a session runs `devenv shell` after an update changed the settings and the sandbox denies writing them
- **THEN** the old links stay in place, and the git-hooks, plugin and enterShell tasks still run

#### Scenario: Relink the sandbox allows
- **WHEN** a session runs `devenv shell`, a link is stale, and the relink succeeds
- **THEN** the link is updated and the file tasks run as usual

#### Scenario: A real file in place of a link
- **WHEN** `.mcp.json` is a regular file rather than a link
- **THEN** the session leaves it to `devenv:files` to report

### Requirement: Stale generated files are reported once
Inside a session, when any protected link doesn't point at its current store path after `devenv:files`, the shell SHALL print one notice listing the stale files and telling the developer to enter the shell once from a terminal. The notice task SHALL never fail and SHALL stay silent outside a session or when the links are current.

Tested by: none.

#### Scenario: Stale settings notice
- **WHEN** a session's shell leaves `.claude/settings.json` stale
- **THEN** stderr shows `coldlogic: the generated files are out of date, and this Claude Code session can't write them: .claude/settings.json. Enter the shell once from a terminal ...`

#### Scenario: Current links
- **WHEN** every protected link is current
- **THEN** the shell prints nothing about them
