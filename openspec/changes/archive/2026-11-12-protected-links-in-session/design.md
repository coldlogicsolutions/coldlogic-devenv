# Design

## Context

See proposal.md for the motivation. This section holds what was checked, and what is assumed.

**Checked, in devenv at the locked rev** (`devenv.lock`: `9655d320`, `src/modules/files.nix`, and the generated scripts named in this worktree's `$DEVENV_TASK_FILE`):

- `devenv:files`' script is one block per file. For a link it runs `ln -sf <target> <name>` when `readlink` differs from the target (files.nix:110-128), and `ln -s` when nothing is there. It then writes `{"managedFiles": [...]}` to `<state>/files.json`.
- `devenv:files:cleanup` reads that state and `rm`s each recorded entry that isn't an exact string among the current names, if it is a link into `/nix/store` (files.nix:203-246).
- The script builders (`createSymlinkScript`, `cleanupScript`, `saveStateScript`) are `let` bindings. The module exposes only `options.files`, `lib.fileSpecType` and `lib.fileCopyModeType`. There is no option to exclude a file from the task, and no per-file hook.
- A task's `exec` is `types.nullOr types.str` (`tasks.nix`). Two definitions don't merge, so it can only be replaced whole, with `lib.mkForce`. `status` is the same type. A status that exits 0 skips the task and counts it as succeeded.
- Each file has `file` (its store path) and `copyMode` (`symlink`, the default, or `seed` or `copy`), both readable from `config.files.<name>`.
- The generated files in this repository's shell are `.mcp.json`, `.pre-commit-config.yaml` and the absolute settings path. No file in the module, the profiles or the fixtures sets `copyMode`.
- `devenv:git-hooks:install`, `coldlogic:plugins-installed` and `coldlogic:generated-files-stale` are ordered `after` `devenv:files`. `devenv:files` is `after` `devenv:files:cleanup`.

**Checked, in this repository:**

- `devenv.nix:51-82` builds `protectedFiles` (the settings path and `.mcp.json`), `sessionRelink` and `sessionStatus`. `devenv.nix:521-534` sets both tasks' statuses: in a session a task runs only when `coldlogic-session-relink` exits 1.
- `packages/session-relink.sh` never removes a link at a path it is given. It links at a temporary name and renames. The only `rm` calls are on its own temporary links.
- In this fresh worktree, in a session: the status's relink created `.mcp.json`, the sandbox refused `.claude/settings.json`, so `devenv:files` was skipped, `.pre-commit-config.yaml` was never linked, `devenv:git-hooks:install` failed and `devenv:enterShell` was skipped as a failed dependency. That is #78.

**Assumed, not checked:**

- Which mechanism removes the link in #94. The issue's isolation experiment shows only that another session in the checkout does it.
- That the sandbox lets a session create `.pre-commit-config.yaml` at a worktree's top. It let it create `.mcp.json` there, and the sandbox's write list covers the worktree.
- How Claude Code reacts to a settings link that changes while a session runs (#68).
- Whether devenv's evaluation cache keys on environment variables read with `builtins.getEnv`. This only matters to a rejected alternative.

## Goals / Non-Goals

**Goals:**

- In a session, nothing devenv ships can remove or replace a generated link. This holds without depending on any check being right.
- In a session, nothing of ours writes the settings link either. Only a terminal shell refreshes it.
- In a session, every other generated link the sandbox allows is created or updated, so a fresh worktree gets `.pre-commit-config.yaml`.
- The notice tells a developer what to do about the case #94 found: other sessions in the checkout.

**Non-Goals:**

- Making `enterShell` run in a fresh worktree. `.pre-commit-config.yaml` is one of its blockers; `core.hooksPath` (#67) and the OpenSpec skills are others, and they belong to #93 group 2.
- Printing the notice only once. Also #93 group 2.
- Stopping Claude Code from removing a settings path, if it does.
- Changing what a terminal shell does.
- A test that runs the tasks. Derek decided against a gate fixture step for that.

## Decisions

### 1. In a session, devenv's two file tasks never run

Both statuses become a single test: in a session exit 0 (skip), outside exit 1 (run). No call to the relink script, no state check.

Today the status asks "are the links current?" and lets `devenv:files` run if so, trusting it to find nothing to do. Every path to a deletion goes through that trust: a link that changes between the status and the exec, a case the check judges wrongly, or a devenv update that changes when the script relinks. Removing the decision removes them all. It also removes `sessionStatus`' fail-open handling, since nothing is left to fail.

*Rejected: replace `devenv:files`' exec with `lib.mkForce`, skipping the protected names in a session.* The original script text can't be reused: its builders aren't exposed, and a forced `exec` replaces the script outside a session too. We would own a copy of devenv's linking, state and copy-mode logic for every terminal shell in every project, and it would drift from devenv on each update. A session-only task carries the same logic for sessions only, and it is the relink script we already have.

*Rejected: drop the protected names from `config.files` in a session.* `CLAUDECODE` would have to be read at evaluation time, so a terminal and a session would need different evaluations, and whether the evaluation cache keeps them apart is unchecked. Worse, cleanup's list of current names would then lack the protected files, so it would treat the recorded `.mcp.json` as an orphan and remove the live link. That is the exact failure this change is for.

*Rejected: call `files.nix` a second time with a `config` holding only the unprotected files, and run the script it returns.* It reuses devenv's code, but it depends on that file's arguments and return shape, which are internal. It keeps `ln -sf`, which is wrong for any path the sandbox protects that isn't on our list (see decision 3). And the script would rewrite the state without the protected files.

*Rejected: keep the status gate and add a task that links the unprotected files when `devenv:files` is skipped.* It fixes #78 and leaves #94's gap between status and exec in place.

### 2. Cleanup is skipped in a session, always

The archived `settings-relink-atomic` design rejected this because `devenv:files` would then rewrite the state without the orphans, and no later shell would remove them. That no longer applies: `devenv:files` doesn't run in a session either, so the state stays as the last terminal shell left it, and the next terminal shell's cleanup removes the orphans.

So the `--state` option, the `respells` helper and their tests go. They decided when cleanup was safe to run in a session, and that question is closed. Leaving them would be untested-in-use code that reads as if cleanup could still run there.

### 3. The session links every symlink-mode file but the settings, through the atomic relink

A new task, `coldlogic:session-files`, runs `coldlogic-session-relink` with every file in `config.files` whose `copyMode` is `symlink`, except `config.claude.code.settingsPath`, each with its store path. In a session only. It never fails.

There are two sets, both derived from `config.files`. `generatedLinks` is every symlink-mode file: the notice compares all of them. `sessionLinks` is `generatedLinks` without the settings path: the task links these.

**The settings link is left out (Derek's decision).** A session never creates, replaces, renames or removes `.claude/settings.json`, and since the script is never given that path in relink mode, it never makes or sweeps a temporary link beside it either. The reason is mechanism (b): if Claude Code removes a settings file that changes under a running session, then a session's own relink, where the sandbox allows it, could be the trigger. Leaving it out costs the case where a session with the sandbox off fixed its own settings link. It now waits for a terminal shell, and the notice says so.

There is no list of protected files beyond that one name. A list is a guess about the sandbox, and the guess is already incomplete: Claude Code also denies writes under `.claude/commands`, `.claude/agents`, `.claude/hooks` and `.claude/skills`, and a project can generate links there. The atomic relink is safe on any path. Where the sandbox allows the write, the link is updated. Where it denies it, the old link stays. Using it for every file means #68's rule (never `ln -sf` over a protected path) holds without knowing which paths are protected.

The script already continues past a file it can't relink, so one refused file doesn't cost the others. That gets a test of its own, since #78 depends on every writable link appearing in a fresh worktree.

The task is ordered `after` `devenv:files:cleanup` and `before` `devenv:files`. Everything that waits for `devenv:files` therefore waits for the session's links as well, with no need to name those tasks. Because `devenv:files` now depends on it, the task must exit 0 whatever happens: a failure would skip `devenv:files` as a failed dependency and everything after it, which is #37.

*Rejected: do the linking in `devenv:files`' status, as today.* It works, and it is where the relink lives now. But a status with side effects is hard to see in the task list, and the session's linking deserves its own name there.

*Rejected: also leave `.mcp.json` out.* The sandbox lets a session write it, a fresh worktree needs it, and Claude Code hasn't been seen removing it: in #94 it stayed while the settings link vanished.

### 4. Copy-mode and seed-mode files are left to a terminal shell

The session task handles `symlink` mode only. devenv's copy script removes a store link before copying over it, which is the same unlink-then-create shape as `ln -sf`, so it can't be run as it is, and writing our own would mean owning that logic. Nothing in this module uses those modes. A project that does keeps the copy it has until the next terminal shell.

### 5. `--print` says missing, stale or conflict

`--print` prints one line per file that isn't current: `missing <path>` when nothing is at the path, `conflict <path>` when something that isn't a link is (a real file or directory, which is never touched), and `stale <path>` otherwise (a link to something else, a dangling link included). The kind is taken before any relink attempt, and a failed attempt leaves the path as it was, so it is still true when printed. A conflict counts as not current, so the script exits 0 for it.

The notice needs the split because the two cases differ for the reader. A stale link means the session runs on older settings. A missing one means it has none. The split lives in the script so the build-time test covers it; the notice only formats it.

*Rejected: let the notice task test each path itself.* It would be untested shell in `devenv.nix`.

### 6. The notice

One `echo`, built in one place. Its text:

> coldlogic: this Claude Code session can't refresh these generated files (missing: A B; out of date: C). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell. Then restart every Claude Code session open in this checkout, this one included, since a running session can undo the refresh. If a terminal shell doesn't fix them, its evaluation may be stale: run devenv shell --refresh-eval-cache there.

A group with no files is left out. Conflicts get a third group, `not links, move them aside first: ...`, and any line of a kind the notice doesn't know a fourth, `other: ...`, listed as printed, so a new kind can't silence the notice. Each path is shell-quoted (`printf %q`), so a path with a space stays one path. The notice compares every symlink-mode file (`generatedLinks`), the settings link included, though the session doesn't write that one. Restarting this session too is Derek's decision: #68 found that a session which had seen the link vanish needed a restart before a new link survived.

## Risks / Trade-offs

- **[The deletion is Claude Code's, not devenv's]** If mechanism (b) is the real one, the link will still vanish. → This change makes that visible: once no session runs devenv's link step or writes the settings link itself, a link that still disappears can only be Claude Code's doing. The notice's restart advice is the workaround meanwhile. Task 5.1 is the experiment.
- **[A session can no longer fix its own settings link]** With the sandbox off, a session used to relink it. → It now reports it and waits for a terminal shell, which is what every sandboxed session already does.
- **[A session with a stale evaluation relinks a writable file back]** Where the sandbox allows the write (`.mcp.json`, `.pre-commit-config.yaml`), two shells with different evaluations each point the link at their own target. → The link is never missing, only out of date for one of them, and the notice says so. This already happens today through the status's relink.
- **[The new task fails and takes the shell with it]** → Its script ends in `exit 0`, guards `cd`, and ignores the relink's exit code and output. Task 3.2 checks the generated script by running it with the binary stubbed to fail.
- **[The state file goes stale in a session]** A link a session creates isn't recorded until a terminal shell runs `devenv:files`. If the file is dropped from the configuration before that, nothing removes the link. → It is a dangling link into the store, harmless, and it needs a file to be added and removed with no terminal shell in between.
- **[Orphans linger through a session]** Cleanup doesn't run, so a link whose file was removed from the configuration stays until a terminal shell. → Same as today whenever a link is stale.
- **[A real file in place of a link]** `devenv:files` printed "Conflicting file" for it, though the task's output isn't shown. → The session leaves it alone and the notice lists it as not a link (review fix), and a terminal shell still runs `devenv:files`.
- **[Copy-mode and seed-mode files are neither written nor reported in a session]** → No file in the module, the profiles or the fixtures uses those modes (`git grep copyMode`), so today this affects nothing; a project that adds one gets it at its next terminal shell (decision 4).
- **[A stale link to a directory is never updated in a session]** The script won't rename over a path that resolves to a directory, so a `source` file that is a directory stays stale and is reported. → Unchanged from today, and the module generates none.
- **[A project on an older devenv has no `copyMode`]** → The filter reads it with a default: `file.copyMode or "symlink"`.
- **[No test runs the tasks]** The statuses and the task wrapper are checked by reading and running the generated scripts by hand (tasks 3.1-3.3), not by the gate. → They are a few lines each, with no branches beyond the session test.

## Room for #93 group 2

- The session's linking is one task and the notice is another, each with one job. Warn-once can wrap the notice's single `echo` without touching the linking. This change adds no stamp or marker file that a warn-once design would have to work around.
- `coldlogic:worktree-hooks-path` (#67) and `coldlogic:openspec-files` aren't touched.
- After this change a fresh worktree has `.pre-commit-config.yaml`, so `devenv:git-hooks:install` gets as far as #67's `core.hooksPath` write. Group 2's fail-soft work starts from there, with one blocker fewer.
- The settings link is still missing in a fresh worktree, and the notice still prints on every shell there. Whether that is worth a notice in a throwaway worktree is group 2's call.

## Migration Plan

None. Projects pick it up on their next lock bump. A checkout whose link is already gone needs one terminal `devenv shell`, then a restart of the sessions open in it. Rollback is reverting the commit.

## Settled by Derek

- A session never writes the settings link (decision 3).
- The notice says to restart every session in the checkout, this one included (decision 6).
- Dropping `protectedFiles`, `--state` and `respells` is accepted (decisions 2 and 3).
- No upstream devenv issue about atomic link replacement.

## Open Questions

- Is the deletion in #94 Claude Code's own? Task 5.1 answers it after merge. Nothing in this change waits on the answer.
