# Spec Delta

## MODIFIED Requirements

### Requirement: A session skips relinking it can't do
Inside a session, the shell SHALL link each generated file devenv links, except the settings link, one at a time, through the atomic relink. A file the sandbox refuses SHALL keep what it has and SHALL NOT stop the others being linked. The step SHALL never fail, so later tasks aren't skipped for a failed dependency. Outside a session it SHALL do nothing.

Tested by: `packages/session-relink-test.sh` at build; the `devenv.nix` task is untested.

#### Scenario: Stale settings in a session
- **WHEN** a session runs `devenv shell` after an update changed the settings
- **THEN** the old settings link stays in place untouched, no task fails because of it, and the tasks ordered after `devenv:files` still run

#### Scenario: A fresh worktree
- **WHEN** a session runs `devenv shell` in a worktree with no generated files
- **THEN** `.pre-commit-config.yaml` and every other generated link the sandbox allows are created, except `.claude/settings.json`, which is reported missing only where the session reads its Claude Code files from that worktree

#### Scenario: Relink the sandbox allows
- **WHEN** a session runs `devenv shell`, `.mcp.json` is a stale link, and the relink succeeds
- **THEN** `.mcp.json` is updated, and `devenv:files` and `devenv:files:cleanup` are still skipped

#### Scenario: Relink the sandbox refuses
- **WHEN** a session runs `devenv shell`, two generated links are stale, and the sandbox refuses the first
- **THEN** the first keeps its old target, the second is updated, and no task fails

#### Scenario: A real file in place of a link
- **WHEN** `.mcp.json` is a regular file rather than a link
- **THEN** the session leaves it as it is, and the notice lists it as not a link

### Requirement: Stale generated files are reported once
In a session, when a generated link (settings included) is missing, stale or not a link after linking, the shell SHALL print one notice listing quoted paths by kind, unknown too. It SHALL say to enter the shell once from a terminal, then restart every session in the checkout, this one included, with `devenv shell --refresh-eval-cache` as the fallback. It SHALL never fail and SHALL be silent outside a session or with current links.

Tested by: `packages/session-relink-test.sh`; the notice isn't.

#### Scenario: Stale settings notice
- **WHEN** a session's shell finds `.claude/settings.json` pointing at an old store path
- **THEN** stderr shows one `coldlogic:` notice that names `.claude/settings.json` as out of date, says to enter the shell once from a terminal, and mentions `devenv shell --refresh-eval-cache`

#### Scenario: Missing settings notice
- **WHEN** a session's shell finds no `.claude/settings.json`
- **THEN** the notice names `.claude/settings.json` as missing, not as out of date

#### Scenario: Restarting sessions
- **WHEN** the notice is printed
- **THEN** it says to restart every Claude Code session open in the checkout, this one included, after the terminal refresh and before any of them runs another command, since a running session can undo the refresh at its next tool call

#### Scenario: Something that isn't a link
- **WHEN** a session's shell finds a regular file or directory at `.mcp.json`
- **THEN** the notice lists `.mcp.json` as not a link, to be moved aside, apart from missing and out-of-date files

#### Scenario: A path with a space, or an unknown kind
- **WHEN** a reported path contains a space, or the relink prints a line of a kind the notice doesn't know
- **THEN** the path is shell-quoted so it reads as one path, and the unknown line is still listed, so the notice is printed

#### Scenario: The comparison itself fails
- **WHEN** a session's shell runs the comparison and it exits with an error rather than reporting, for example because a command it runs fails
- **THEN** stderr shows one `coldlogic:` notice that the generated files couldn't be checked, with the exit code, saying to enter the shell once from a terminal, and no task fails

#### Scenario: Current links
- **WHEN** every generated link is current
- **THEN** the shell prints nothing about them

### Requirement: A session never writes the settings link
Inside a session (the module's session test), the shell SHALL NOT create, replace, rename or remove the Claude Code settings link, and SHALL NOT create or remove any temporary link beside it. Only a shell entered outside a session SHALL refresh it. The session SHALL still compare it, so the notice can report it.

Tested by: none. The settings path is left out of the session's linking in `devenv.nix`.

#### Scenario: Stale settings link
- **WHEN** a session runs `devenv shell` and `.claude/settings.json` points at a store path other than the current one
- **THEN** `.claude/settings.json` points at the same store path afterwards, and nothing was written in `.claude/`

#### Scenario: Missing settings link
- **WHEN** a session runs `devenv shell` and `.claude/settings.json` doesn't exist
- **THEN** the session doesn't create it, even where the sandbox would allow it, and the notice reports it missing where the session reads its Claude Code files from that checkout

#### Scenario: Terminal refresh
- **WHEN** a developer runs `devenv shell` outside a session
- **THEN** `.claude/settings.json` points at the current store path

## ADDED Requirements

### Requirement: The notice leaves out files this session reads elsewhere
When a session reads its Claude Code files from another checkout (session-notices), the notice SHALL NOT list the settings link or `.mcp.json`, whatever state they are in, and SHALL NOT be printed for them alone. Every other generated link SHALL still be listed. Where the session's own checkout is this one, or can't be told, both SHALL be listed as before.

Tested by: `packages/session-shell-test.sh` for the decision; the `devenv.nix` task is untested.

#### Scenario: A subagent's fresh worktree
- **WHEN** a session started in the main checkout runs `devenv shell` in `<main checkout>.worktrees/agent-x`, where `.pre-commit-config.yaml` and `.mcp.json` get linked and `.claude/settings.json` doesn't exist
- **THEN** the shell prints nothing about generated files

#### Scenario: An EnterWorktree worktree
- **WHEN** a session started in the main checkout runs `devenv shell` in a worktree it entered, where the sandbox refuses `.mcp.json` and `.claude/settings.json` doesn't exist
- **THEN** the shell prints nothing about generated files, and creates neither

#### Scenario: A hooks configuration that can't be linked there
- **WHEN** such a session's shell can't link `.pre-commit-config.yaml` in the worktree
- **THEN** the notice lists `.pre-commit-config.yaml` as missing, and lists neither the settings link nor `.mcp.json`

#### Scenario: The session's own checkout
- **WHEN** a session started in the main checkout runs `devenv shell` there and `.claude/settings.json` is missing
- **THEN** the notice names `.claude/settings.json` as missing

### Requirement: The generated-files notice is printed once per session
The notice, and the notice that the files couldn't be checked, SHALL each follow the session-notices once-per-session rule. A shell that finds every listed link current SHALL clear the record, so the notice is printed again if a link goes stale later in that session.

Tested by: `packages/session-shell-test.sh` for the rule; the `devenv.nix` task is untested.

#### Scenario: The same stale link on a second shell
- **WHEN** a session's shell printed the notice for a stale `.claude/settings.json`, and the session enters the shell again with nothing changed
- **THEN** the second shell prints nothing about generated files

#### Scenario: Another file goes stale
- **WHEN** a session's shell printed the notice for one file, and its next shell finds a second file stale as well
- **THEN** the notice is printed again, listing both

#### Scenario: Fixed, then stale again
- **WHEN** a terminal shell refreshed the links, a session's shell found them current, and a later shell in that session finds one missing
- **THEN** the notice is printed again
