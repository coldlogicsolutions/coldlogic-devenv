# Tasks

## 1. Safe writes in the prune

- [x] 1.1 In `packages/prune-worktrees.sh`, add `own_file`, `make_new`, `open_log`, `touch_stamp` and `replace_file` (design.md, decisions 1-4). Open the log once on `log_fd` before any `say`, failing closed (one stderr line, no removal) when it can't be used, with `say` opening it again when the path no longer names the open file (and falling back to `/dev/null`, reported by `log_line`, if that fails); send the detached run's output to `log_fd`. Read the kept file only when `own_file`; trim the log only when this run opened it. Write the lock's `pid` with noclobber. Verify that `grep -n 'tmp\.\$\$\|touch --\|>>"\$log"\|>&"\$log_fd"\|{log_fd}>/dev/null'` finds only the checked open, the descriptor's uses and the fallback.
- [x] 1.2 Quote every path, branch, ref, git error and lock owner in a log line with `q` (decision 5). Verify by listing every `keep`/`say` call that interpolates a variable.
- [x] 1.3 Update the header comment.

## 2. Tests

- [x] 2.1 In `packages/prune-worktrees-test.sh`: (h3) a kept worktree and a branch with no worktree whose names hold `$( )` or a backquote are logged quoted, and no log line has an unquoted `$(` or backquote; (K) a symlinked log, for a run and a `--background` run: pruned, quiet, target unchanged, log still the link, no temporary file left; (K2) dangling links for log, stamp and kept file make nothing; (K3) a hard-linked log; (K4) a FIFO or directory log, under a timeout; (K5) a kept file linked to a secret, with a run skipped for an old lock; (K6) no `.tmp.$$` in the script. Update (u2e) for the quoted `feat\]x`.
- [x] 2.2 Run `shellcheck` on both files and the gate, `devenv shell --quiet -- scripts/check.sh`, and verify both pass.

## 3. Sandbox finding

- [x] 3.1 Read-only: check which `.git` paths a session can write (design.md, "Sandbox finding"), without writing into a real `.git`.
- [x] 3.2 Follow-up for Derek: decide on the `config.worktree` hole (design.md) and file it as an issue. The narrow deny, `${mainCheckout}/.git/worktrees/*/config.worktree`, needs `coldlogic:worktree-hooks-path` to stop writing that file from a session first. Filed as coldlogic-devenv#97.

## 4. Review fixes

- [x] 4.1 Read the lock's `pid` only when `own_file`; otherwise the owner is unknown (design.md, decision 3). Test (K7): a `pid` linked to a file naming a live process, with an old lock (taken over, nothing logged, lock released) and a fresh one (kept, left).
- [x] 4.2 `replace_file` drains stdin on every failure, and its pipelines end in `|| true` (decision 2). Test (K8): `mktemp` stubbed to fail, a log of 1500 long lines: exit 0, prunes, logs, untrimmed, no temporary file.
- [x] 4.3 `own_file` and `mtime` fell back to BSD `stat -f`; removed in 5.4, since coreutils is in `runtimeInputs` and the script needs GNU `mv -fT` and `realpath -m` anyway (test K10 removed with them).
- [x] 4.4 The stamp is replaced through `replace_file`, not touched (decision 4). Test (K9): stamp and kept file hard-linked to another file, whose content and time stay.
- [x] 4.5 Record the inherited log descriptor and the eager log in design.md's Risks.
- [x] 4.6 Tests: `stop_live` in the exit trap ends a stand-in owner whatever fails, and `wait_until` fails with a message when a 30-second poll times out.

## 5. Final review fixes

- [x] 5.1 Fail closed: `open_log` fails for an unusable log, and the run (a `--background` one before it detaches) prints one line to stderr and removes nothing; a dry run is unchanged. Spec scenario "A log that can't be used"; tests K, K2, K2b, K3, K4 expect no removals.
- [x] 5.2 `say` opens the log again when the path no longer names the open descriptor (`-ef /dev/fd/N`), with the same checks (design.md, decision 1). Test K11: the log replaced mid-run.
- [x] 5.3 Proposal: the stamp is replaced by a renamed `mktemp` file, not touched with `touch -h`.
- [x] 5.4 Remove the BSD `stat -f` fallbacks in `mtime()`, `own_file()` and `device()` and test K10; reasons in design.md and 4.3.
- [x] 5.5 `touch_stamp` writes the stamp with `mktemp` and `mv -fT`, not `replace_file`'s stdin copy.
- [x] 5.6 Git errors and lock owners go through `clean` (control characters to spaces, `$(` and backquotes defused) instead of `%q`; paths, branches and refs keep `%q`. Test K12; design.md decision 5 notes the one-time extra log lines.
- [x] 5.7 Test K, `--background` with a link as the log: no detached run starts (exit 0, one stderr line, the worktree kept after a pause, no lock, the target untouched). Its output can't reach the link, since nothing is detached; the earlier repeated `untouched` check is gone.

## 6. Second review fixes

- [x] 6.1 Write each "removing ...; to restore: ..." / "deleting branch ..." line before the worktree removal and the branch deletion (`intend`); when it can't be written, skip the removal and keep it for the next run. Spec scenario "The log unusable just before a removal"; test K13 (the log made a hard link at the pre-removal recheck); K11 also checks the intent line.
- [x] 6.2 Design.md decision 1: both ways of trimming have a window between read and rewrite; accepted as rare and recorded in Risks. No code change.
- [x] 6.3 Read the stamp's mtime only when `own_file` (the fast path and the full run; `own_file` moved above the fast path), so a link counts as no stamp. Test K14; spec scenario "The stamp a link".
- [x] 6.4 The unusable-log stderr line names the log path and says to remove or fix it.
- [x] 6.5 Docs: proposal.md (`clean` for free text, `%q` for names, the intent line), task 1.1, README.md's prune-worktrees row.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges.
