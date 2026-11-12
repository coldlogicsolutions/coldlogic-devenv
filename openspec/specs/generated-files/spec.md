# generated-files Specification

## Purpose
How `devenv shell` treats the generated links (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml` and the rest) inside a Claude Code session, whose sandbox can't safely rewrite them. A session never runs devenv's file tasks or writes the settings link; it relinks the rest atomically and reports what it can't fix. A stale link mustn't break the shell or leave the session with no settings (#37, #94).

## Requirements

### Requirement: Generated settings are store links, not tracked files
The module SHALL generate the Claude Code settings file and `.mcp.json` as links into the Nix store, built per checkout. Projects SHALL change them through `devenv.nix`, not by editing the files.

Tested by: none.

#### Scenario: Entering the shell from a terminal
- **WHEN** a developer runs `devenv shell` outside a Claude Code session after the module changed the settings
- **THEN** `.claude/settings.json` points at the new store path

### Requirement: A session skips relinking it can't do
Inside a session, the shell SHALL link each generated file devenv links, except the settings link, one at a time, through the atomic relink. A file the sandbox refuses SHALL keep what it has and SHALL NOT stop the others being linked. The step SHALL never fail, so later tasks aren't skipped for a failed dependency. Outside a session it SHALL do nothing.

Tested by: `packages/session-relink-test.sh` at build; the `devenv.nix` task is untested.

#### Scenario: Stale settings in a session
- **WHEN** a session runs `devenv shell` after an update changed the settings
- **THEN** the old settings link stays in place untouched, no task fails because of it, and the tasks ordered after `devenv:files` still run

#### Scenario: A fresh worktree
- **WHEN** a session runs `devenv shell` in a worktree with no generated files
- **THEN** `.pre-commit-config.yaml` and every other generated link the sandbox allows are created, except `.claude/settings.json`, which is reported missing

#### Scenario: Relink the sandbox allows
- **WHEN** a session runs `devenv shell`, `.mcp.json` is a stale link, and the relink succeeds
- **THEN** `.mcp.json` is updated, and `devenv:files` and `devenv:files:cleanup` are still skipped

#### Scenario: Relink the sandbox refuses
- **WHEN** a session runs `devenv shell`, two generated links are stale, and the sandbox refuses the first
- **THEN** the first keeps its old target, the second is updated, and no task fails

#### Scenario: A real file in place of a link
- **WHEN** `.mcp.json` is a regular file rather than a link
- **THEN** the session leaves it as it is, and the notice lists it as not a link

### Requirement: A session relink never leaves a protected path missing
The session's relink SHALL replace a generated link atomically, so the path is never missing, even when the sandbox allows removing the link but denies creating one. It SHALL leave no temporary link of its own behind. It SHALL remove a leftover temporary link only when its process has exited and it is over a minute old, whether or not the generated link is stale. None of this SHALL apply to the settings link, which a session never writes.

Tested by: `packages/session-relink-test.sh` at build.

#### Scenario: Removal allowed, create denied
- **WHEN** a session runs `devenv shell`, a generated link other than the settings link points at another store path, and the sandbox would allow removing the link but denies creating or renaming one there
- **THEN** the link still points at its old store path afterwards, no temporary link is left beside it, and the file is reported stale

#### Scenario: A concurrent shell's temporary link
- **WHEN** a session relinks `.mcp.json` while another shell's `..mcp.json.coldlogic-relink.<pid>` link exists and that process is still running
- **THEN** the other shell's temporary link is left in place, and only links whose process has exited are removed

#### Scenario: A leftover beside a current link
- **WHEN** `.mcp.json` is current and a `..mcp.json.coldlogic-relink.<pid>` link from an exited process is more than a minute old
- **THEN** the session's `devenv shell` removes the leftover

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
- **THEN** it says to restart every Claude Code session open in the checkout, this one included, after the terminal refresh, since a running session can undo it

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

### Requirement: A session never runs devenv's file tasks
Inside a session, the shell SHALL skip `devenv:files` and `devenv:files:cleanup` without failing them, whatever state the generated links are in. No check SHALL be able to let either task run there: `devenv:files` replaces a link by removing it first, and cleanup removes links. Outside a session, both tasks SHALL run.

Tested by: none. Each status in `devenv.nix` is a single test of `CLAUDECODE`.

#### Scenario: The check fails
- **WHEN** a session runs `devenv shell` and the session's own linking exits with an error, for example because a command it runs fails
- **THEN** `devenv:files` and `devenv:files:cleanup` are skipped all the same, and `.claude/settings.json` still exists

#### Scenario: Links are current
- **WHEN** a session runs `devenv shell` and every generated link is current
- **THEN** `devenv:files` and `devenv:files:cleanup` are skipped, and no link is changed

#### Scenario: Another evaluation's link
- **WHEN** a session runs `devenv shell` and `.claude/settings.json` points at a store path other than the one the session's evaluation expects
- **THEN** `devenv:files` and `devenv:files:cleanup` are skipped and `.claude/settings.json` still exists

#### Scenario: An orphan in the recorded state
- **WHEN** a session runs `devenv shell` and devenv's recorded state lists a link this evaluation no longer generates
- **THEN** `devenv:files:cleanup` is skipped, the link is left, and the next terminal shell's cleanup removes it

#### Scenario: Outside a session
- **WHEN** a developer runs `devenv shell` from a terminal
- **THEN** `devenv:files:cleanup` and `devenv:files` both run

### Requirement: A session never writes the settings link
Inside a session (`CLAUDECODE` set), the shell SHALL NOT create, replace, rename or remove the Claude Code settings link, and SHALL NOT create or remove any temporary link beside it. Only a shell entered outside a session SHALL refresh it. The session SHALL still compare it, so the notice can report it.

Tested by: none. The settings path is left out of the session's linking in `devenv.nix`.

#### Scenario: Stale settings link
- **WHEN** a session runs `devenv shell` and `.claude/settings.json` points at a store path other than the current one
- **THEN** `.claude/settings.json` points at the same store path afterwards, and nothing was written in `.claude/`

#### Scenario: Missing settings link
- **WHEN** a session runs `devenv shell` and `.claude/settings.json` doesn't exist
- **THEN** the session doesn't create it, even where the sandbox would allow it, and the notice reports it missing

#### Scenario: Terminal refresh
- **WHEN** a developer runs `devenv shell` outside a session
- **THEN** `.claude/settings.json` points at the current store path
