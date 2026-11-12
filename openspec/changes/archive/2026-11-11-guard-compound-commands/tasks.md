# Tasks

Run the guard's cases with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed` and exits 0 when every case passes. A decision different from the one a task lists means the implementation differs from design.md: fix the code, not the expectation, or stop and ask. Each case below is a `BASH` entry `(command, expected)` against `POLICY`; `\n` is a newline in the Python string. Add each group's cases under its own comment heading, before `# Nothing to say: Claude Code's rules decide.`

## 1. Heredoc bodies are data in both readings (design decisions 3 and 4)

- [x] 1.1 In `lex()`, replace the per-command heredoc list read at a newline with a per-line list of pending heredocs (delimiter, quoted, strip-tabs, opening command), taken in order at the newline. Handle each body by the command that opened it, as today (shell: inner script; interpreter: unread script and mentions; unquoted: `quoted_text`; quoted: nothing). Verify every existing case still passes.
- [x] 1.2 In `rough_deny()`, drop each quoted heredoc's body before splitting, unless the line opening it has a word whose basename is in `SHELLS` or passes `interpreter()`, or `pipes_to_shell()` holds for that line. Verify existing cases still pass, `("echo '<<X'\nrm -rf build\nX", NONE)` and `("cat <<EOF | sh\ngit reset --hard\nEOF", DENY)` included.
- [x] 1.3 Add a `# Heredocs.` section with these cases and verify they pass:
  - `("devenv shell --quiet -- gh-app issue create --title x --body-file - <<'EOF' 2>&1 | grep 'https://'\nRun gh pr merge 55.\nEOF", ASK)` (the test `POLICY`'s `devenv shell *` rule makes the wrapper check ask; group 3 turns this to ALLOW; today it's DENY)
  - `("git status <<'EOF' && git push --force\nx\nEOF", DENY)`
  - `("git -c core.x=y commit -F - <<'EOF'\ngit push --force\nEOF", ASK)`
  - `("git -c core.x=y status; bash <<'EOF'\ngit push --force\nEOF", DENY)`
  - `("git -c core.x=y status; cat <<'EOF' | sh\ngit push --force\nEOF", DENY)`
  - `("git commit -F - <<'EOF'\nfix\nEOF\ngit push --force", DENY)`
  - `("git commit -F - <<'EOF'\nfix\nEOF\nrm -rf build", NONE)`
  - `("git commit -F - <<'EOF'\nfix", ASK)`
  - `("bash <<'EOF'\ngit status\nEOF", NONE)`
  - `("python3 - <<'EOF'\nprint(1)\nEOF", NONE)`

## 2. Shell function definitions ask (design decisions 3 and 4)

- [x] 2.1 In `lex()`/`unwrap()`, recognise `NAME()`, `NAME ()` and `function NAME` in command position, record the names in a new `Unwrapped.functions` set (merged by `add()`), and mark the call opaque. In `decide()`, skip `forbidden()` and `secret_named()` for a command whose program is a defined name, and after the deny checks return `("ask", "coldlogic guard: this call defines a shell function, which the guard can't follow.")` when `result.functions` is non-empty. In `rough_deny()`, skip segments whose first word is a name the text defines (`\b(NAME)\s*\(\s*\)` or `function\s+NAME`). Verify existing cases still pass.
- [x] 2.2 Add a `# Shell functions.` section and verify:
  - `("gh() { devenv shell --quiet -- gh-app \"$@\"; }\ngh pr merge 55 --auto --squash", ASK)`
  - `("gh() { devenv shell --quiet -- gh-app \"$@\"; }; gh pr view 1", ASK)`
  - `("function gh { gh-app \"$@\"; }; gh pr merge 1", ASK)`
  - `("gh () { gh-app \"$@\"; }; gh pr merge 1", ASK)`
  - `("f() { git push --force; }; f", DENY)`
  - `("f() { cat .env; }; f", DENY)`
  - `("f() { :; }; gh pr merge 1", DENY)`
  - `("gh() { gh-app \"$@\"; }; gh pr merge 1; echo 'unclosed", ASK)`

## 3. Sequences, pipelines, quoted heredocs and approved commands (design decisions 2, 5 and 6)

- [x] 3.1 Replace `simple_command()` with `plain_commands()` reading the grammar of design decision 2, without `for_loop` and without `$TMPDIR` or file redirects yet: `&&`/`||` (newlines after them allowed), `;`, newline, `|` (newlines after it allowed), a per-command `devenv shell [--quiet|-q] --` prefix, `fd_dup`, `[N]>`/`>>`/`&>` to `/dev/null`, `/dev/stdout` or `/dev/stderr`, and fully quoted heredoc delimiters whose bodies it skips per line as the shell does. Return `None` for everything design decision 2 rejects. Keep the `COMMIT_MESSAGE` stand-in as is.
- [x] 3.2 Add `approved(words)` (allow rule or `read_only()`, `plain_args()`, and not a `SHELLS` member or `interpreter()` with no script-file argument) and rewrite `decide()`'s allow check as in design decision 6. Delete `PIPE_FILTERS`. Move the wrapper check into a per-command loop: for each command the full reader unwrapped from `devenv shell`, ask when an allow rule matches that command's original words. To get them, have `plain_commands()` also return each command's words as written.
- [x] 3.3 Extend `read_only()` with `sort`, `uniq`, `jq` and `set` per design decision 5. Verify `("jq -n env", NONE)` and `("sort --compress-program=./evil x", NONE)` still pass.
- [x] 3.4 Add `"gh-app issue create *"`, `"gh-app issue view *"`, `"git branch *"` and `"git fetch *"` to the test file's `POLICY["allow"]`. Change these existing expectations, which this group's grammar turns into allows: `("cat <<'EOF'\nopen('.env').read()\nEOF", ALLOW)`, `("cat <<'EOF'\n$(rm -rf build)\nEOF", ALLOW)`, `("echo hi >&2", ALLOW)`, `("devenv shell --quiet -- cargo test 2>/dev/null", ALLOW)`, `("echo x > /dev/stderr", ALLOW)`, `("cat <<'EOF'\nopen(f, 'w') and sed -i are mentioned here\nEOF", ALLOW)`, and the group 1 heredoc-line case to ALLOW. Verify no other existing case changes.
- [x] 3.5 Add a `# Sequences and pipelines.` section and verify:
  - `("git status && git log -1", ALLOW)`
  - `("git worktree list; git branch -vv", ALLOW)`
  - `("git status\ngit log -1", ALLOW)`
  - `("git status || git log -1", ALLOW)`
  - `("git status;", ALLOW)`
  - `("git status &&\ngit log -1", ALLOW)`
  - `("ls -la && git status", ALLOW)`
  - `("git fetch origin && git log --oneline origin/main -3", ALLOW)`
  - `("git status && devenv shell --quiet -- scripts/check.sh", ALLOW)`
  - `("devenv shell --quiet -- gh-app issue view 36; devenv shell --quiet -- gh-app issue view 21", ALLOW)`
  - `("git status && rm -rf build", NONE)`
  - `("git status; git push -u origin feat", ASK)`
  - `("git status && devenv shell --quiet -- rm -rf build", ASK)`
  - `("git status && devenv shell -- cargo publish", DENY)`
  - `("git status && cat .env", DENY)`
  - `("git status && cat ~/.ssh/id_rsa", NONE)`
  - `("git branch -r | grep -v HEAD", ALLOW)`
  - `("git log --oneline | sort | uniq -c", ALLOW)`
  - `("git log | cut -d' ' -f1 | head", ALLOW)`
  - `("gh-app pr view 1 --json title | jq -r .title", ALLOW)`
  - `("git diff | gh-app issue create --title x --body-file -", ALLOW)`
  - `("git log | jq -n env", NONE)`
  - `("git log | jq '$ENV.GH_TOKEN'", NONE)`
  - `("git log | jq -f prog.jq", NONE)`
  - `("git log | jq -L lib 'import \"x\" as x; .'", NONE)`
  - `("git log | jq --rawfile x .dev.vars .", DENY)`
  - `("git log | sort -o out.txt", NONE)`
  - `("git log | sort --compress-program=./evil", NONE)`
  - `("git log | uniq - out.txt", NONE)`
  - `("git log | grep -r x .", NONE)`
  - `("git log | python3", NONE)`
  - `("git log | sh", NONE)`
  - `("set -o pipefail; devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW)`
  - `("set -euo pipefail; git status", ALLOW)`
  - `("set -- a b; git status", NONE)`
  - `("set -o noclobber; git status", NONE)`
  - `("git status 2>&1 >/dev/null", ALLOW)`
  - `("git log &>/dev/null", ALLOW)`
- [x] 3.6 Add to `# Heredocs.` and verify:
  - `("git commit -F - <<'EOF'\nfix: x\n\ngit push --force is quoted here\nEOF", ALLOW)`
  - `("devenv shell --quiet -- gh-app issue create --title x --body-file - <<'EOF'\nRun gh pr merge 55 --auto --squash.\nEOF", ALLOW)`
  - ``("gh-app issue create --title x --body-file - <<'EOF' | grep https\nUse `rm -rf` and $(x) and don't\nEOF", ALLOW)``
  - `("gh-app issue create --title x --body-file - <<\"EOF\"\nbody $(x)\nEOF", ALLOW)`
  - `("git commit -F - <<-'EOF'\n\tfix\n\tEOF", ALLOW)`
  - `("git commit -F - <<'EOF' && git log -1\nfix\nEOF", ALLOW)`
  - `("cat <<'A' <<'B'\nx\nA\ny\nB", ALLOW)`
  - `("git commit -F - <<EOF\nfix: x\nEOF", NONE)`
  - `("cat <<'EOF' | sh\ngit status\nEOF", NONE)`
- [x] 3.7 Add a `# Still not followed.` section and verify:
  - `("git status & git log", NONE)`
  - `("git status |& grep x", NONE)`
  - `("(git status; git log)", NONE)`
  - `("{ git status; git log; }", NONE)`
  - `("! git status", NONE)`
  - `("if git status; then git log; fi", NONE)`
  - `("git status && git log $(git rev-parse HEAD)", NONE)`
  - ``("git status && git log `git rev-parse HEAD`", NONE)``
  - `("git status && git log <(git diff)", NONE)`
  - `("git status && eval git log", NONE)`
  - `("git status && cd sub && git log", NONE)`
  - `("FOO=1 git status && git log", NONE)`
  - `("git status && git log -1 # note", NONE)`
  - `("git status && \\\ngit log", NONE)`
  - `("git status && git log $HOME", NONE)`
  - `("for i in 36 21; do devenv shell --quiet -- gh-app issue view $i; done", NONE)`
  - `("for b in a; do git status; done", NONE)`
  - `("for b in a; do git status; done && git log -1", NONE)`
  - `("while true; do git status; done", NONE)`
  - `("case x in x) git status;; esac", NONE)`

## 4. Scratch redirects and $TMPDIR (design decisions 2 and 3)

- [x] 4.1 In both readers, replace a leading `$TMPDIR` or `${TMPDIR}` in a word, quoted or not, with `os.environ.get("TMPDIR") or "/tmp"` without marking an expansion. `$TMPDIRX` and any other variable are unchanged. In `plain_commands()`, accept `>`, `>>`, `[N]>`, `[N]>>`, `&>`, `&>>` to a scratch word: an absolute path, or a `$TMPDIR` word. In `analyse()`, stop marking a command opaque for an output redirect whose target is a device or is not `project_file()` and passes `scratch()`. Verify every existing case still passes except the ones 4.2 changes, in particular `("echo x > .git/hooks/pre-commit", NONE)`, `("echo x > \"$OUT/a.rs\"", NONE)`, `("echo x >! \"$TMPDIR/out.txt\"", NONE)` and the tempfile blocks, where `guard.scratch` is mocked or the project itself sits under `$TMPDIR`.
- [x] 4.2 Change these existing expectations to ALLOW: `("git log > \"$TMPDIR/log.txt\"", …)`, `("echo x > \"$TMPDIR/body.md\"", …)`, `("echo x > ${TMPDIR}/body.md", …)`, `("echo x > /tmp/claude-501/scratch/x", …)`, `("echo x >> /private/tmp/claude-501/scratch/log", …)` and `("echo .dev.vars >> \"$TMPDIR/ignore\"", …)`. Verify no other existing case changes.
- [x] 4.3 Add a `# Redirects.` section and verify:
  - `("git log > \"$TMPDIR/log.txt\" 2>&1", ALLOW)`
  - `("git log >\"$TMPDIR/log.txt\"", ALLOW)`
  - `("git log 2>/dev/null | head -5", ALLOW)`
  - `("git log > $TMPDIR/x", ALLOW)`
  - `("git log >> ${TMPDIR}/x", ALLOW)`
  - `("git log > /private/tmp/claude-501/scratch/x", ALLOW)`
  - `("git log > \"$TMPDIR/../../../../../../../../etc/x\"", NONE)`
  - `("git log > \"$TMPDIR/x\" > out.txt", DENY)`
  - `("git log > ~/x", NONE)`
  - `("git log > \"$HOME/x\"", NONE)`
  - `("git log > \"$TMPDIRX/y\"", NONE)`
  - `("git log < README.md", NONE)`
  - `("git log <<< x", NONE)`
  - `("TMPDIR=. git log > \"$TMPDIR/x\"", NONE)`
  - `("git log >| \"$TMPDIR/x\"", NONE)`
  - `("gh-app issue create --title x --body-file \"$TMPDIR/body.md\"", ALLOW)`
- [x] 4.4 In the "Shell edits by absolute path" block, add `(f"echo x > {root}/src/a.rs 2>&1", "deny")` and `(f"git log > {root}/../elsewhere.txt", None)`, and verify they pass: a project under the temp directory is still the project.

## 5. The gate's exit status (design decision 7)

Loops are not unrolled (dropped from this change); they keep falling through, which 3.7's loop cases check.

- [x] 5.1 Have `plain_commands()` record, per command, whether its output is piped into the next stage. In `decide()`, after the rule checks and before the allow, when the strict reader reads the call: walk its commands in order, note a `set` whose options turn on `pipefail`, and deny a piped command whose program (after the `devenv shell --` prefix) is `scripts/check.sh` or ends in `/scripts/check.sh` when no such `set` came before it. The reason names `set -o pipefail; ...` and a redirect to `$TMPDIR`. (Review moved the check into `analyse()`: see 6a.2.)
- [x] 5.2 Change `("devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW)` to DENY (the one allow-to-deny change). Add a `# The gate's status.` section and verify:
  - `("scripts/check.sh | tail -40", DENY)`
  - `("git status && devenv shell --quiet -- scripts/check.sh 2>&1 | grep FAIL", DENY)`
  - `("./scripts/check.sh 2>&1 | tail", DENY)`
  - `("set -euo pipefail; scripts/check.sh 2>&1 | tail -40", ALLOW)`
  - `("set -o pipefail\ndevenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW)`
  - `("scripts/check.sh | tail; set -o pipefail", DENY)`
  - `("devenv shell --quiet -- scripts/check.sh > \"$TMPDIR/check.log\" 2>&1", ALLOW)`
  - `("devenv shell --quiet -- scripts/check.sh 2>&1", ALLOW)`
  - `("git log | grep check.sh", ALLOW)`

## 6. Allow rules, docs and spec

- [x] 6.1 In `devenv.nix`, add `"git fetch *"` and `"git rev-list *"` after `"git worktree *"`, `"gh-app pr list *"` and `"gh-app pr comment *"` after `"gh-app pr checks *"`, and `"gh-app issue view *"`, `"gh-app issue list *"`, `"gh-app issue comment *"` and `"gh-app issue edit *"` after `"gh-app issue create *"`. Run `devenv shell --quiet -- nixfmt devenv.nix` and verify `devenv --profile developer eval claude.code.permissions.rules.Bash.allow` lists all eight.
- [x] 6.2 Update the module docstring at the top of `claude-guard.py` (the allow bullet) and the `packages/claude-guard.py` row of `README.md`: a call is allowed when every command of its sequences and pipelines is approved; quoted heredoc bodies are data; scratch and device redirects are fine; loops still get no allow; a shell function definition asks; piping the gate is denied unless `set -o pipefail` comes first. Add the new rules to the README's allow-rule list if it has one. Verify by reading the rows back.
- [x] 6.3 Run `devenv shell --quiet -- openspec validate guard-compound-commands --strict` and verify it reports the change valid.

## 6a. Review fixes

- [x] 6a.1 `plain_args()` refuses git options that run a program (`--upload-pack`, `--receive-pack`, `--exec` and their abbreviations, `ext::`/`fd::` URLs, fetch `-u`) and options that wait for an editor or a prompt (`--edit-description`, `--interactive`, commit `-e`/`-c`/`-p`/`--edit`/`--reedit-message`/`--patch`, add `-i`/`-e`/`-p`/`--edit`/`--patch`, gh/gh-app `-e`/`--editor`/`--edit`). `read_only()` refuses `tail` that follows and `uniq --`. Cases in "Options that run a program, or wait for a user who isn't there".
- [x] 6a.2 The gate check moves from the strict reader to `analyse()` (design decision 7), with pipefail counted only as a top-level, unpiped, unwrapped `set` after the start, `;` or a newline and before any compound command; any other pipefail mention turns it off. Cases in "pipefail counts only where the calling shell is sure to set it first" and "The gate piped in a call the strict reader doesn't read".
- [x] 6a.3 A heredoc body's reader is found through its own pipeline (design decision 3); `pipes_to_shell(text)` goes. `rough_deny()` keeps bodies whose line ends in a pipe or names `eval`/`source`/`xargs`/`exec`, and every body when a group closer is piped. Cases in "What reads a heredoc body is found through its pipeline".
- [x] 6a.4 `Command.heredocs` goes; `redirects` and `writes` derive from `redirect_ops`.
- [x] 6a.5 The commit-message stand-in applies per command of a `&&`/`;`/newline chain. Cases in "A heredoc commit message in a chain".

## 6b. Second review fixes

- [x] 6b.1 Every rule (deny, ask, allow) is matched against each command of a chain as written, wrapper included, and unwrapped; a rule spelled with the wrapper also stands for its inner command (design decision 5, `Unwrapped.written`, `inner_rules()`). Cases in the policy block.
- [x] 6b.2 `git fetch` asks for `-f`/`--force`, `-u`/`--update-head-ok`, `-p`/`--prune`, `-P`/`--prune-tags`, `--refmap`, a `+` refspec and a `:` refspec after the remote; the `-u` reasoning is corrected (it is `--update-head-ok`). Changes `("git fetch --update-head-ok origin", ALLOW)` to ASK. Cases in "A fetch that can drop local work or refs asks".
- [x] 6b.3 A heredoc or here-string body read by anything not a known data consumer is scanned for denies as a script, its strings read roughly too (design decision 3); the rough reading drops a body only when its line reads it as data (design decision 4). Changes `("python3 - <<'EOF'\n$(git push --force)\nEOF", NONE)` to DENY. Cases in "A body something other than a known data consumer reads", "Here-strings are bodies too" and "The same in a call only the rough reading reads".
- [x] 6b.4 The gate followed by `||`, `;`, a newline or `&` and another command is denied, and so is the gate run through a shell in a pipe (design decision 7). Cases in "Only `&& ...` may follow the gate".
- [x] 6b.5 `git commit` without a message (`-m`, `-F`, `-C`, `--no-edit`, a plain `--fixup`), `--fixup=reword:`/`amend:`, gh `--edit-last` and gh issue/pr create or comment without a body ask (design decision 5; the `-o` narrowing here is reverted in 6c.2). Cases in "Editors gh and git open for a message they aren't given" and the policy block.
- [x] 6b.6 `sort` and `uniq` are read-only only with listed options (`listed_options()`), so `sort --files0-from`/`--random-source` get no allow; `grep -f`/`--file`/`--exclude-from` get no allow (design decision 5). Cases in "sort and uniq take only listed options" and "grep -f reads its patterns from a file".

## 6c. Third review fixes

- [x] 6c.1 The operator after a subshell's `)` counts for the gate inside it (`Command.closed_by`), and the gate inside a command or process substitution is denied (`Substitution`, design decision 7). Cases in "What follows a subshell's `)` follows the gate inside it".
- [x] 6c.2 `-o`, alone or in a cluster, is refused for every program but `grep`, `egrep`, `fgrep`, `rg` and `set` (`HARMLESS_O`, design decision 5), so `ssh -o ProxyCommand=sh`, `unzip -o` and `7z x -oout` ask under an allow rule. Cases in "-o is refused except where it is known to name no file or program" and the policy block.
- [x] 6c.3 Every long option git refuses or denies matches any prefix down to `--` and one letter (`git_option()`: `fetch --fo`, `push --m`, `reset --h`, `commit --e`); `tail --retry` down to `--r` (design decision 5). Cases in "git takes any unique prefix of a long option".
- [x] 6c.4 A `tee` whose every target passes `safe_redirect()` is a known data consumer, so its body isn't scanned (design decision 3). Cases in "A tee whose every target is scratch takes its body as data".
- [x] 6c.5 Deliberate spellings that feed a shell (process substitution, compound stages, `$(cat <<EOF)`) and a dummy function in a subshell are listed as known limits in the design's Risks; not fixed.

No existing case changed its expected decision in 6c.

## 6d. Fourth review fixes

- [x] 6d.1 For git, only a word starting `-o` is `-o`, and `commit`/`fetch` short clusters stop at a letter that takes a value (`git_short()`), so `git status -uno`, `git log -Sfoo`/`-Gfoo` and `git commit -mdocs:x` are approved as on main (design decision 5). Cases in "git's short options take their value in the word".
- [x] 6d.2 Only operators at the gate's nesting level count (`nesting()`): a compound command after `&&`, and the gate's own group closing, don't hide its status (design decision 7). Cases in "Operators inside a compound command `&&` leads to".
- [x] 6d.3 The rough reading takes `$TMPDIR`/`${TMPDIR}` opening a word as its value, so a tee to scratch reads as a data consumer there too (design decision 3). Cases in "The same in a call only the rough reading reads".
- [x] 6d.4 An unquoted `~` is plain inside a git revision (`REVISION`); `^` isn't, as a zsh glob operator (design decision 5). Changes `("git diff HEAD~1", NONE)` to ALLOW. Cases in "A revision's `~` is plain".
- [x] 6d.5 The spec and README list every `HARMLESS_O` program; the README and the module docstring describe the gate's nesting and substitution rules.

## 6e. Fifth review fixes

- [x] 6e.1 Only an unquoted `~` needs a revision; a quoted `~` stays plain as on main (`git commit -m "use ~/.cache"`, `git log --grep='a~b'`) (design decision 5). Cases in "A quoted `~` is just a character".
- [x] 6e.2 `git fetch` skips the separate value of `--filter`, `--server-option`, `--depth`, `--deepen`, `--shallow-since`, `--shallow-exclude`, `--negotiation-tip`, `--jobs` (full names) and a cluster ending in `-j`/`-o` when collecting operands, so `git fetch origin --filter blob:none` is approved (design decision 5). Cases in "A fetch option's value in the next word".

## 6f. Sixth review fixes

- [x] 6f.1 A word starting `-o` is refused for every program but `HARMLESS_O`; an `o` later in a cluster only for `O_CLUSTER` (`unzip`, `7z`, `ssh`, `scp`, `sftp`, `curl`, `wget`, `cc`, `gcc`, `clang`, `sort`, `mount`), so `ls -lo`, `wc -lo` and go's `-count=1 -timeout` are approved as on main (design decision 5). Cases in "Elsewhere an `o` later in the word".
- [x] 6f.2 A `&` at the gate's level backgrounds it and is denied, last or not (`scripts/check.sh &`, `scripts/check.sh && git status &`); the deny message names it (design decision 7). Cases in "A trailing `&` at the gate's level".

## 6g. Seventh review fixes

- [x] 6g.1 Only a pipeline the gate, or a group or subshell holding it, is a stage of counts as piping it (`in_pipeline()`), and `(scripts/check.sh;)` takes the operator after its `)` (`leads_on()`) (design decision 7). Cases in "Only a pipeline the gate ... is a stage of counts".
- [x] 6g.2 `-F-`, `--file=-` and `--body-file=-` read stdin as data, as `-F -` does (design decision 3). Cases in "The attached and `=` spellings read stdin too".
- [x] 6g.3 The word after git's or gh's `-m`, `--message`, `-b`, `--body`, `-t` or `--title` is text: the `-o`, `git_runs_program()` and gh `-e` checks skip it (design decision 5). Cases in "A message, title or body is text".
- [x] 6g.4 `expand_braces()` keeps an empty word, so `echo ''` and `git commit -m ''` read alike in both readers (design decision 5). Cases in "An empty word is kept".
- [x] 6g.5 Text options are keyed on (program, subcommand, option) (`text_options_of()`), and a word that could make git run a program (`-c`, `--config`, `--config-env`, `--upload-pack`, `--receive-pack`, `--exec`) is checked even as text (design decision 5). Cases: `git fetch -t --upload-pack=x origin`, `git fetch -m ...`, `git push -t --receive-pack=x origin`, `git commit -m --upload-pack=x`, `git commit -m -cfoo`, `git log -m -o x`, `git tag --message -o v1` and `gh-app pr checks -t -e` ask; `git tag -m "-o x" v1` and `gh-app pr create -t "-e x" -b y` stay allowed.
- [x] 6g.6 `git tag -e`/`--edit` asks, and so does an annotated or signed tag (`-a`, `-s`, `-u`, `--annotate`, `--sign`, `--local-user`) without `-m`, `-F`, `--message` or `--file` (`git_runs_program()`, `git_waits_or_drops()`, design decision 5's `git tag` entry). Cases in "A tag opens an editor".
- [x] 6g.7 stash's `-m`/`--message` is text only for a bare stash, `push`, `save` or an option right after `stash`, and notes' only for `add` and `append`; a word starting `-o` or `--output` with no whitespace is checked even as text (design decision 5). Cases in "stash's -m is a message only for push, save or a bare stash" and "A word that could name an output file is checked even as text".
- [x] 6g.8 A `&` ending the gate backgrounds it at any depth: `lex()` hands the operator after `(a;)`'s `)` to the last command only when `;` or a newline ended it, and `hides_status()` denies a gate `&` ended (design decision 7). Cases in "A `&` ending the gate backgrounds it at any depth".
- [x] 6g.9 `nesting()` keeps a stack of openers, pushing each one in command position (`openers()`: at a command's start, after `then`, `do`, `else`, `elif`, `!`, `time` or another opener) and popping on each closer (design decision 7). Cases in "An opener after a reserved word or another opener nests too".
- [x] 6g.10 `lex()` no longer returns the unused grouped-pipe flag.

## 7. Integration check

- [x] 7.1 Verify the guard package builds, which runs the cases (`packages/claude-guard.nix`): `devenv shell --quiet -- true` succeeds without a `coldlogic-claude-guard` build failure.
- [ ] 7.2 (Manual, after merge and Derek's terminal `devenv shell`.) In a fresh session, run each as its own Bash call and verify none prompts: `git status && git log -1`, `git branch -r | grep -v HEAD`, `devenv shell --quiet -- gh-app issue view 72 2>&1 | head -20`, `git log -3 > "$TMPDIR/log.txt"`, `set -o pipefail; devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`, and a `gh-app issue create --body-file - <<'EOF'` with a body quoting `gh pr merge 1` against a throwaway issue the session then closes. Note any prompt with the exact command in the PR.

## Workflow follow-up

- Open the PR with `Closes #72`, `Closes #61` and `Closes #43`, and enable auto-merge.
- Archive the change after review and the integration check.
