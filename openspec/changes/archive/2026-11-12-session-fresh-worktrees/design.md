# Design

## Context

See proposal.md for the motivation. This section holds what was checked, and what is assumed.

There are two kinds of worktree a session works in, and they behave differently:

- **EnterWorktree**: the session moves into `<main>.worktrees/<name>`, which becomes the session's project. Claude Code's sandbox then protects that worktree's `.claude/settings.json`, `settings.local.json`, `.claude/skills`, `.claude/hooks`, `.mcp.json` and git config, as it does the main checkout's.
- **Subagent isolation** (`isolation: worktree`): `<main>.worktrees/agent-*`. It isn't the session's project. The module's own sandbox settings open it for writing and protect only its `.git` file and `.claude` configuration (`siblingWorktreeConfig`, devenv.nix:164-170).

**Checked today (2026-11-12), in this EnterWorktree worktree, from a session:**

- `devenv shell --quiet -- true` prints `error: could not lock config file <main>/.git/worktrees/session-fresh-worktrees/config.worktree: Operation not permitted`. `coldlogic:worktree-hooks-path` fails, and `devenv:git-hooks:install` and `devenv:enterShell` fail as dependencies. The command still runs.
- The worktree's `config.worktree` already holds `core.hooksPath = <main>/.git/hooks`. Its timestamp is the worktree's creation time, so the harness wrote it. The task wants `<main>/.git/worktrees/<name>/hooks` instead, sees a difference and writes.
- `<main>/.git/hooks/pre-commit` exists (prek, installed by a terminal shell). Its last line passes `--config=".pre-commit-config.yaml"`, a relative path. git runs hooks from the top of the worktree that commits, so the hook reads that worktree's own configuration.
- This worktree has `.pre-commit-config.yaml` (linked by `coldlogic:session-files`), no `.mcp.json`, and a `.claude/` holding only Claude Code's `.cc-writes`.
- `access(2)` reflects the sandbox (a known-denied path reads as not writable, `.devenv` as writable). By it, a session can't write `<main>/.git/hooks`, `<main>/.git/hooks/pre-commit`, `<main>/.git/config`, or this worktree's `config.worktree`. It can write `<main>/.git/worktrees/agent-*/hooks`.
- The notice lists `.mcp.json` and `.claude/settings.json` as missing, and `coldlogic:openspec-files` warns with `EPERM ... mkdir .../.claude/skills`, on every shell.
- A command's environment in this worktree has `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID=<uuid>` and `XDG_RUNTIME_DIR=~/.cache/devenv/run`. The last comes from the main checkout's settings `env`, so a session carries its settings' `env` into a worktree it entered.

**Checked, in the subagent worktrees on this machine:**

- `agent-ac29841244a565309`: `config.worktree` names its own `hooks` directory, written two minutes after the worktree was made, and that directory holds `pre-commit`. `.mcp.json` and `.pre-commit-config.yaml` are links. All written from a session.
- `agent-acf80ec4ed5df4a6d` (made before #99): `config.worktree` names its own `hooks` directory, written in the minute the worktree was made, and that directory doesn't exist. Commits there run no hooks, and nothing says so.
- Both settings are the module's own doing (`coldlogic:worktree-hooks-path`). The harness writes `<main>/.git/hooks`, as in this worktree.

**Checked, in devenv at the locked rev** (`devenv.lock`: `9655d320`, `src/modules/integrations/git-hooks.nix`):

- `devenv:git-hooks:install` has an `exec` and no `status`. It resolves the hooks directory with `git rev-parse --path-format=absolute --git-path hooks`, which follows `core.hooksPath`. On a cache hit (a key and manifest under `$DEVENV_STATE/git-hooks-install`) it exits 0 without writing. On a miss it runs `prek install -c <relative config> -t <hook>` under `set -e`, so a refused write fails the task. A fresh worktree has no state, so its first shell is always a miss. The key includes the hooks directory, and the manifest fingerprints each expected hook there, so a hook that is missing or changed is a miss too (`stale_hook`) and gets reinstalled.
- Its changelog entry of 2026-10-19: hooks installed in a directory shared by linked worktrees now use the configuration of the worktree where git runs. That is the relative `--config` seen above.
- The expected hooks are `pre-commit` when `installStages` is empty, else each stage's hook name.
- A task's `status` is a string of its own; one that exits 0 skips the task and counts it as succeeded (as the module already does for `devenv:files`).

**Checked, in this repository:**

- `coldlogic:worktree-hooks-path` (devenv.nix:480-495) runs two `git config` writes with no error handling.
- `coldlogic:generated-files-stale` (devenv.nix:542-590) prints with one `echo` per case. `coldlogic:openspec-files` (devenv.nix:683-721) prints with two. `coldlogic:setup-freshness` prints with one (devenv.nix:641).
- The guard's `main_checkout_switch` (claude-guard.py:1834) already places each `git switch` and `git checkout` (`git_place`), finds the main checkout from a linked worktree (`main_checkout`), and reads loose and packed refs (`has_ref`, `packed_refs`).
- `claude-guard-test.py:1615-1616` and `:1623-1624` expect `allow` for `git switch -c feat/x origin/main`, `--create`, `--track -c` and `-C ... origin/main` in a linked worktree. The fixture has no `origin/main` ref.

**Assumed, not checked:**

- That a task's stderr is shown under `devenv shell --quiet` when every task succeeds. Today's runs all had a failed task, which prints the whole log. Task 6.3 checks it.
- That a task ordered `after` one whose status skipped it still runs. Decision 3's check depends on it. Task 6.2 shows it.
- That the harness writes `core.hooksPath = <main>/.git/hooks` for a subagent worktree as it does for an EnterWorktree one. With no setting at all git resolves the same directory, so nothing depends on it.
- That `prek install` creates a hooks directory that doesn't exist. It decides only whether `agent-acf80ec4ed5df4a6d` heals on its next shell or gets the missing-hook notice.
- That `CLAUDE_CODE_SESSION_ID` is set in every Claude Code version in use. It isn't documented. Decision 5 degrades without it.
- How git behaves when the tracking write is refused. #45 reports that the command fails partway; it wasn't rerun here, since it would have changed this worktree's branch.
- That Claude Code doesn't reload settings from a worktree a session enters. The `env` it carries says it keeps the ones it started with.
- That a commit in a linked worktree runs the main checkout's hook with the worktree's own configuration. Read from the hook's text and devenv's changelog, not run. Decision 2 rests on it; checklists B and C run it.

## Goals / Non-Goals

**Goals:**

- In a session, `devenv shell` in a fresh worktree of either kind ends with `devenv:enterShell` having run.
- A session's shell prints nothing about files that session doesn't read from that checkout, and each remaining notice once.
- A commit never silently loses its hooks because of this change: where no hook is in the directory commits will use, the shell says so. Where one is, it says nothing.
- The shell writes no git config.
- The new shell logic is in one script with build-time tests.

**Non-Goals:**

- Cleaning up a per-worktree `core.hooksPath` that an earlier shell wrote (decision 2).
- Denying the hooks path write in the sandbox (#97), and sibling worktree recognition in the guard (#65).
- The other commands that write tracking configuration: `git switch <name>` that guesses a remote branch, `git branch <new> <remote start>`, `git worktree add -b`, `git push -u`. They go to the tracking follow-up.
- The plugin install warnings. They are silent in a worktree with no settings file, which is every session-made one.
- Stopping `openspec init` from being tried, and failing, in the checkout a session started in. Only its warning changes there.
- A test that runs the devenv tasks. Derek decided against a gate fixture step for that (#99).

## Decisions

### 1. One tested script holds the session logic

`packages/session-shell.sh`, built as `coldlogic-session-shell` by `packages/session-shell.nix`, with `packages/session-shell-test.sh` run at build, the same shape as `session-relink`. Its subcommands:

| Subcommand | Does | Exit |
|---|---|---|
| `own-checkout` | Says whether this checkout is the one the session reads its Claude Code files from (decision 4) | 10: another checkout's. 0: this one, or can't tell |
| `notice <key> <text>` | Prints `<text>` on stderr unless this session was already shown it (decision 5) | 0; 2 on bad usage |
| `clear <key>` | Forgets what was shown for `<key>` | 0; 2 on bad usage |
| `skip-hooks-install [<hook>...]` | The status of `devenv:git-hooks:install` (decision 3). Prints nothing | 0: skip. 1: run |
| `hooks-check [<hook>...]` | The notice when an expected hook is missing (decision 3) | 0 |

**One session test.** The script asks "is this a Claude Code session?" in one function, `in_session` (`[ -n "${CLAUDECODE:-}" ]`), and nowhere else. `own-checkout`, `notice` and the install check all call it. This change adds no session test to `devenv.nix`: each task calls the script and goes by its exit code, and the tests already there (`skipInSession` and the three inline ones) are left as they are.

That is for the parallel `claude-wrapper` change (#101), which replaces `devenv.nix`'s `CLAUDECODE` tests with one Nix binding, `inSession`: `COLDLOGIC_DEVENV_SESSION` set, or `CLAUDECODE` set. Whichever change lands second reconciles the two in one edit, giving `in_session`'s body that same condition, plus one test case with only `COLDLOGIC_DEVENV_SESSION` set. The script is a standalone tested file and can't read a Nix binding, so the condition is written twice, once in each place.

A textual conflict is expected in `coldlogic:generated-files-stale`, whose first line #101 replaces and whose body this change edits. Resolve it by keeping #101's `${inSession} || exit 0` (or, if this lands first, today's `CLAUDECODE` line) as the first line, with this change's body after it. See Risks.

The tasks in `devenv.nix` keep their own conditions and texts and call the script for the decisions. Every call to `notice` there is wrapped so that a failing helper still prints: `coldlogic-session-shell notice <key> "$text" || echo "$text" >&2`.

*Rejected: move each task's whole body into its own script.* It would put `coldlogic:openspec-files` and `coldlogic:setup-freshness` under test too, but it rewrites working code that this change only touches at its `echo`s, and triples the diff.

*Rejected: two packages, one for notices and one for hooks.* The hooks code needs the notice code. One script calling another through PATH is harder to test than one script.

*Rejected: extend `session-relink.sh`.* It has one job, relinking, and its `set -eE` error trap exits 3 on any failure. A notice helper must do the opposite: print when anything goes wrong.

### 2. The per-worktree hooks path step is removed

`coldlogic:worktree-hooks-path` is deleted, with nothing in its place. The shell writes no git config. A worktree uses the hooks directory git resolves: `<main>/.git/hooks` for a new worktree of either kind, whether the harness wrote that into `config.worktree` or nothing is set.

The step existed because the installed hook once named one worktree's configuration by absolute path, so the last worktree to install won for all of them. devenv's change of 2026-10-19 made the hook name its configuration by a relative path, and git runs a hook from the top of the committing worktree. Checked here: the main checkout's hook ends with `--config=".pre-commit-config.yaml"`.

This is Derek's answer to the first plan's open question, and it replaces that plan's fail-soft design: there is no write left to refuse, so #67's failure and its notice both go.

**Worktrees that already have a per-worktree `core.hooksPath` are left alone.** The shell neither sets nor unsets it. What happens to each:

- Its own hooks directory holds the hook (`agent-ac29841244a565309`): nothing changes. Installs keep going there, where a session can write.
- Its own hooks directory is missing or empty (`agent-acf80ec4ed5df4a6d`): the install sees a missing hook as a cache miss and reinstalls, where it can write. Where it can't, or it doesn't, decision 3's notice names the directory.
- The main checkout's own entry (`<main>/.git/hooks`, which is also git's default): no effect.

Worktrees are short-lived; merged ones are pruned (#81).

**The devenv version.** An importing project gets devenv's hook module from its own `devenv.lock`. On a devenv before 2026-10-19, worktrees sharing `<main>/.git/hooks` run the hook configuration of whichever worktree installed last, which is the bug the removed step worked around. The module's lock is past that date and projects follow it through the update workflow; the README says so (task 6.4).

*Rejected: keep the step, fail-soft* (the first plan). It kept a git config write on every fresh worktree's first shell, a notice to explain the refused one, and code and tests for both, to work around a devenv bug that is fixed.

*Rejected: unset a stale per-worktree `core.hooksPath`, fail-soft.* It would bring every worktree back to one hooks directory, and mend `agent-acf80ec4ed5df4a6d` in a terminal. But it is the same kind of write that caused #67, refused in the same places, and it needs the guard code, the notice and the tests this decision removes. It could also only recognise the module's own value (`<git dir>/hooks`), and removing it from a session worktree would move that worktree from a hooks directory the session can write to one it can't. The install and the notice already cover the broken case.

*Rejected: fold in #97* (deny the write in the sandbox). With no write there is nothing to deny; #97 can likely close.

*Rejected: detect an old devenv* (look for an absolute `--config` in the installed hook, and warn). It reads devenv's generated hook text, which can change, for a case the update workflow already moves projects out of.

### 3. In a session, the hook install is skipped where it can't write

Decision 2 alone moves the failure one task along. A session's worktree resolves `<main>/.git/hooks`, which the sandbox protects; the worktree's install state is empty, so the install runs `prek install`, which is refused, and `devenv:enterShell` still fails as a dependency. The same happens in the main checkout whenever a module update changes the hooks configuration.

So `devenv:git-hooks:install` gets a `status`: `coldlogic-session-shell skip-hooks-install <hooks>`. It exits 0 (skip) only when all of these hold: this is a session (`in_session`, decision 1); git resolves a hooks directory; and that directory (or, if it doesn't exist yet, its nearest existing parent) fails `[ -w ]`, or an expected hook that exists there does. Anything else, any error included, exits 1, and the install runs as devenv wrote it. Outside a session it always exits 1.

The hook already in the directory keeps working: it calls prek with a relative configuration path, so it serves every worktree that points at it.

**The missing-hook notice.** A status prints nothing, so a new task, `coldlogic:hooks-check`, runs `hooks-check <hooks>` after the install and before `devenv:enterShell`. It looks at the hooks directory git resolves and nothing else. When an expected hook isn't an executable file there, it prints through `notice` with key `hooks-missing`:

- in a session: `coldlogic: commits here run no <hooks> hook: there is none in <dir>, and this Claude Code session can't install one there. Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell.`
- outside one: `coldlogic: commits here run no <hooks> hook: there is none in <dir>, and the install didn't add one.`

With every expected hook in place it clears the key and prints nothing. That is Derek's answer on the notice: silent when a hook exists, whichever directory it is in. Running after the install makes it one rule for every cause: a skipped install, an older hooks path naming a missing directory, or an install that didn't do its job. The task ends `|| true; exit 0`.

The expected hooks are computed in `devenv.nix` the way devenv computes them (`pre-commit` when `git-hooks.installStages` is empty, else the stage names mapped) and passed as arguments.

*Rejected: a status that always skips in a session.* A worktree with an older per-worktree hooks path has a directory the session can write, and may have no hook in it: the state `agent-acf80ec4ed5df4a6d` is in today. The install is what mends it.

*Rejected: check for the hook before the install, only where the install will be skipped* (the first plan). It needed the skip test twice and missed a hook that is absent for any other reason.

*Rejected: probe by creating a file in the hooks directory.* It is the surest test, but it writes into `.git/hooks` on every shell. `[ -w ]` was checked against the sandbox today and agreed with every known case. If it is ever wrong toward "writable", the install runs and fails as it does today, which is no worse.

*Rejected: replace the install's `exec` with a fail-soft copy.* The original can't be wrapped, only replaced whole (`lib.mkForce`), and we would own a copy of devenv's install and cache logic.

*Rejected: leave the install failing in a session's worktrees.* The command still runs, but `enterShell` doesn't, every shell prints the failed-task log, and the goal (a fresh worktree's shell succeeds quietly) isn't met.

### 4. The settings say which checkout they belong to

`claude.code.env.COLDLOGIC_SESSION_ROOT = config.devenv.root`. A session carries its settings' `env` into every command, wherever it runs. `own-checkout` compares it with `$DEVENV_ROOT`, by physical path:

- Not a session (`in_session`), the variable unset or empty, `DEVENV_ROOT` unset, or either path not resolvable: exit 0. This checkout is treated as the session's own, and everything is reported as today.
- Both resolve and are equal: exit 0.
- Both resolve and differ: exit 10. The session reads its settings, `.mcp.json` and skills from the other checkout, so their state here doesn't matter to it.

Callers treat any code but 10 as 0. Every failure leans toward reporting. The code is 10, not 1, because 1 is what a crash, a `set -e` exit or a missing-command wrapper gives: with 1, a broken helper would silence the settings notice.

This is Derek's rule ("a worktree's settings only matter to a `claude` started inside it") made checkable. It covers both worktree kinds, and it gets the opposite case right too: a `claude` started inside a linked worktree with no settings has no variable, so the missing settings are still reported there. That session has no guard and no sandbox, and should be told.

*Rejected: go by "is this a linked worktree?"* It needs no settings change, but it silences the notice for a session started in a worktree, the one case where missing settings are serious.

*Rejected: go by "does the sandbox refuse the write?"* It tells nothing: a session's own main checkout is refused too.

*Rejected: reuse `XDG_RUNTIME_DIR`* as the sign that the module's settings are loaded. It says a session has settings, not whose.

### 5. Each notice once per session, kept in the checkout's state

`notice <key> <text>`:

- Outside a session (`in_session` false): print, record nothing. Terminal behaviour doesn't change.
- In a session: the record is `<state>/coldlogic-notices/<key>`, where `<state>` is `$DEVENV_STATE`, else `$DEVENV_ROOT/.devenv/state`. Its content is `$CLAUDE_CODE_SESSION_ID` (or `-`) on the first line and the text after it. If the file holds exactly that, print nothing. Otherwise print, then write the record through a temporary file and a rename.
- A record that can't be read, doesn't match exactly, or can't be written leads to printing. Nothing here can fail the shell.

`clear <key>` removes the record. Each task calls it when its condition is gone, so a notice returns if the condition does.

The state directory is per checkout, so each worktree keeps its own records, and a worktree pruned takes them with it. So a notice is shown once per session and checkout, which Derek confirmed.

Keys: `generated-files`, `generated-files-check`, `openspec-files`, `hooks-missing`, `freshness`.

*Rejected: once per text, with no session in the record.* A notice printed on Monday would stay silent for every later session until the state changed. The stale-settings notice asks for an action; a new session must see it.

*Rejected: reprint after a time (an hour, as the freshness cache does).* A long session would see the same notice many times, and a short one started just after another might not see it at all.

*Rejected: keep the records under `~/.cache`, keyed by session.* It needs cleanup that the checkout's own state gets for free.

### 6. What each task does with the two rules

- **`coldlogic:generated-files-stale`**: when `own-checkout` exits 10, it compares the generated links without the settings path and `.mcp.json`; otherwise all of them, as today. Both lists are built at evaluation time. Its two notices go through `notice` (`generated-files`, `generated-files-check`), and it clears a key when that condition is gone. The session's linking (`coldlogic:session-files`) doesn't change: it still links `.mcp.json` wherever the sandbox allows, which a subagent worktree's does.
- **`coldlogic:openspec-files`**: where `own-checkout` exits 10, which only happens in a session, it exits 0 before doing anything. It has no session test of its own. Elsewhere it runs as today, with its warning through `notice openspec-files` (the `Failed:` line joined to the text as a second line) and a `clear` on success or when the stamp matches.
- **`coldlogic:setup-freshness`**: its `echo` goes through `notice freshness`, with a `clear` when the lock is current.

Stale and conflicting session-only files are left out along with missing ones. A worktree with an old settings link was set up from a terminal, and its next terminal shell refreshes it (direnv does on entry). The session working there can't fix it and doesn't use it.

The notice's text changes in one clause: `Then restart every Claude Code session open in this checkout, this one included, before any of them runs another command, since a running session can undo the refresh at its next tool call.` That is #94's finding: a session removes its project's settings link at its next tool call if the file wasn't there when it started.

### 7. The guard denies a tracking branch create

A new check beside `main_checkout_switch`, run right after it, for each `git switch` or `git checkout` the call holds whose directory is known:

- It applies where the command runs in the main checkout or in any linked worktree whose common directory is the main checkout's `.git`. Tracking is written to the shared `.git/config` from any of them. Nested and foreign repositories are left alone.
- It denies when the last tracking option is `--track` (any prefix git takes) or `-t`; or when there is no tracking option, a branch is created (`-c`, `-C`, `--create`, `--force-create`; `-b`, `-B` for checkout) and the start point names a remote-tracking branch: `refs/remotes/<start>` or `refs/remotes/<start>/HEAD` exists, loose or packed, with `<start>` also accepted as `remotes/...` or `refs/remotes/...`.
- `--no-track` as the last tracking option, `--detach`, `--orphan`, no start point, and a start point that is no remote-tracking branch (`main`, `origin/main~1`, a name that doesn't exist) are not denied.
- The reason: ``coldlogic guard: this `git switch` would set up tracking of origin/main, which writes .git/config. The sandbox protects that file, so the command would fail partway. Add --no-track: `git switch --no-track -c feat/x origin/main`.``

In the main checkout the existing deny comes first, with its own reason, since creating a branch there is already refused.

**Deny, not ask.** If a user approves the prompt, the command still fails in the sandbox, and it leaves a branch created but not checked out. The fix is one flag the session can add itself, as with the Bash-edit deny that points to Edit and Write.

**By refs, not by the look of the name.** git sets up tracking only when the start point resolves to a remote-tracking branch. Reading the refs is what the guard already does for `git checkout <name>`, and it keeps `git switch -c feat/x some/local-branch` allowed.

*Rejected: deny every create with a start point unless `--no-track` is given.* Simpler, and it would stop `git switch -c feat/y feat/x`, which writes nothing.

*Rejected: read `branch.autoSetupMerge`.* A repository can turn tracking off, and then the deny is unneeded. Reading git config from the guard, with its includes and scopes, is more than the saving is worth. The cost of the miss is one extra flag.

*Rejected: an ask rule in the settings (`git switch -c * origin/*`).* Rules match text. It can't see the last-option-wins order, a wrapper, or whether the start point is a remote branch.

## Risks / Trade-offs

- **[No hook in a session's worktree]** Commits there use `<main>/.git/hooks`. If no terminal shell ever installed a hook in the main checkout, there is none, and the session can't install one. → `hooks-check` prints the `hooks-missing` notice (decision 3). Checklists B and C commit a misformatted `.nix` file to see the hook fire.
- **[A subagent worktree loses its own hooks directory]** Until now a session installed a subagent worktree's hooks itself. Now they come from the main checkout's hook, which only a terminal shell installs. → It is the same hook with the worktree's own configuration; a missing one is reported; step 4 of the process already has the terminal shell.
- **[A branch that adds a hook stage]** A worktree whose branch adds, say, `pre-push` can't get that hook installed from a session. → `hooks-check` gets the expected hooks from that worktree's evaluation, so the notice names `pre-push`.
- **[Terminal shells in two worktrees rewrite the shared hook]** Each worktree's install fingerprints the shared hook; when two branches build different prek versions, each terminal shell reinstalls it. → A rewrite of one small file. Either hook reads the committing worktree's configuration.
- **[A stale per-worktree hooks path stays]** A worktree made before this change keeps its own hooks directory until it is pruned. → It works where it has a hook, heals where the install can write, and is reported otherwise (decision 2).
- **[The main checkout's hook is older than the worktree's prek]** The shared hook names the prek store path it was installed with, falling back to `prek` on PATH. → It reads the committing worktree's configuration either way. A terminal shell in the main checkout reinstalls it.
- **[`[ -w ]` and the sandbox disagree]** Wrong toward "not writable" in a session: the install is skipped where it would have worked, and the hook may be missing. → The `hooks-missing` notice covers a missing hook; a present one keeps working. Wrong toward "writable": today's failure, unchanged.
- **[A project on a devenv older than 2026-10-19]** There the shared hook names one worktree's configuration by absolute path, and with the per-worktree step gone every worktree runs the hook configuration of whichever installed last. → Still hooks, and usually the same ones. The module's own lock is past that date, projects follow it through the update workflow, and the README states the requirement. A hook installed in the main checkout before that date is replaced by the first terminal shell on the newer devenv, since its fingerprint changes.
- **[A notice hidden for a whole session]** Once shown, a notice stays silent until its text changes, its condition clears, or a new session starts. A session that ignored it won't be reminded. → That is the request. The stale-settings notice changes text when another file goes stale, and every new session sees it.
- **[No session id]** Without `CLAUDE_CODE_SESSION_ID` a notice is shown once per text, across sessions, until it clears. → Fail-open would mean printing on every shell again, which is what this change removes. Task 6.2 confirms the variable is there today.
- **[Stale records]** A record outlives its session. → One small file per key per checkout, overwritten by the next notice, removed with the worktree.
- **[Sessions started before the update]** They have no `COLDLOGIC_SESSION_ROOT`, so in worktrees they keep reporting the settings link and `.mcp.json` as missing, once per session. → The restart the settings change needs anyway fixes it.
- **[A worktree's stale settings go unreported]** A session in a worktree no longer mentions that worktree's old settings link. → Only a `claude` started there reads it, and that session, whose root is the worktree, reports it.
- **[The guard denies a create that would have worked]** With `branch.autoSetupMerge=false`, with the sandbox off, or when a local branch shadows the remote name, no tracking write would fail. → The cost is adding `--no-track`. The reason says exactly that.
- **[Tracking writers the guard still allows]** `git switch <remote-only name>`, `git branch x origin/main`, `git worktree add -b x path origin/main` and `git push -u` still reach the refused write. → Out of scope here, by Derek's decision; they are in the tracking follow-up.
- **[`reftable` repositories]** The guard reads loose and packed refs only, so it would find no remote branch and deny only the explicit `--track`. → Same limit as the existing checkout check. No project uses reftable.
- **[The new status or task fails]** → The `coldlogic:hooks-check` task ends `|| true; exit 0`. A status that errors exits non-zero, which runs the install as today.
- **[Two changes define "in a session"]** `claude-wrapper` (#101) changes the test in `devenv.nix` to `COLDLOGIC_DEVENV_SESSION` set, or `CLAUDECODE` set. If the two definitions differ after both land, a shell could skip the relink as a session while this script prints and installs as a terminal, or the reverse. → Decision 1 keeps this change's test in `in_session` alone. Whichever lands second makes `in_session` and #101's shared test the same condition, adds a marker case to `session-shell-test.sh`, and rewords any `CLAUDECODE` in these specs that #101 redefines. Until then both use `CLAUDECODE`, which every session sets, so they agree.
- **[No test runs the tasks]** The wiring in `devenv.nix` is checked by reading and running the generated scripts by hand (tasks 6.x) and by the manual checklist, not by the gate. → Each call site is a line or two; the branches are in the tested script.

## Migration Plan

None beyond the usual. Projects pick it up on their next lock bump. The settings' store path changes, so each checkout needs one terminal `devenv shell` and its sessions restarted, as the notice will say. Rollback is reverting the commit; the records under `.devenv/state/coldlogic-notices` are then ignored.

## Settled by Derek

- #67: remove the per-worktree `core.hooksPath` step now, relying on devenv's 2026-10-19 shared hook, and keep the install skip where the hooks directory can't be written. This replaces the first plan's fail-soft step. #97 stays separate.
- The hooks notice is silent when a hook exists; it reports only a hooks directory with no hook.
- Each notice once per session and checkout.
- The other tracking writers go to the tracking follow-up.
- A session-made worktree gets no `.claude/settings.json` and no notice that it is missing. The same reasoning covers `.mcp.json` and the OpenSpec skills.
- New logic goes in a tested script under `packages/`.
- #64 is superseded; its checks are this change's final manual section, to be filed as a follow-up issue.
- #65 and #97 are out of scope.

## Open Questions

- Should the shell unset a per-worktree `core.hooksPath` left by an earlier shell? This plan says no (decision 2). Derek asked for a recommendation and hasn't confirmed it.
- Can #97 close, now that nothing writes the hooks path?
- Is a task's stderr shown under `--quiet` when every task succeeds (task 6.3)? If not, no notice reaches a session once the shell is healthy, which is a separate problem from this change and older than it.
