## MODIFIED Requirements

### Requirement: A session skips relinking it can't do
Inside a session (`CLAUDECODE` set), when a protected link is missing or stale, the shell SHALL skip `devenv:files:cleanup` without relinking, and SHALL try the relink in `devenv:files`' status. If the sandbox refuses it, the shell SHALL skip `devenv:files` too. Neither task SHALL fail, so the links stay and later tasks run. Outside a session, both tasks SHALL run as usual.

Tested by: `packages/session-relink-test.sh`, run when `packages/session-relink.nix` builds.

#### Scenario: Stale settings in a session
- **WHEN** a session runs `devenv shell` after an update changed the settings and the sandbox denies writing them
- **THEN** the old links stay in place, and the git-hooks, plugin and enterShell tasks still run

#### Scenario: Relink the sandbox allows
- **WHEN** a session runs `devenv shell`, a link is stale, and the relink succeeds
- **THEN** `devenv:files:cleanup` is skipped, the link is updated, and `devenv:files` runs as usual

#### Scenario: A real file in place of a link
- **WHEN** `.mcp.json` is a regular file rather than a link
- **THEN** the session leaves it to `devenv:files` to report, and it neither skips `devenv:files:cleanup` nor appears in the stale notice

### Requirement: Stale generated files are reported once
Inside a session, when a protected link doesn't point at its current store path after `devenv:files`, the shell SHALL print one notice that lists the stale files, says to enter the shell once from a terminal, and names `devenv shell --refresh-eval-cache` if that doesn't help. The notice SHALL never fail, and SHALL stay silent outside a session or when the links are current.

Tested by: `packages/session-relink-test.sh` for the comparison (`--check-only --print`); the notice text is untested.

#### Scenario: Stale settings notice
- **WHEN** a session's shell leaves `.claude/settings.json` stale
- **THEN** stderr shows `coldlogic: the generated files are out of date, and this Claude Code session can't write them: .claude/settings.json. Enter the shell once from a terminal ...` and the notice mentions `devenv shell --refresh-eval-cache`

#### Scenario: Current links
- **WHEN** every protected link is current
- **THEN** the shell prints nothing about them

## ADDED Requirements

### Requirement: A session relink never leaves a protected path missing
The session's relink SHALL replace a protected link atomically, so the path is never missing, even when the sandbox allows removing the link but denies creating one. It SHALL leave no temporary link of its own behind. It SHALL remove a leftover temporary link only when the link's process has exited and the link is more than a minute old, whether or not the protected link is stale.

Tested by: `packages/session-relink-test.sh`, run when `packages/session-relink.nix` builds.

#### Scenario: Removal allowed, create denied
- **WHEN** a session runs `devenv shell`, `.claude/settings.json` points at another store path, and the sandbox would allow removing the link but denies creating or renaming one there
- **THEN** `.claude/settings.json` still points at its old store path afterwards, no temporary link is left beside it, and the file is reported stale

#### Scenario: A concurrent shell's temporary link
- **WHEN** a session relinks while another shell's `.settings.json.coldlogic-relink.<pid>` link exists and that process is still running
- **THEN** the other shell's temporary link is left in place, and only links whose process has exited are removed

#### Scenario: A leftover beside a current link
- **WHEN** `.claude/settings.json` is current and a `.settings.json.coldlogic-relink.<pid>` link from an exited process is more than a minute old
- **THEN** the session's `devenv shell` removes the leftover

### Requirement: Session cleanup keeps current protected links
Inside a session, the shell SHALL skip `devenv:files:cleanup`, without failing it, when the recorded state lists a protected file under another spelling (the entry read joined to the checkout and, if it starts with `/`, as absolute; paths normalised without resolving links), since cleanup would treat that entry as an orphan and remove the live link. Outside a session, cleanup SHALL run as usual.

Tested by: `packages/session-relink-test.sh`, run when `packages/session-relink.nix` builds.

#### Scenario: Settings recorded as a relative path
- **WHEN** a session runs `devenv shell`, the recorded state lists `.claude/settings.json`, and the current config names it by its absolute path
- **THEN** `devenv:files:cleanup` is skipped and `.claude/settings.json` still exists

#### Scenario: Settings recorded with a redundant path segment
- **WHEN** a session runs `devenv shell` and the recorded state lists `.claude//settings.json` or `x/../.claude/settings.json`
- **THEN** `devenv:files:cleanup` is skipped and `.claude/settings.json` still exists

#### Scenario: Settings recorded as an absolute path
- **WHEN** a session runs `devenv shell`, the recorded state lists the settings by its absolute path, and the current config names it `.claude/settings.json`
- **THEN** `devenv:files:cleanup` is skipped and `.claude/settings.json` still exists

#### Scenario: Recorded spelling matches
- **WHEN** a session runs `devenv shell`, every protected file is recorded under its current spelling, and every protected link is current
- **THEN** `devenv:files:cleanup` runs as usual

### Requirement: Session cleanup skips state it can't check
Inside a session, the shell SHALL skip `devenv:files:cleanup`, without failing it, when the recorded state exists but can't be read as a single list of file names, since the spelling check above can't be made.

Tested by: `packages/session-relink-test.sh`, run when `packages/session-relink.nix` builds.

#### Scenario: Unreadable state
- **WHEN** a session runs `devenv shell` and the recorded state is not valid JSON, or has no `managedFiles` list of strings
- **THEN** `devenv:files:cleanup` is skipped and `.claude/settings.json` still exists

#### Scenario: No state yet
- **WHEN** a session runs `devenv shell`, no state has been recorded, and every protected link is current
- **THEN** `devenv:files:cleanup` runs as usual

### Requirement: A session runs the file tasks only when the check says so
Inside a session, `devenv:files` and `devenv:files:cleanup` SHALL run only when their check explicitly reports that it is safe. If the check fails or errors in any other way, the task SHALL be skipped without failing. Outside a session, both tasks SHALL run.

Tested by: `packages/session-relink-test.sh` for the check's exit codes; the status wrappers in `devenv.nix` are untested.

#### Scenario: The check fails
- **WHEN** a session runs `devenv shell` and the check exits with an error, for example because a command it runs fails
- **THEN** `devenv:files` and `devenv:files:cleanup` are skipped and `.claude/settings.json` still exists
