# Proposal

## Why

The guard allows only one plain command, optionally piped into `tail`, `head`, `grep` or `wc`. Any chain (`&&`, `;`, newline), heredoc, scratch redirect or loop gets no decision and falls through to a prompt, even when every part is allowed on its own. Routine, allowed work keeps prompting Derek (#72, #43). The guard also denies allowed calls: a heredoc body that quotes a forbidden command is read as commands when the heredoc's command isn't last on its line, and calling a shell function named `gh` is judged as `gh` (#61).

## What Changes

- Approve a compound command when every part is approved on its own: each command of a `&&`, `||`, `;` or newline sequence and each stage of a `|` pipeline. Background `&`, subshells, groups, `!`, `|&`, command and process substitution, `eval`, `cd`, assignments, comments and anything the guard can't read still fall through, as now.
- Treat a quoted heredoc's body (`<<'EOF'`, `<<"EOF"`, `<<-'EOF'`) as data everywhere, including the rough reading used when a command can't be parsed. Bodies fed to a shell or interpreter are still checked. Fix the lexer bug that reads a body as commands when the command opening the heredoc isn't the last one on its line.
- Approve redirects to `/dev/null`, `/dev/stdout`, `/dev/stderr`, descriptor duplications (`2>&1`, `>&2`) and scratch files (`$TMPDIR/...`, `${TMPDIR}/...`, `/tmp`, `/private/tmp`, the session scratchpad). Writes into the project are still denied and pointed at Edit and Write; writes elsewhere still fall through.
- Count more read-only filters as approved commands: `sort`, `uniq` (no output operand) and `jq` (no environment, module or file-reading filters), next to today's `head`, `tail`, `grep`, `wc`, `cut`, `tr` and the rest of the read-only set.
- Approve `set -o pipefail` (and `set` with only `-e`, `-u`, `-x` and `-o pipefail`) as a sequence element, so `set -o pipefail; scripts/check.sh 2>&1 | tail -40` keeps the gate's exit status.
- Deny piping the gate (`scripts/check.sh`) into another command when no earlier `set` in the call turns on `pipefail`: the conventions forbid hiding its exit status. The message points at `set -o pipefail; ...` or a redirect to `$TMPDIR`.
- Loops (`for`, `while`, `until`, `select`) and `case` still fall through, as now.
- A command line that defines a shell function (`name()`, `function name`) gets no allow, and a call to that name asks instead of being judged as the program it shadows. The function's body is still checked.
- Add the read-only `gh-app issue view *`, `gh-app issue list *`, `gh-app pr list *`, `git fetch *` and `git rev-list *`, and the routine App writes `gh-app issue comment *`, `gh-app issue edit *` and `gh-app pr comment *`, to the module's allow rules (#72, #43).
- **BREAKING** (decision only): several cases that returned no decision now return allow, and `devenv shell --quiet -- cargo test 2>/dev/null` with a wrapper allow rule changes from ask to allow. One allowed case becomes a deny: the gate piped without `pipefail` (`devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: the allow requirement widens from one plain pipeline to sequences, pipelines, quoted heredocs, safe redirects and `set` options; heredoc bodies become data in every reading; shell function definitions ask; the gate piped without `pipefail` is denied.
- `session-permissions`: the routine allow rules gain `gh-app issue view|list|comment|edit`, `gh-app pr list|comment`, `git fetch` and `git rev-list`.

## Impact

- `packages/claude-guard.py`: the plain reader (`simple_command`) becomes a reader of the approved grammar, the lexer's heredoc handling, `$TMPDIR` words, scratch redirects, function definitions, `rough_deny`, `read_only` and `decide`'s allow check.
- `packages/claude-guard-test.py`: new cases, and the existing cases whose decision changes, listed in `tasks.md`.
- `devenv.nix`: eight allow rules.
- `README.md`: the guard and allow-rule rows.
- No new dependency: the guard stays a single `python3 -I` script tested at build time.
- Closes #72, #61 and #43.
