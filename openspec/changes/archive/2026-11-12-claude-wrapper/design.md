# Design

## Context

See proposal.md for the motivation. The driver is #100's finding: a running session unlinks a settings link created after it started (`fs_usage`: `unlink … claude.<pid>`). Claude Code's documentation says it hot-reloads settings files and "also loads a settings file you create mid-session if its folder existed", which is not what #100 saw. So the plan doesn't rely on a session picking up a link made later: the link must be current before the session starts.

Derek's decisions, taken as given:

- The wrapper lives in devenv, not a plugin SessionStart hook.
- The refresh is `devenv --quiet tasks run devenv:files`. Every invocation refreshes.
- On failure it starts with the link present and refuses without it, with an env override. A refresh that succeeds is trusted and silent.
- The session marker is the module's own, set by the wrapper, with Claude Code's variables only as fallbacks: `CLAUDECODE` for the shell's test, `CLAUDE_CODE_CHILD_SESSION` for the wrapper's. The five tests in `devenv.nix` become one definition.
- The stale notice's wording waits until this change and `session-fresh-worktrees` have both landed.
- The spec home is `generated-files`.

**Checked, in this worktree (devenv 2.4.0, Claude Code 2.1.322, in a session):**

- `devenv tasks list`: `devenv:files` depends on `coldlogic:session-files`, which depends on `devenv:files:cleanup`. `devenv tasks run devenv:files` (default mode `before`) ran exactly those three, in that order, applied the statuses (both file tasks `(cached)`, since this is a session), and didn't run `enterShell` or any other task.
- That command printed a JSON line on standard output (`{"devenv:files":{…}}`), without `--quiet`. Whether `--quiet` drops it wasn't checked, so the wrapper discards the refresh's standard output.
- `devenv tasks run --help`: `--mode` defaults to `before`; `-q, --quiet` is a global option.
- A session's Bash tool has both `CLAUDECODE=1` and `CLAUDE_CODE_CHILD_SESSION=1`.
- Claude Code's environment variable reference: `CLAUDECODE` is set for the Bash and PowerShell tools, tmux sessions, hooks, status line commands and stdio MCP servers, and by IDE extensions in their terminals. `CLAUDE_CODE_CHILD_SESSION` is set for the Bash, PowerShell and Monitor tools, hooks and status line commands, not for stdio MCP servers and not by IDE extensions, and needs Claude Code 2.1.172 or later.
- The session's `PATH` lists the developer profile's package directories (`git`, `openspec`, `gh-app`, `coldlogic-prune-worktrees`) before `/opt/homebrew/bin`, where the real `claude` is. So a `claude` in `packages` (devenv.nix:173-180) comes first.
- With `DEVENV_ROOT` inherited as the main checkout, `devenv shell` run in this worktree worked on the worktree (its notice named the worktree's settings path). So `devenv shell` picks its project from the current directory.
- `devenv.nix`: the session tests are `skipInSession` (76-78, used by the two statuses at 516-517), `coldlogic:session-files` (526), `coldlogic:generated-files-stale` (544) and `coldlogic:prune-worktrees` (654). All test `CLAUDECODE`, at run time. No other file in `packages/`, `profiles/`, `scripts/`, `templates/` or `tests/` tests it (`prune-worktrees-test.sh` only unsets it). Evaluation reads only `HOME`, `GNUPGHOME` and `COLDLOGIC_GPG_AGENT_SOCKET`.
- The main specs name `CLAUDECODE` in three places: `generated-files` twice (lines 95 and 118) and `worktree-cleanup` once (line 353).
- The module's only MCP server is `mcp.devenv.sh`, of type `http` (`.mcp.json`, `enabledMcpjsonServers`). Neither profile nor any fixture adds one.
- `packages/session-relink.nix` and `packages/prune-worktrees.nix`: `pkgs.runCommand` runs `<name>-test.sh` against the raw script, and the application's text refers to it, so the build needs the tests to pass. `scripts/check.sh` shellchecks every `*.sh` (91) and builds the shell and the fixtures' shells (107-116), on Linux in CI.
- The parallel change's proposal and `generated-files` delta, in `coldlogic-devenv.worktrees/session-fresh-worktrees`. Its `session-notices` delta has a scenario on `CLAUDECODE` being set.

**Assumed, not checked:**

- That the task processes of `devenv tasks run` see the caller's environment, so clearing the two variables in the wrapper's subshell makes the statuses run the tasks. A session's `CLAUDECODE` does reach them (the tasks were skipped), which supports it. Not run from here: it would run devenv's link step inside the sandbox, the thing #68 forbids.
- That Claude Code passes an environment variable it was started with to its tool calls, hooks, stdio MCP servers and tmux sessions. `PATH`, `DEVENV_ROOT` and the rest of the shell's environment reach this session's tool calls, which supports it.
- That `devenv tasks run`, like `devenv shell`, picks its project from the current directory and writes that project's state, with `DEVENV_ROOT` and `DEVENV_STATE` inherited from another checkout's shell.
- That direnv's `PATH` has the same order as `devenv shell`'s. This session's `PATH` came through direnv and has it; a fresh terminal wasn't tried.
- What the refresh costs from a terminal, warm and cold.
- That no project moves `claude.code.settingsPath`. Claude Code reads only `.claude/settings.json`, so another path would be no use.

## Goals / Non-Goals

**Goals:**

- A session started with `claude` from the devenv shell starts with current generated files, with no manual step.
- A wrapper run by a session changes nothing.
- The shell's session test reads as the module's own, is defined once, and is never weaker than today's `CLAUDECODE` test.
- The wrapper is invisible to the launch: arguments, directory, standard streams, exit code, signals and `PATH` are Claude Code's own.
- After a failed refresh, a session doesn't start with no settings at all without the developer being told and choosing it.

**Non-Goals:**

- Sessions not started through `PATH` in the devenv shell: the IDE extension's own launch, the desktop app, a `claude` run by absolute path. They get no refresh and no marker, and are still sessions by the `CLAUDECODE` fallback.
- Fixing a session that is already running. The notice still covers that.
- The rest of `devenv shell`: OpenSpec's skills, the plugin install, the hooks path, the prune. They don't decide whether a session has its guard, and they'd make every launch slower.
- Treating an IDE terminal's plain `devenv shell` as a terminal shell. `CLAUDECODE` is set there, so the fallback still counts it as a session.

## Decisions

### 1. The module's own session marker: `COLDLOGIC_DEVENV_SESSION`

The wrapper exports `COLDLOGIC_DEVENV_SESSION=1` before it starts the real `claude`, on every path that starts it. Claude Code hands its environment to what it runs, so each tool call, hook, stdio MCP server and tmux teammate of that session has it.

The name: `COLDLOGIC_` as the module's other variable has (`COLDLOGIC_GPG_AGENT_SOCKET`); `DEVENV` because it is the devenv shell's notion of a session, and the shell's tasks are what read it; no `CLAUDE` in it, so it can't be taken for one of Claude Code's own variables, which is what made the old tests hard to read. It is a flag, and stays apart from the parallel change's `COLDLOGIC_SESSION_ROOT`, which is a path. Any non-empty value counts.

The wrapper's other two variables are renamed the same way, since `COLDLOGIC_CLAUDE_…` reads as something Claude Code defines:

- `COLDLOGIC_START_WITHOUT_SETTINGS` (was `COLDLOGIC_CLAUDE_START_ANYWAY`): the name says what the developer is choosing.
- `COLDLOGIC_WRAPPERS_RUN` (was `COLDLOGIC_CLAUDE_WRAPPERS`): the wrappers already run in this launch.

The package and its store path keep `claude` in their names (`coldlogic-claude-wrapper`): there it names the command being wrapped.

### 2. One session test in `devenv.nix`: the marker, or `CLAUDECODE`

One `let` binding holds the test, and all five places use it:

```nix
inSession = ''{ [ -n "''${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "''${CLAUDECODE:-}" ]; }'';
```

| Place | Today | Becomes |
| --- | --- | --- |
| `skipInSession`, the status of `devenv:files` and `devenv:files:cleanup` (76-78, 516-517) | `[ -n "${CLAUDECODE:-}" ]` | `${inSession}` as the whole script |
| `coldlogic:session-files` (526) | `[ -n … ] \|\| exit 0` | `${inSession} \|\| exit 0` |
| `coldlogic:generated-files-stale` (544) | the same | `${inSession} \|\| exit 0` |
| `coldlogic:prune-worktrees` (654) | `[ -z … ] \|\| exit 0` | `if ${inSession}; then exit 0; fi` |

All five switch together, because they must agree: `coldlogic:session-files` is the exact complement of the statuses, and a shell where one test said "session" and another didn't would run both linkings or neither.

The test is a superset of today's: everything that has `CLAUDECODE` still counts. So it can only skip the file tasks in more places than today, never fewer, and #68's protection holds for the desktop app and the IDE extension's own sessions, which never see the marker. The marker adds the sessions where `CLAUDECODE` would be missing or cleared, and makes the common case readable as ours.

The spec's "Each status in `devenv.nix` is a single test of `CLAUDECODE`" becomes "the shared session test and nothing else", with a new requirement that defines the test once.

*Rejected: the marker alone, dropping `CLAUDECODE`.* Sessions the wrapper didn't start would run `devenv:files` in the sandbox: #68.

*Rejected: `CLAUDE_CODE_CHILD_SESSION` as the shell's fallback.* A plain `devenv shell` in an IDE terminal would then refresh, which is a gain. But the guard would fail open on a Claude Code older than 2.1.172, and for a stdio MCP server started as `devenv shell -- <server>` in a session the wrapper didn't start, which has `CLAUDECODE` and not `CLAUDE_CODE_CHILD_SESSION`: devenv's file tasks would run under a live session. None of the module's servers does that (checked); a project's or a plugin's might.

*Rejected: set the marker through `claude.code.env` in the generated settings as well.* It would reach only sessions that loaded the settings, and the failure this guards is a session without them. `CLAUDECODE` covers those sessions already, and the parallel change is editing `claude.code.env`.

*Rejected: keep `CLAUDECODE` as the only test and have the wrapper just clear it.* The first draft of this plan. It works, but leaves the confusing name in five places and no marker of our own.

### 3. The wrapper's own test: the marker, or `CLAUDE_CODE_CHILD_SESSION`

`[ -n "${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]` means a session started this process: no devenv, start the real `claude` at once. The marker covers every `claude` inside a session the wrapper started, whatever the Claude Code version. `CLAUDE_CODE_CHILD_SESSION` is the fallback for a `claude -p` inside a session started another way.

`CLAUDECODE` can't be the wrapper's fallback: IDE extensions set it in their terminals, where the developer is about to start a session and the refresh must run.

### 4. The refresh is devenv's own file tasks, at the checkout's top

`devenv --quiet tasks run devenv:files`, in a subshell: `cd` to the checkout, `unset CLAUDECODE COLDLOGIC_DEVENV_SESSION` and every `DEVENV_` variable, standard input from `/dev/null`, standard output to `/dev/null`, stderr left alone. The wrapper's own directory and environment never change.

- The two variables are cleared so the shared test (decision 2) lets the file tasks run. `CLAUDECODE` is the one an IDE terminal sets. The marker is already exported by then, for the real `claude`.
- The shell's `DEVENV_` variables (`DEVENV_ROOT`, `DEVENV_DOTFILE`, `DEVENV_STATE`, `DEVENV_PROFILE` and the rest) are cleared too (review finding): a shell entered in the main checkout and moved into a worktree names the main checkout in them, and devenv could work on its state. Without them devenv works out the project from the directory, as a terminal shell does. The real `claude` still gets them.
- Standard input: the wrapper's may be a prompt piped to `claude -p`. devenv must not be able to read it.
- Standard output: `claude -p` output is often captured, and devenv printed JSON there (checked).
- Stderr: with `--quiet` devenv says nothing unless it fails, and then its error is what the developer needs. The wrapper adds nothing on success (Derek's decision).

The checkout is `git rev-parse --show-toplevel` when that directory has a `devenv.nix` or `devenv.yaml`; else none. Never `$DEVENV_ROOT`: a shell entered in the main checkout and moved into a worktree still has the main checkout's `DEVENV_ROOT` (this session does), and `claude` reads the settings of the directory it starts in, not that checkout's. With no checkout, the wrapper starts `claude` at once, with no refresh, no settings check and no message: there are no generated settings of the module's there to refresh or be without. (An earlier version fell back to `$DEVENV_ROOT`, and so refreshed, and refused on, another project's link; review finding.)

*Rejected: `devenv shell --quiet -- true`.* It runs every task: the freshness check's network call, the OpenSpec generation, the plugin install, the hook install. Slower, and none of it decides whether the session has its settings.

*Rejected: link the settings directly with `coldlogic-session-relink` and the store path of the shell's evaluation.* Fast, with no evaluation. But the wrapper is built by one evaluation and used in any checkout, the store path it would link is the one from when the shell was entered, not the current one, and it would be a second thing that writes the link besides devenv.

*Rejected: refresh only when something looks stale.* Deciding that needs the evaluation, which is the cost.

*Rejected: a timeout on the refresh.* A cold build legitimately takes minutes, and a timeout needs a tool on `PATH` or by store path. Ctrl-C stops the wrapper and devenv together.

### 5. When the refresh fails

Derek's decision, made exact:

- The settings are "there" when `<checkout>/.claude/settings.json` resolves to a file (`[ -e ]`). A link whose store path is gone counts as missing: Claude Code would read nothing through it. A regular file, as in a project not yet adopted, counts as there.
- There: one `coldlogic:` line on stderr (the checkout, the exit code, "may be out of date", and `devenv shell` to see why), then start.
- Missing: one line naming the file, what the session would lack, and `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude`; exit 1. With the variable set to anything non-empty: one line, then start.
- `devenv` missing from `PATH` is a failed refresh (the subshell exits 127), not a special case.
- A refresh that succeeds is trusted (Derek's decision): no message, no look at the link.

*Rejected: check the link after a successful refresh too.* A project that turns `claude.code` off would never be able to start `claude`, and a devenv that reports success without linking is devenv's bug to surface, not ours to guess at.

*Rejected: always start, only warning.* A session with no guard, sandbox settings or permissions is the failure #101 exists for. Starting it should be a choice.

*Rejected: always refuse on failure.* A broken `devenv.nix` mid-edit would lock the developer out of the tool they'd use to fix it, while the old settings are still in place and still protect.

### 6. Finding the real `claude`

Walk `PATH` in order. Skip an entry whose `claude` isn't an executable file, is the same file as the wrapper (`-ef`, which follows links, so it covers a directory listed twice and a profile link), or is the same file as any path in `COLDLOGIC_WRAPPERS_RUN`. Start the first one left, with the wrapper's own absolute path added to that variable. None left: exit 127, before any refresh.

The variable has to be a list. Skipping only itself isn't enough: with two module versions' wrappers on `PATH` (a `devenv shell` inside a direnv shell of another checkout, or of a worktree on another lock), A skips A and starts B, and B, searching from the front, skips B and starts A, forever. With the list each start adds one path, so a chain ends.

It stays apart from the session marker. The marker says "a session is running"; the list says "these files are wrappers". In the two-wrapper chain, A exports the marker and starts B, so B sees the marker and doesn't refresh a second time.

*Rejected: use the session marker to stop the loop.* The session inherits it, so every `claude` a session starts would be refused, or would have to guess which `claude` is real.

*Rejected: recognise a wrapper by its store path's name.* It works only for names this version knows, and the tests run the script outside the store.

*Rejected: bake the real path in at build time.* Claude Code isn't from nix here (`/opt/homebrew/bin/claude`), and differs per machine.

### 7. Packaging

`packages/claude-wrapper.sh` is the raw script, `packages/claude-wrapper-test.sh` its cases, `packages/claude-wrapper.nix` the package, following `session-relink.nix`.

- `pkgs.writeShellApplication` named `coldlogic-claude-wrapper`, with `runtimeInputs = [ ]`, and a `runCommand` whose only content is `bin/claude`, a link to it. So the store path says what it is, and `claude` is the one name it puts on `PATH`.
- No `runtimeInputs`: `writeShellApplication` exports them onto `PATH`, and the session inherits the wrapper's environment. The nix text sets `git_bin` to git's store path before the script's body; the raw script falls back to `git` on `PATH`, which is how the tests stub it. Everything else is bash builtins.
- `devenv` comes from `PATH`: it must be the developer's own, the one that made the shell. nixpkgs' would be another version with another evaluation cache.
- The script ends in `exec`, so no wrapper process stays between the terminal and Claude Code.

*Rejected: a devenv `scripts.claude` entry.* devenv's scripts are wrapped by devenv, the body would live inline in `devenv.nix` with no build-time tests, and the other three tools are packages.

*Rejected: a shell alias or function from `enterShell`.* It wouldn't exist under direnv, which exports only the environment.

### 8. No change to the stale notice's text

Derek's decision: after both changes land. The notice (devenv.nix:584) keeps its words; only the task's first line, the session test, changes (decision 2).

## Overlap with `session-fresh-worktrees`

That change (branch `fix/session-fresh-worktrees`) edits `coldlogic:worktree-hooks-path`, `coldlogic:openspec-files`, `coldlogic:generated-files-stale`, `coldlogic:setup-freshness`, `claude.code.env` and the guard, and adds `packages/session-shell.sh`. Whichever change lands second adapts to the first.

- **The session test (the one that matters).** That change's new shell logic, in `packages/session-shell.sh` and the tasks that call it, tests `CLAUDECODE`. After this change the shell's test is "`COLDLOGIC_DEVENV_SESSION` or `CLAUDECODE`". A script can't use the nix binding, so its test has to be written the same way, or the tasks have to pass the answer in, guarded by `${inSession}`. A `CLAUDECODE`-only test there would be wrong only where the marker is set and `CLAUDECODE` isn't, which Claude Code doesn't produce today, so nothing breaks in the gap; it is a consistency fix. Its `session-notices` spec names `CLAUDECODE` in a scenario and needs the same wording.
- **`devenv.nix`, `coldlogic:generated-files-stale` (544).** This change replaces the task's first line. That change rewrites the task. A textual conflict: the rewritten task keeps `${inSession} || exit 0` as its session test.
- **`devenv.nix`, `coldlogic:openspec-files`, `coldlogic:setup-freshness`, `coldlogic:worktree-hooks-path`.** Not edited here. If that change adds session tests to them, they use `${inSession}`.
- **`devenv.nix`, the `let` block (7-10).** Both add an `import ./packages/….nix` line. Keep both.
- **`devenv.nix`, elsewhere.** This change adds to `packages` (173-180), adds `inSession` and changes `skipInSession` (74-78), changes one line each in `coldlogic:session-files` (526) and `coldlogic:prune-worktrees` (654), and rewords comments (53-54, 497-511). That change touches none of those.
- **`generated-files`, "A session never writes the settings link".** Both carry the whole requirement as MODIFIED. That change rewords the THEN of "Missing settings link". This one drops "(`CLAUDECODE` set)", changes the description's second sentence and adds the scenarios "Wrapper refresh" and "The wrapper run by a session". The second to land rebases its copy onto the first's, keeping both edits.
- **`generated-files`, "A session never runs devenv's file tasks".** Only this change modifies it.
- **`generated-files`, "Stale generated files are reported once".** Only that change modifies it (decision 8).
- **`generated-files`, Purpose.** Only this change edits it.
- **`README.md`.** This change adds one table row and one section, and leaves the `devenv.nix` row alone.
- **`packages/`, `scripts/check.sh`.** New files with their own names; one comment in `check.sh` that the other change doesn't touch.
- **`COLDLOGIC_SESSION_ROOT`.** That change adds it to the settings' environment. The wrapper doesn't read it, and the names don't collide.

Neither change needs the other to land first.

## Risks / Trade-offs

- **An older session undoes the refresh (#100).** A session that started without the settings link and is still open unlinks the link the wrapper creates, at its next tool call. The new session has already read its settings, so it is whole, but the link is gone for the one after. → The next `claude` refreshes again. The notice still tells sessions to restart. Not fixed here: only closing the old session does.
- **The refresh replaces a link under other running sessions.** `devenv:files` relinks only what is out of date, as a terminal `devenv shell` and every direnv reload already do. Nothing new, but it now happens at every launch after a change.
- **The marker outlives its session.** A long-lived process started inside a session (a tmux server, a terminal opened from a tool call) keeps `COLDLOGIC_DEVENV_SESSION`, and every shell under it counts as a session: no refresh from `claude` or `devenv shell` there. → It fails closed, never open. The shell's notice appears there, and the README says to check `printenv COLDLOGIC_DEVENV_SESSION` and start a fresh terminal.
- **Neither of the wrapper's variables is set where it should be.** A session the wrapper didn't start, on a Claude Code before 2.1.172, runs `claude` through the wrapper: the refresh runs inside the sandbox with `CLAUDECODE` cleared, #68's unlink without the create. → Three conditions at once, and only when a link is out of date; the refusal rule reports a missing link; the README names the version. Sessions the wrapper started are covered by the marker on any version.
- **An IDE terminal's plain `devenv shell` still counts as a session**, because `CLAUDECODE` is the fallback. It doesn't refresh, and its notice says to use a terminal. → The wrapper covers what matters there, starting `claude`. Fixing it means weakening the fallback (decision 2's second rejected alternative).
- **Launch cost.** Every `claude`, `claude --version` and `claude mcp …` outside a session waits for a devenv evaluation, and for a build after a change. Unmeasured. → Task 6.1 measures it. If the warm cost is over a second or two, come back before merging: the alternatives in decision 4 trade it against correctness.
- **A silent wait.** `--quiet` and no message of our own means a cold refresh shows nothing until it ends. → Accepted (Derek's decision); a "refreshing…" line would land in every `claude -p` caller's stderr.
- **A hung devenv hangs the launch.** → Ctrl-C ends both. The real binary is still reachable by its path, which the README says how to find.
- **The profile isn't the shell's.** The refresh evaluates what `devenv.yaml` selects (`profile: developer`, which adopt.sh writes and direnv uses). A shell entered with other `--profile` flags gets a refresh for the yaml's profile. If that has no generated files, devenv has no `devenv:files` task, the refresh fails, and decision 5 applies. → Documented in the README's limits.
- **The inherited environment misleads devenv.** `DEVENV_ROOT`, `DEVENV_STATE` and `DEVENV_DOTFILE` from another checkout's shell would be in the refresh's environment. → The refresh clears every `DEVENV_` variable (decision 4), and task 6.3 checks the main checkout's links and state are untouched.
- **Two launches at once.** Two refreshes of one checkout run together. → A failure of either falls under decision 5, with the link normally present.
- **Something on `PATH` calls `claude` often** (an IDE extension started from the shell, a script). Each call outside a session refreshes. → Output and input are protected (decision 4); the cost is the launch cost above.
- **The shell's tests have no automated test.** The five uses of `inSession` are checked by reading the generated scripts (section 4), as the statuses are today.
- **The wrapper's tests stub devenv.** Nothing at build time proves the real command links anything. → The terminal runs in section 6.

## Migration Plan

Lands with the next module update. A shell entered before the update has no wrapper; after `devenv update coldlogic-devenv` and a new shell (or direnv reload), `claude` is the wrapper. Sessions already running have no marker and stay sessions through `CLAUDECODE`. Rollback is reverting the commit: the wrapper leaves no state behind.

## Open Questions

1. **Is the launch cost acceptable?** Depends on task 6.1's numbers.
2. **The notice's advice** can shrink to "restart `claude` from the devenv shell" once both changes have landed (decision 8).
