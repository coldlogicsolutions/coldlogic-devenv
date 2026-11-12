# generated-files Specification

## Purpose
How the generated links (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml` and the rest) are kept current around a Claude Code session, whose sandbox can't safely rewrite them. A session never runs devenv's file tasks or writes the settings link; it relinks the rest atomically and reports what it can't fix. Outside a session, a terminal `devenv shell` refreshes them, and so does the `claude` wrapper before it starts one. A stale link mustn't break the shell or leave the session with no settings (#37, #94, #101).

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

### Requirement: A session never runs devenv's file tasks
Inside a session, the shell SHALL skip `devenv:files` and `devenv:files:cleanup` without failing them, whatever state the generated links are in. No check SHALL be able to let either task run there: `devenv:files` replaces a link by removing it first, and cleanup removes links. Outside a session, both tasks SHALL run.

Tested by: none. Each status in `devenv.nix` is the shared session test and nothing else.

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

#### Scenario: A session the wrapper didn't start
- **WHEN** a session started by the desktop app, with `CLAUDECODE` set and no `COLDLOGIC_DEVENV_SESSION`, runs `devenv shell`
- **THEN** `devenv:files` and `devenv:files:cleanup` are skipped

### Requirement: A session never writes the settings link
Inside a session (the module's session test), the shell SHALL NOT create, replace, rename or remove the Claude Code settings link, and SHALL NOT create or remove any temporary link beside it. Only a shell entered outside a session, or the `claude` wrapper before it starts a session, SHALL refresh it. The session SHALL still compare it, so the notice can report it.

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

#### Scenario: Wrapper refresh
- **WHEN** a developer runs `claude` from the devenv shell, outside a session, and `.claude/settings.json` is missing or points at an old store path
- **THEN** `.claude/settings.json` points at the current store path before Claude Code starts

#### Scenario: The wrapper run by a session
- **WHEN** a session's Bash tool runs `claude` and `.claude/settings.json` is missing or out of date
- **THEN** the link is left exactly as it was

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

### Requirement: One test decides whether the shell is in a session
The shell SHALL count as inside a session when `COLDLOGIC_DEVENV_SESSION`, the module's own marker, is set, or when `CLAUDECODE` is. Every step of the shell that depends on being in a session SHALL use that one test, defined once, and nothing else SHALL decide it. `CLAUDECODE` is the fallback for sessions the `claude` wrapper didn't start.

Tested by: none. `devenv.nix` defines the test once; the change's tasks search for any other.

#### Scenario: A session the wrapper started
- **WHEN** a shell runs with `COLDLOGIC_DEVENV_SESSION=1` and no `CLAUDECODE`
- **THEN** it is inside a session: the file tasks are skipped, the session's own linking runs, and no prune starts

#### Scenario: A session started another way
- **WHEN** a shell runs with `CLAUDECODE=1` and no `COLDLOGIC_DEVENV_SESSION`
- **THEN** it is inside a session all the same

#### Scenario: A terminal
- **WHEN** a shell runs with neither variable set
- **THEN** it is outside a session

### Requirement: The claude wrapper refreshes the generated files before a session starts
The developer shell SHALL put a `claude` command on `PATH` ahead of Claude Code. Outside a session, every invocation, whatever its arguments, SHALL first run devenv's file tasks at the top of the devenv project the current directory is in, as a terminal shell runs them, and only then start Claude Code. A `CLAUDECODE` set by an IDE terminal SHALL NOT stop it.

Tested by: `packages/claude-wrapper-test.sh` at build, with a stand-in `devenv`; the change's terminal runs.

#### Scenario: Out-of-date settings
- **WHEN** a developer runs `claude` in a checkout whose `.claude/settings.json` points at an old store path
- **THEN** the link points at the current store path when Claude Code starts

#### Scenario: Any arguments
- **WHEN** a developer runs `claude --version`, `claude -p hello` or `claude mcp list`
- **THEN** the refresh runs first each time

#### Scenario: A subdirectory
- **WHEN** a developer runs `claude` in `src/` of a checkout
- **THEN** the checkout's generated files are refreshed, and Claude Code starts in `src/`

#### Scenario: A sibling worktree
- **WHEN** a shell entered in the main checkout has changed directory into a worktree with its own `devenv.nix`, and the developer runs `claude`
- **THEN** the worktree's generated files are refreshed, not the main checkout's

#### Scenario: An IDE terminal
- **WHEN** a developer runs `claude` in an IDE extension's terminal, where `CLAUDECODE` is set and neither `COLDLOGIC_DEVENV_SESSION` nor `CLAUDE_CODE_CHILD_SESSION` is
- **THEN** devenv's file tasks run, and Claude Code starts with `CLAUDECODE` as the terminal set it

### Requirement: The wrapper leaves other directories alone
Where the git checkout the current directory is in has no `devenv.nix` or `devenv.yaml` at its top, or the directory is in no git checkout, the wrapper SHALL start Claude Code at once, with no refresh, no settings check and no message. It SHALL NOT fall back to the shell's own checkout.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: A checkout that isn't a devenv project
- **WHEN** a developer in a devenv shell runs `claude` in a git checkout with no `devenv.nix` or `devenv.yaml`
- **THEN** devenv isn't run, not even for the shell's own checkout, no settings are checked, nothing is printed, and Claude Code starts in that directory

#### Scenario: Outside any checkout
- **WHEN** a developer in a devenv shell runs `claude` from a directory in no git checkout
- **THEN** devenv isn't run, not even for the shell's own checkout, no settings are checked, nothing is printed, and Claude Code starts in that directory

### Requirement: The wrapper marks the session it starts
The wrapper SHALL start Claude Code with `COLDLOGIC_DEVENV_SESSION=1` in its environment, on every path that starts it, so everything that session runs inherits the marker. The devenv run that refreshes the files SHALL NOT have the marker, `CLAUDECODE`, or any `DEVENV_` variable of the shell the wrapper runs in, so devenv works out the checkout from its directory.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: A tool call in the session
- **WHEN** a session the wrapper started runs `devenv shell` from its Bash tool
- **THEN** that shell has `COLDLOGIC_DEVENV_SESSION=1` and is inside a session

#### Scenario: The refresh itself
- **WHEN** the wrapper runs devenv from an IDE terminal
- **THEN** devenv's environment has neither `COLDLOGIC_DEVENV_SESSION` nor `CLAUDECODE`

#### Scenario: A shell entered in another checkout
- **WHEN** a shell entered in the main checkout has changed directory into a worktree, and the developer runs `claude`
- **THEN** devenv's environment has none of that shell's `DEVENV_ROOT`, `DEVENV_DOTFILE`, `DEVENV_STATE`, `DEVENV_PROFILE` or other `DEVENV_` variables, and Claude Code gets them as the shell set them

### Requirement: The wrapper refreshes nothing inside a session
Where `COLDLOGIC_DEVENV_SESSION` is set, or `CLAUDE_CODE_CHILD_SESSION` is, the wrapper SHALL NOT run devenv or write any file, and SHALL start Claude Code at once with the same arguments. Nothing else SHALL decide it. `CLAUDE_CODE_CHILD_SESSION` is the fallback for a session the wrapper didn't start.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: A nested claude
- **WHEN** the Bash tool of a session the wrapper started runs `claude -p hello`
- **THEN** devenv isn't run, no generated link changes, and Claude Code gets `-p hello`

#### Scenario: A nested claude in a session started another way
- **WHEN** the Bash tool of a desktop-app session, with `CLAUDE_CODE_CHILD_SESSION` set and no marker, runs `claude -p hello` through the wrapper
- **THEN** devenv isn't run

#### Scenario: A hook
- **WHEN** a hook command runs `claude --version`
- **THEN** devenv isn't run

### Requirement: A failed refresh starts claude only with settings in place
When the refresh fails, the wrapper SHALL say so on stderr, with the checkout and the exit code. It SHALL then start Claude Code if the checkout's settings file (`claude.code.settingsPath`) resolves to a file, and otherwise exit 1 without starting it, naming the file and `COLDLOGIC_START_WITHOUT_SETTINGS`, unless that variable is set. A refresh that succeeds SHALL print nothing and SHALL be trusted.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: The refresh fails, settings in place
- **WHEN** devenv exits 3 and `.claude/settings.json` is a link to an existing file
- **THEN** stderr has one `coldlogic:` line saying the refresh failed with exit 3 and the settings may be out of date, and Claude Code starts

#### Scenario: The refresh fails, no settings
- **WHEN** devenv exits 3 and `.claude/settings.json` doesn't exist
- **THEN** Claude Code isn't started, the exit code is 1, and stderr names `.claude/settings.json` and `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude`

#### Scenario: A dangling link
- **WHEN** devenv fails and `.claude/settings.json` is a link whose target is gone
- **THEN** it counts as missing, and Claude Code isn't started

#### Scenario: The override
- **WHEN** devenv fails, `.claude/settings.json` doesn't exist and `COLDLOGIC_START_WITHOUT_SETTINGS=1` is set
- **THEN** stderr says the session starts without the module's settings, and Claude Code starts

#### Scenario: A settings path of the project's own
- **WHEN** the project sets `claude.code.settingsPath` to another file, devenv fails, and that file is missing though `.claude/settings.json` is there
- **THEN** Claude Code isn't started, and stderr names that file

#### Scenario: No devenv on PATH
- **WHEN** `devenv` can't be found
- **THEN** it counts as a failed refresh

#### Scenario: A refresh that works
- **WHEN** devenv exits 0
- **THEN** the wrapper prints nothing, and Claude Code starts

#### Scenario: A refresh that works, no settings
- **WHEN** devenv exits 0 and `.claude/settings.json` doesn't exist
- **THEN** Claude Code starts, and the wrapper prints nothing

### Requirement: The wrapper passes the launch through unchanged
The wrapper SHALL start Claude Code with the same arguments, each as given, in the same working directory, with the same standard input and output, and SHALL be replaced by it, so the exit code and signals are Claude Code's. The refresh SHALL NOT read standard input or write to standard output. The wrapper SHALL add nothing to `PATH`, and SHALL set only the session marker and its record of wrappers already run.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: Arguments with spaces and empty arguments
- **WHEN** a developer runs `claude -p 'a b' '' '*'`
- **THEN** Claude Code gets exactly those four arguments

#### Scenario: Piped input and captured output
- **WHEN** a script runs `echo question | claude -p >answer.txt`
- **THEN** Claude Code reads `question`, and `answer.txt` holds only what Claude Code wrote

#### Scenario: Exit code
- **WHEN** Claude Code exits 7
- **THEN** the command exits 7

### Requirement: The wrapper finds the real claude without running itself
The wrapper SHALL start the first executable `claude` on `PATH` that is neither itself, however often or through whatever link its directory is listed, nor a wrapper already run in this launch. With none, it SHALL exit 127 with a message and SHALL NOT run the refresh.

Tested by: `packages/claude-wrapper-test.sh` at build.

#### Scenario: Its directory is on PATH twice
- **WHEN** the wrapper's directory is listed twice before Claude Code's
- **THEN** Claude Code starts once, and the wrapper doesn't run itself

#### Scenario: Two shells' wrappers
- **WHEN** `PATH` lists one module version's wrapper, then another's, then Claude Code
- **THEN** each wrapper runs at most once and Claude Code starts

#### Scenario: No Claude Code
- **WHEN** the only `claude` on `PATH` is the wrapper
- **THEN** it exits 127, says no Claude Code was found, and devenv isn't run
