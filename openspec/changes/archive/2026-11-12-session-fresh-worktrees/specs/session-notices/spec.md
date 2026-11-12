# Spec Delta

## Purpose

When a `devenv shell` inside a Claude Code session prints a notice. A session enters the shell for every command it runs, so a notice printed on each shell, or about files that session doesn't use, buries the ones that matter.

## ADDED Requirements

### Requirement: A session prints each distinct notice once
Inside a Claude Code session, the shell SHALL print a notice only when that session hasn't yet been shown the same text for the same kind of notice in that checkout. It SHALL print it again when the text changes, in another session, or after the condition cleared and came back. Where the session can't be identified, it SHALL print once per text. Outside a session every notice SHALL print on every shell.

Tested by: `packages/session-shell-test.sh` at build.

#### Scenario: A second shell in the same session
- **WHEN** a session's shell printed a notice, and the same session enters the shell again in that checkout with the same condition
- **THEN** the second shell prints nothing for it

#### Scenario: Another session
- **WHEN** a session's shell printed a notice, and a session with a different `CLAUDE_CODE_SESSION_ID` enters the shell in that checkout with the same condition
- **THEN** the notice is printed once for that session too

#### Scenario: The text changes
- **WHEN** a session's shell printed a notice listing one file, and its next shell would list two
- **THEN** the new text is printed

#### Scenario: Cleared, then back
- **WHEN** a notice was printed, a later shell in the same session found nothing to report, and a shell after that finds the same condition again
- **THEN** the notice is printed again

#### Scenario: No session id
- **WHEN** the shell runs in a session (the module's session test) and `CLAUDE_CODE_SESSION_ID` isn't set
- **THEN** a notice is printed once for each distinct text, until its condition clears

#### Scenario: Outside a session
- **WHEN** a developer enters the shell from a terminal twice with the same condition
- **THEN** the notice is printed both times, and nothing is recorded

#### Scenario: Another checkout
- **WHEN** a session saw a notice in one worktree and enters the shell in another with the same condition
- **THEN** the notice is printed there once as well

### Requirement: A notice is never lost to its own bookkeeping
When the record of what a session was shown can't be read or written, holds anything but an exact match, or the helper that keeps it fails, the shell SHALL print the notice. The bookkeeping SHALL never fail the shell.

Tested by: `packages/session-shell-test.sh` at build; the fallback `echo` at each call in `devenv.nix` is untested.

#### Scenario: The record can't be written
- **WHEN** a session's shell has a notice and its state directory can't be written
- **THEN** the notice is printed on that shell and on each later one, and no task fails

#### Scenario: A damaged record
- **WHEN** the record for a notice is empty or holds part of an earlier text
- **THEN** the notice is printed, and the record is rewritten

### Requirement: A session's own checkout is the one its settings name
Inside a session, the shell SHALL count a checkout as the session's own when `COLDLOGIC_SESSION_ROOT` names it, or when that can't be told: the variable unset, a path unresolvable, or the check failing. Only when the variable names a different checkout SHALL the shell treat the session-only files (the settings link, `.mcp.json`, OpenSpec's skills and commands) as not that session's concern there.

Tested by: `packages/session-shell-test.sh` at build.

#### Scenario: A worktree the session entered
- **WHEN** a session started in the main checkout enters the shell in a worktree made with EnterWorktree or for a subagent with `isolation: worktree`
- **THEN** the shell treats that worktree's settings link, `.mcp.json` and OpenSpec skills as not this session's concern

#### Scenario: The checkout the session started in
- **WHEN** a session enters the shell in the checkout `COLDLOGIC_SESSION_ROOT` names, through any spelling of its path
- **THEN** the shell treats those files as the session's own, and reports them

#### Scenario: A session started in a linked worktree
- **WHEN** a session started in a linked worktree whose settings were generated there enters the shell in that worktree
- **THEN** the shell treats those files as the session's own

#### Scenario: A session without the variable
- **WHEN** a session whose settings predate this variable, or that started with no settings, enters the shell anywhere
- **THEN** the shell treats those files as the session's own, and reports them as before
