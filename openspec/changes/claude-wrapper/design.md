# Design

## Context

See proposal.md for the motivation. The driver is #100's finding: a running session unlinks a settings link created after it started (`fs_usage`: `unlink … claude.<pid>`). Claude Code's documentation says it hot-reloads settings files and "also loads a settings file you create mid-session if its folder existed", which is not what #100 saw. So the plan doesn't rely on a session picking up a link made later: the link must be current before the session starts.

Derek's decisions, taken as given: the wrapper lives in devenv, not a plugin SessionStart hook; the refresh is `devenv --quiet tasks run devenv:files`; on failure it starts with the link present and refuses without it, with an env override; the wrapper's session test is `CLAUDE_CODE_CHILD_SESSION`; every invocation refreshes; the spec home is `generated-files`.

**Checked, in this worktree (devenv 2.4.0, Claude Code 2.1.322, in a session):**

- `devenv tasks list`: `devenv:files` depends on `coldlogic:session-files`, which depends on `devenv:files:cleanup`. `devenv tasks run devenv:files` (default mode `before`) ran exactly those three, in that order, applied the statuses (both file tasks `(cached)`, since this is a session), and didn't run `enterShell` or any other task.
- That command printed a JSON line on standard output (`{"devenv:files":{…}}`), without `--quiet`. Whether `--quiet` drops it wasn't checked, so the wrapper discards the refresh's standard output.
- `devenv tasks run --help`: `--mode` defaults to `before`; `-q, --quiet` is a global option.
- A session's Bash tool has both `CLAUDECODE=1` and `CLAUDE_CODE_CHILD_SESSION=1`.
- Claude Code's environment variable reference: `CLAUDECODE` is set for the Bash and PowerShell tools, tmux sessions, hooks, status line commands and stdio MCP servers, and by IDE extensions in their terminals. `CLAUDE_CODE_CHILD_SESSION` is set for the Bash, PowerShell and Monitor tools, hooks and status line commands, not for stdio MCP servers and not by IDE extensions, and needs Claude Code 2.1.172 or later.
- The session's `PATH` lists the developer profile's package directories (`git`, `openspec`, `gh-app`, `coldlogic-prune-worktrees`) before `/opt/homebrew/bin`, where the real `claude` is. So a `claude` in `packages` (devenv.nix:173-180) comes first.
- With `DEVENV_ROOT` inherited as the main checkout, `devenv shell` run in this worktree worked on the worktree (its notice named the worktree's settings path). So `devenv shell` picks its project from the current directory.
- `devenv.nix`: the five session tests are `skipInSession` (76-78, used by the two statuses at 516-517), `coldlogic:session-files` (526), `coldlogic:generated-files-stale` (544) and `coldlogic:prune-worktrees` (654). All test `CLAUDECODE`, at run time. Evaluation reads only `HOME`, `GNUPGHOME` and `COLDLOGIC_GPG_AGENT_SOCKET`.
- The module's only MCP server is `mcp.devenv.sh`, of type `http` (`.mcp.json`, `enabledMcpjsonServers`). Neither profile nor any fixture adds one.
- `packages/session-relink.nix` and `packages/prune-worktrees.nix`: `pkgs.runCommand` runs `<name>-test.sh` against the raw script, and the application's text refers to it, so the build needs the tests to pass. `scripts/check.sh` shellchecks every `*.sh` (91) and builds the shell and the fixtures' shells (107-116), on Linux in CI.
- The parallel change's proposal and `generated-files` delta, in `coldlogic-devenv.worktrees/session-fresh-worktrees`.

**Assumed, not checked:**

- That the task processes of `devenv tasks run` see the caller's environment, so clearing `CLAUDECODE` in the wrapper's subshell makes the statuses run the tasks. A session's `CLAUDECODE` does reach them (the tasks were skipped), which supports it. Not run from here: it would run devenv's link step inside the sandbox, the thing #68 forbids.
- That `devenv tasks run`, like `devenv shell`, picks its project from the current directory and writes that project's state, with `DEVENV_ROOT` and `DEVENV_STATE` inherited from another checkout's shell.
- That direnv's `PATH` has the same order as `devenv shell`'s. This session's `PATH` came through direnv and has it; a fresh terminal wasn't tried.
- What the refresh costs from a terminal, warm and cold.
- That no plugin's or project's stdio MCP server starts a devenv shell.
- Whether Claude Code starts agent-team teammates, or the IDE extension its sessions, through `claude` on `PATH`.
- That no project moves `claude.code.settingsPath`. Claude Code reads only `.claude/settings.json`, so another path would be no use.

## Goals / Non-Goals

**Goals:**

- A session started with `claude` from the devenv shell starts with current generated files, with no manual step.
- A wrapper run by a session changes nothing.
- The wrapper is invisible to the launch: arguments, directory, standard streams, exit code, signals and `PATH` are Claude Code's own.
- A session doesn't start with no settings at all without the developer being told and choosing it.

**Non-Goals:**

- Sessions not started through `PATH` in the devenv shell: the IDE extension's own launch, the desktop app, a `claude` run by absolute path.
- Fixing a session that is already running. The notice still covers that.
- The rest of `devenv shell`: OpenSpec's skills, the plugin install, the hooks path, the prune. They don't decide whether a session has its guard, and they'd make every launch slower.
- Treating an IDE terminal's plain `devenv shell` as a terminal shell (see decision 2).

## Decisions

### 1. The wrapper's session test is `CLAUDE_CODE_CHILD_SESSION`, alone

Derek's decision. `[ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]` means a session started this process, where the sandbox applies and the settings link must not be written. Then the wrapper runs no devenv and starts the real `claude`. `CLAUDECODE` can't be the test: IDE extensions set it in their terminals, where no session is involved and the developer is about to start one.

### 2. The file tasks keep testing `CLAUDECODE`; the wrapper clears it for its own devenv run

The wrapper runs devenv in a subshell that first does `unset CLAUDECODE`. So in an IDE terminal the two statuses run the tasks, and `coldlogic:session-files` does nothing. The real `claude` is started from the wrapper's own environment, where `CLAUDECODE` is as it was.

Per task:

| Test | Decision | Why |
| --- | --- | --- |
| `skipInSession`: the statuses of `devenv:files` and `devenv:files:cleanup` (76-78, 516-517) | Stays `CLAUDECODE` | It is the guard against #68 and #94, and the spec wants one test that can't be argued with. `CLAUDECODE` is the wider variable: every process `CLAUDE_CODE_CHILD_SESSION` marks has it too. So it fails closed. |
| `coldlogic:session-files` (526) | Stays `CLAUDECODE` | It must be the exact complement of the statuses, or a shell would run both linkings or neither. |
| `coldlogic:generated-files-stale` (544) | Stays `CLAUDECODE` | Not on the wrapper's path (it is ordered after `devenv:files`). The parallel change rewrites this task. |
| `coldlogic:prune-worktrees` (654) | Stays `CLAUDECODE` | Not on the wrapper's path. Changing it is a `worktree-cleanup` spec change with nothing to do with #101. |

*Rejected: switch the statuses and `coldlogic:session-files` to `CLAUDE_CODE_CHILD_SESSION`.* This is what the decision's wording leaned to, and it has one real gain: a plain `devenv shell` or direnv load in an IDE terminal would refresh the files too. Against it:

- It makes the guard fail open. With a Claude Code older than 2.1.172, or one that stops setting the variable, every `devenv shell` a session runs would run `devenv:files` inside the sandbox: #68 again, the settings deleted. With `CLAUDECODE` kept, the same fault only reaches a `claude` that a session starts through the wrapper, which is rare, and the refusal rule then reports the damage.
- Stdio MCP servers have `CLAUDECODE` but not `CLAUDE_CODE_CHILD_SESSION`. One started as `devenv shell -- <server>` would run devenv's file tasks under the session that started it, at startup and at each reconnect. It isn't sandboxed, so the link step would work, but it would replace or create the settings link under a running session, which is #94's and #100's ground. None of the module's servers does this (checked); a project's or a plugin's might (not checked). Keeping `CLAUDECODE` makes the question moot.
- An IDE terminal isn't sandboxed as far as we know, so the switch would be safe there. That is the gain, not a risk.
- The spec's "Each status in `devenv.nix` is a single test of `CLAUDECODE`" would have to change, in the requirement the last two changes fought for.
- It edits tasks the parallel change is editing, and its new session tests (`packages/session-shell.sh`) would have to switch with it.

*Rejected: switch all five.* The same, plus a `worktree-cleanup` delta, for two tasks the wrapper never runs.

*Rejected: a new variable the wrapper sets and the statuses also read ("refresh even though `CLAUDECODE` is set").* A second input to the statuses is exactly what "nothing else may decide it" rules out, and any process could set it.

The cost of this decision: a plain `devenv shell` in an IDE terminal still counts as a session, as today. It doesn't refresh, and its notice says to use a terminal. The wrapper covers the case that matters there, starting `claude`. It is listed under Open Questions.

### 3. The refresh is devenv's own file tasks, at the checkout's top

`devenv --quiet tasks run devenv:files`, Derek's decision, in a subshell: `cd` to the checkout, `unset CLAUDECODE`, standard input from `/dev/null`, standard output to `/dev/null`, stderr left alone. The wrapper's own directory never changes.

- Standard input: the wrapper's may be a prompt piped to `claude -p`. devenv must not be able to read it.
- Standard output: `claude -p` output is often captured, and devenv printed JSON there (checked).
- Stderr: with `--quiet` devenv says nothing unless it fails, and then its error is what the developer needs.

The checkout is `git rev-parse --show-toplevel` when that directory has a `devenv.nix` or `devenv.yaml`; else `$DEVENV_ROOT` when it is a directory; else none. Not `$DEVENV_ROOT` first: a shell entered in the main checkout and moved into a worktree still has the main checkout's `DEVENV_ROOT` (this session does), and `claude` there reads the worktree's settings. With no checkout, the wrapper says on stderr that it refreshed nothing and starts `claude`: there are no generated settings to be without. It can hardly happen, since the wrapper is only on `PATH` in a devenv shell, which sets `DEVENV_ROOT`.

*Rejected: `devenv shell --quiet -- true`.* It runs every task: the freshness check's network call, the OpenSpec generation, the plugin install, the hook install. Slower, and none of it decides whether the session has its settings.

*Rejected: link the settings directly with `coldlogic-session-relink` and the store path of the shell's evaluation.* Fast, with no evaluation. But the wrapper is built by one evaluation and used in any checkout, the store path it would link is the one from when the shell was entered, not the current one, and it would be a second thing that writes the link besides devenv.

*Rejected: refresh only when something looks stale.* Deciding that needs the evaluation, which is the cost.

*Rejected: a timeout on the refresh.* A cold build legitimately takes minutes, and a timeout needs a tool on `PATH` or by store path. Ctrl-C stops the wrapper and devenv together.

### 4. When the refresh fails

Derek's decision, made exact:

- The settings are "there" when `<checkout>/.claude/settings.json` resolves to a file (`[ -e ]`). A link whose store path is gone counts as missing: Claude Code would read nothing through it. A regular file, as in a project not yet adopted, counts as there.
- There: one `coldlogic:` line on stderr (the checkout, the exit code, "may be out of date", and `devenv shell` to see why), then start.
- Missing: one line naming the file, what the session would lack, and `COLDLOGIC_CLAUDE_START_ANYWAY=1 claude`; exit 1. With the variable set to anything non-empty: one line, then start.
- `devenv` missing from `PATH` is a failed refresh (the subshell exits 127), not a special case.
- A refresh that succeeds is trusted: no message, no look at the link.

*Rejected: check the link after a successful refresh too.* A project that turns `claude.code` off would never be able to start `claude`, and a devenv that reports success without linking is devenv's bug to surface, not ours to guess at.

*Rejected: always start, only warning.* A session with no guard, sandbox settings or permissions is the failure #101 exists for. Starting it should be a choice.

*Rejected: always refuse on failure.* A broken `devenv.nix` mid-edit would lock the developer out of the tool they'd use to fix it, while the old settings are still in place and still protect.

### 5. Finding the real `claude`

Walk `PATH` in order. Skip an entry whose `claude` isn't an executable file, is the same file as the wrapper (`-ef`, which follows links, so it covers a directory listed twice and a profile link), or is the same file as any path in `COLDLOGIC_CLAUDE_WRAPPERS`. Start the first one left, with the wrapper's own absolute path added to that variable. None left: exit 127, before any refresh.

The variable is the recursion marker, and it has to be a list. Skipping only itself isn't enough: with two module versions' wrappers on `PATH` (a `devenv shell` inside a direnv shell of another checkout, or of a worktree on another lock), A skips A and starts B, and B, searching from the front, skips B and starts A, forever. With the list each start adds one path, so a chain ends.

A session inherits the variable. That is harmless: it only names wrappers, which a nested wrapper must skip anyway, and it never affects whether to refresh. In the two-wrapper case both refresh the same checkout, once each; the second finds nothing to do.

*Rejected: a marker that makes a second wrapper give up or skip.* The session inherits it, so every `claude` a session starts would be refused, or would have to guess.

*Rejected: recognise a wrapper by its store path's name.* It works only for names this version knows, and the tests run the script outside the store.

*Rejected: bake the real path in at build time.* Claude Code isn't from nix here (`/opt/homebrew/bin/claude`), and differs per machine.

### 6. Packaging

`packages/claude-wrapper.sh` is the raw script, `packages/claude-wrapper-test.sh` its cases, `packages/claude-wrapper.nix` the package, following `session-relink.nix`.

- `pkgs.writeShellApplication` named `coldlogic-claude-wrapper`, with `runtimeInputs = [ ]`, and a `runCommand` whose only content is `bin/claude`, a link to it. So the store path says what it is, and `claude` is the one name it puts on `PATH`.
- No `runtimeInputs`: `writeShellApplication` exports them onto `PATH`, and the session inherits the wrapper's environment. The nix text sets `git_bin` to git's store path before the script's body; the raw script falls back to `git` on `PATH`, which is how the tests stub it. Everything else is bash builtins.
- `devenv` comes from `PATH`: it must be the developer's own, the one that made the shell. nixpkgs' would be another version with another evaluation cache.
- The script ends in `exec`, so no wrapper process stays between the terminal and Claude Code.

*Rejected: a devenv `scripts.claude` entry.* devenv's scripts are wrapped by devenv, the body would live inline in `devenv.nix` with no build-time tests, and the other three tools are packages.

*Rejected: a shell alias or function from `enterShell`.* It wouldn't exist under direnv, which exports only the environment.

### 7. No change to the stale notice

The notice (devenv.nix:584) could now say that restarting `claude` from the devenv shell is enough. It keeps its text: what it says stays true, and the parallel change is rewriting that task and that requirement. Whichever change lands second can shorten the advice.

## Overlap with `session-fresh-worktrees`

That change (branch `fix/session-fresh-worktrees`) edits `coldlogic:worktree-hooks-path`, `coldlogic:openspec-files`, `coldlogic:generated-files-stale`, `coldlogic:setup-freshness`, `claude.code.env` and the guard. This change edits none of those.

- **`devenv.nix`, the `let` block (7-10).** Both add an `import ./packages/….nix` line. A textual conflict at most: keep both lines.
- **`devenv.nix`, elsewhere.** This change adds to `packages` (173-180) and rewords one comment sentence (507-509). Neither is in a task that change edits.
- **`generated-files`, "A session never writes the settings link".** Both carry the whole requirement as MODIFIED. That change rewords the THEN of "Missing settings link". This one changes the description's second sentence and adds the scenarios "Wrapper refresh" and "The wrapper run by a session". The second to land rebases its copy onto the first's, keeping both edits.
- **`generated-files`, "Stale generated files are reported once".** Only that change modifies it (decision 7).
- **`generated-files`, Purpose.** Only this change edits it.
- **The session test.** That change's new shell logic tests `CLAUDECODE`. So does everything here but the wrapper, so the two agree. If the open question below is answered with a switch, that change's tests switch with it.
- **`README.md`.** This change adds one table row and one section, and leaves the `devenv.nix` row alone.
- **`packages/`, `scripts/check.sh`.** New files with their own names; one comment in `check.sh` that the other change doesn't touch.
- **`COLDLOGIC_SESSION_ROOT`.** That change adds it to the settings' environment. The wrapper doesn't read it.

Neither change needs the other to land first.

## Risks / Trade-offs

- **An older session undoes the refresh (#100).** A session that started without the settings link and is still open unlinks the link the wrapper creates, at its next tool call. The new session has already read its settings, so it is whole, but the link is gone for the one after. → The next `claude` refreshes again. The notice still tells sessions to restart. Not fixed here: only closing the old session does.
- **The refresh replaces a link under other running sessions.** `devenv:files` relinks only what is out of date, as a terminal `devenv shell` and every direnv reload already do. Nothing new, but it now happens at every launch after a change.
- **`CLAUDE_CODE_CHILD_SESSION` isn't set where it should be** (Claude Code before 2.1.172). A `claude` a session starts would run the refresh inside the sandbox with `CLAUDECODE` cleared: #68's unlink without the create. → Only reached by a session running `claude` through the wrapper while a link is out of date; the refusal rule reports a missing link; the README names the minimum version. Decision 2 keeps every other shell on `CLAUDECODE`.
- **Launch cost.** Every `claude`, `claude --version` and `claude mcp …` waits for a devenv evaluation, and for a build after a change. Unmeasured. → Task 5.1 measures it. If the warm cost is over a second or two, come back before merging: the alternatives in decision 3 trade it against correctness.
- **A silent wait.** `--quiet` and no message of our own means a cold refresh shows nothing until it ends. → Accepted for now with the measurement; a "refreshing…" line would land in every `claude -p` caller's stderr.
- **A hung devenv hangs the launch.** → Ctrl-C ends both. The real binary is still reachable by its path, which the README says how to find.
- **The profile isn't the shell's.** The refresh evaluates what `devenv.yaml` selects (`profile: developer`, which adopt.sh writes and direnv uses). A shell entered with other `--profile` flags gets a refresh for the yaml's profile. If that has no generated files, devenv has no `devenv:files` task, the refresh fails, and decision 4 applies. → Documented in the README's limits.
- **The inherited environment misleads devenv.** `DEVENV_ROOT`, `DEVENV_STATE` and `DEVENV_DOTFILE` from another checkout's shell are in the refresh's environment. `devenv shell` ignored them (checked); `tasks run` is assumed to. → Task 5.3 checks the main checkout's links and state are untouched.
- **Two launches at once.** Two refreshes of one checkout run together. → A failure of either falls under decision 4, with the link normally present.
- **Something on `PATH` calls `claude` often** (an IDE extension started from the shell, a script). Each call refreshes. → Output and input are protected (decision 3); the cost is the launch cost above.
- **Agent-team teammates.** If Claude Code starts them through `claude` on `PATH` in a tmux session, `CLAUDECODE` is set and `CLAUDE_CODE_CHILD_SESSION` may not be, so each teammate's start refreshes. Not sandboxed, so it is safe, but it costs time per teammate. → Task 5.5 looks.
- **The tests stub devenv.** Nothing at build time proves the real command links anything. → The terminal runs in section 5.

## Migration Plan

Lands with the next module update. A shell entered before the update has no wrapper; after `devenv update coldlogic-devenv` and a new shell (or direnv reload), `claude` is the wrapper. Rollback is reverting the commit: the wrapper leaves no state behind.

## Open Questions

1. **Should a plain `devenv shell` in an IDE terminal count as a terminal shell?** Decision 2 says not in this change. Options: keep the tasks on `CLAUDECODE` (chosen); switch the statuses and `coldlogic:session-files` to `CLAUDE_CODE_CHILD_SESSION`; switch all five tests. A switch is its own change with its own spec delta, after `session-fresh-worktrees`.
2. **Is the launch cost acceptable?** Depends on task 5.1's numbers.
3. **Should the notice's advice shrink to "restart `claude` from the devenv shell"?** After both changes land (decision 7).
