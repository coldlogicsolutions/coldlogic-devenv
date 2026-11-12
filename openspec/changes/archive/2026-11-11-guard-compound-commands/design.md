# Design

## Context

See proposal.md for why. The guard (`packages/claude-guard.py`) reads a Bash call twice:

- `lex()` / `analyse()` is the full reader. It lexes as bash and zsh would (Claude Code runs the user's shell, zsh here), splits on `;`, `&`, `|`, `&&`, `||` and newlines, unwraps wrappers, follows substitutions and heredocs fed to shells, and marks anything it can't vouch for as `opaque`. It drives every deny and ask.
- `simple_command()` is the strict reader. It accepts only plain words joined by `|`, with `2>&1`, behind an optional leading `devenv shell [--quiet] --`, and returns `None` for anything else.

`decide()` allows only when both readers agree on the command list, the full reading isn't opaque, the first command matches an allow rule or `read_only()`, and every later stage is `tail`/`head`/`grep`/`wc`. Two readers that must agree is the guard's main defence for its allow side: a lexer bug has to be repeated in the strict reader to turn into an allow.

Bugs found while probing the current guard (`decide()` called directly):

- `gh-app issue create --body-file - <<'EOF' 2>&1 | grep x` followed by a body quoting `gh pr merge 55` is **denied**. `lex()` attaches heredocs to the command that's current when the newline comes (`grep`), not to the one that opened them, so the body is lexed as commands. This is #61's second case.
- `gh() { ... gh-app "$@"; }` then `gh pr merge 55` is denied: the call is judged as `gh` (#61's first case).
- `rough_deny()`, used when the full reader raises `Unparsable`, splits the raw text, heredoc bodies included, so any unparsable call with a body quoting a forbidden command is denied.

## Goals / Non-Goals

**Goals:**

- Keep the two-reader structure and its agreement check; widen what both read, in step.
- No new dependency: the guard stays one `python3 -I` script whose cases gate its build.
- Every new allow is a composition of things that would each be allowed as their own call, plus scratch-only writes.

**Non-Goals:**

- Input redirects from files (`< file`), here-strings (`<<<`), loops (`for`, `while`, `until`, `select`), `case`, `if`, and any expansion besides `$TMPDIR`. Loops keep falling through; unrolling them was considered and dropped.
- Following shell functions. A call that defines one asks.
- Changing the canonical `git commit -m "$(cat <<'EOF' ...)"` handling (`COMMIT_MESSAGE`). It stays a whole-call special case; `git commit -F - <<'EOF'` is the form that works inside chains.
- Write-side `gh-app` commands beyond `issue comment`, `issue edit` and `pr comment` (decision 8).

## Decisions

### 1. Parser: keep the guard's own zsh-aware lexer and strict reader

Alternatives considered:

- **bashlex** (`python3Packages.bashlex`): a port of bash's grammar. It reads bash, not zsh, so the guard would still need its zsh rejections (`=cmd`, `>!`, glob qualifiers, `*(e:...:)`) on top. It has gaps (it rejects or misreads some valid constructs) and little maintenance.
- **tree-sitter-bash**: an error-tolerant grammar that returns a tree with `ERROR` nodes for input it doesn't understand. That suits an editor, not an allow decision. It also brings a native library into a hook that runs on every tool call.
- **`shfmt --to-json`** (mvdan/sh): a solid parser with a full JSON AST, but bash/POSIX/mksh only, a Go binary in the closure, a subprocess per call, and still no zsh.

The current lexer has been through seven reviews, knows zsh's differences, and already finds every simple command, operator, heredoc and redirect. The work here is in what's approved, not in parsing. Instead of a third-party parser, the strict reader becomes a small recursive-descent recognizer of exactly the grammar in decision 2. Bash and zsh read that grammar the same way, so the choice of shell doesn't matter for anything it accepts.

### 2. The approved grammar (strict reader)

`simple_command()` becomes `plain_commands(text)`, returning the list of simple commands (words, after `normalize_git`) or `None`:

```
call      := blank* item ( sep item )* sep? blank*
sep       := '&&' newline* | '||' newline* | ';' | newline
item      := pipeline
pipeline  := command ( '|' newline* command )*
command   := [ 'devenv' 'shell' ( '--quiet' | '-q' )? '--' ] word ( word | redirect )*
redirect  := fd_dup | [digit] ( '>' | '>>' ) target | '&>' target | '&>>' target | heredoc
fd_dup    := [digit] '>&' digit            -- 2>&1, >&2, 1>&2
target    := '/dev/null' | '/dev/stdout' | '/dev/stderr' | scratch_word
heredoc   := ( '<<' | '<<-' ) ( "'" NAME "'" | '"' NAME '"' )
word      := today's plain word: PLAIN characters, '...' and "..." with no $ ` \ inside,
             plus a leading $TMPDIR / ${TMPDIR} / "$TMPDIR..." / "${TMPDIR}..."
```

- The wrapper prefix is accepted per command, not only at the start of the call.
- Heredoc bodies: after each newline the reader takes the bodies of every heredoc opened on that line, in order, exactly as the shell does (closing line equal to the delimiter, leading tabs stripped only for `<<-`). An unterminated body returns `None`.
- `$TMPDIR` in a word is replaced, in both readers, by the hook's own `os.environ["TMPDIR"]` when set, else `/tmp`. A made-up stand-in wouldn't do: `scratch()` resolves paths, so the value has to be a real directory. Both are scratch roots by `scratch()`'s definition, and the sandbox gives sessions a `TMPDIR` under `/private/tmp` or `/var/folders`, so where the hook's and the session's values differ, both are still scratch.
- Rejected outright (return `None`): `&` alone, `|&`, `(`, `)`, `{`, `}`, `!` and reserved words in command position (`for`, `while`, `until`, `select`, `case` and `if` among them), `#`, backslash, backtick, any other `$`, `<`, `<<<`, `>|`, `>!`, `<>`, unquoted heredoc delimiters, an assignment word first, and a first word in `WRAPPERS | SHELLS` other than the `devenv shell --` prefix.
- The gate check (decision 7) reads the full reader's output, not this one's.
- **The commit-message stand-in** applies per command: each `git commit -m "$(cat <<'EOF' ... EOF)"` (behind `devenv shell --` or not) that stands as its own command, first in the call or after `&&`, `;` or a newline whose earlier text the strict reader reads, and is followed only by the end or another `&&`, `;` or newline, is replaced by `git commit -m message` in both readers' input. The commit itself matches exactly the pattern it did before; the first match that doesn't qualify stops the replacing.

### 3. The full reader: changes that keep it in step

- **Heredocs per line.** `lex()` keeps a per-line list of pending heredocs (delimiter, quoted, strip-tabs, and the command that opened it). At a newline it takes them in order. Each body is then judged by what reads it, found through the opener's own pipeline: `lex()` records for each command the operator that ended it, its `(` depth and the next stage, and a pipe after a group closer (`)`, `}`, `done`, `fi`, `esac`) records the stages it feeds. The opener is judged by its words (brace-expanded; a program word with `$`, a glob or `~` counts as a shell); every later stage, and every stage fed by a piped group, also by its unwrapped words. Any shell → the body is an inner script; any interpreter → the opener is unread and the body is its script; any stage that isn't all read-only programs, or is opaque → the opener is unread and the body stays data; otherwise the body is data. An unquoted delimiter gets the expansion check as before. A here-string (`<<<`) is a body of its own command, judged the same way. Separately from approval, a body that is not an inner script is scanned for denies unless every reader (the opener, its later stages, every stage fed by a piped group) is a known data consumer (`data_consumer()`: a read-only program, `git commit` or `git tag` with `-F -`/`-F-` (alone or ending a cluster)/`--file -`/`--file=-`, `gh`/`gh-app` with `--body-file -`, `--body-file=-`, `-F -` or `-F-`, or `tee` with only `-a`, `-i`, `-p` and their long forms whose every operand passes `safe_redirect()`, the same test as a `>` redirect, so prose copied to `$TMPDIR` isn't scanned; the rough reading's `line_reads_data()` replaces a `$TMPDIR` or `${TMPDIR}` opening a word with its value first, as the full reader does). The SHELLS and INTERPRETERS lists don't decide this, so `tcsh`, `pwsh`, `nu`, `php`, `lua`, `awk -f -`, `osascript`, `ssh` and `sqlite3` all count. `scan()` analyses such a body as a script (nothing if it doesn't lex) and also reads it, and each quoted string in it, roughly (`rough_words()`), since a script in another language runs commands from its strings (`system('git push -f')`). `decide()` runs `forbidden()`, deny rules and `shell_edit()` over both readings, and `secret_named()` over the parsed one only (a string in a Python body like `"no .env here"` is not a path). Ask rules and approval don't look at it. `pipes_to_shell(text)` goes: it scanned the whole call, bodies included, so a body that mentioned `curl x | sh` made every body commands. This fixes the deny in #61.
- **Dead state.** `Command.heredocs` goes; `redirects` and `writes` are derived from `redirect_ops`.
- **`$TMPDIR` words.** A `$TMPDIR` or `${TMPDIR}` at the start of a word, quoted or not, is replaced by the same value as in decision 2 and doesn't set `cmd.expands`. Any other `$` still does. `project_file()` keeps its current benefit of the doubt for other variables.
- **Scratch redirects aren't opaque.** `analyse()` marks a command opaque for a redirect unless it is an output redirect whose target is `/dev/null`, `/dev/stdout`, `/dev/stderr`, or is not `project_file()` and passes `scratch()` (which resolves `..` and symlinks). The `project_file()` test comes first because a project checked out under `/tmp` (the test fixtures are) would otherwise count as scratch. Writes stay in `result.writes`, so `shell_edit()` still denies a write into the project. Input redirects stay opaque.
- **Function definitions.** `lex()` recognises `NAME ( )` (with or without the space) and `function NAME` in command position and records the name in `Unwrapped.functions`; the call is opaque. `decide()` skips `forbidden()` and `secret_named()` for a command whose program is a defined name, and returns `("ask", "coldlogic guard: this call defines a shell function, which the guard can't follow")` when there is no deny. The body is lexed like any other commands, so a forbidden command in it is still denied.

### 4. `rough_deny()` reads around data

Before splitting, `rough_deny()` removes the body of each quoted heredoc only when every command on the line that opens it, read roughly with heredoc openers and redirects dropped, is a known data consumer (`line_reads_data()`, the same `data_consumer()` test as the full reader), and the line doesn't end in a pipe that continues after the body. A here-string's text is also checked as a command of its own. When a group closer (`)`, `}`, `done`, `fi`, `esac`) is piped anywhere in the text, every body is kept. It also drops segments whose first word is a function name defined in the text (same two spellings). Everything else stays as today: a rough reading can only add denies.

### 5. Approved commands

A command is approved when it matches an allow rule or is read-only, `plain_args()` passes, and it isn't an interpreter or shell reading its script from stdin. `read_only()` gains:

- `sort`: only listed options (`listed_options()`): `-n -r -u -f -b -h -V -s -z` alone or in a cluster, `-k` and `-t` with their value in the word or the next, and the exact long forms (`--numeric-sort` ... `--zero-terminated`, `--key`, `--field-separator`). Any other option gets no allow: `--files0-from` and `--random-source` read a file named only indirectly, and `-o`, `-T` and `--compress-program` write or run.
- `uniq`: only listed options (`-c -d -D -u -i -z`, `-f`/`-s`/`-w` with a value, and their long forms), at most one operand (the second is an output file), and no `--` (after it, `-x` is an operand).
- `grep` (already read-only): rejected with `-f` alone or in a cluster, `--file` and `--exclude-from`, which read patterns from a file the path check doesn't see as one read. `jq` (`-f`, `--from-file`, `-L` below), `tail`, `head` and `cut` have no option that reads files listed in a file; `jq --rawfile` and `--slurpfile` name their file outright, so the path check sees it.
- `tail` (already read-only): rejected when it follows a file (`-f`, `-F` or a cluster holding either, `--follow` and `--retry` and their abbreviations down to `--f` and `--r`), since it never exits.

`plain_args()` also refuses options that run a program or wait for an editor, so a command an allow rule names gets an ask with them:

- every git subcommand: `--upload-pack`, `--receive-pack`, `--exec`, `ext::` and `fd::` URLs, `--edit-description`, `--interactive`. `git -c` and `--config-env` (`core.sshCommand` and the like) were already refused as config overrides.
- Git abbreviations (`git_option()`): git's parser takes any unique prefix of a long option, one letter after `--` included (`git reset --h` is `--hard`, `git fetch --fo` is `--force`), and fails on an ambiguous one. So every long option git refuses or denies here (the ones below, and `push --force`/`--mirror` and `reset --hard` in `forbidden()`) matches any prefix of it from `--` plus one letter. That refuses some ambiguous prefixes too (`--u`), which git would reject anyway. The checks that grant something (a commit's `--message`, `--no-edit`) keep their longer minimums, which only errs towards asking.
- `git fetch` (`git_waits_or_drops()`), for what can drop local work or refs: `-f`/`--force`, `-u`/`--update-head-ok` (`-u` is that, not `--upload-pack`, which has no short form), `-p`/`--prune`, `-P`/`--prune-tags`, `--refmap`, short clusters holding any of `f`, `u`, `p`, `P` (`-qu`), any operand starting with `+`, and any operand after the first (the remote) holding `:`. The next word after an option that takes a separate value (`--filter`, `--server-option`, `--depth`, `--deepen`, `--shallow-since`, `--shallow-exclude`, `--negotiation-tip`, `--jobs`, spelled in full, or a short cluster ending in `-j` or `-o`) is that value, not an operand, so `git fetch origin --filter blob:none` isn't read as a refspec. An abbreviation leaves the next word an operand. `git fetch [remote] [branch]` stays allowed.
- `git commit`: `-e`, `-c`, `-p` alone or in a cluster, `--edit`, `--reedit-message`, `--patch`. `--no-edit` and `-C` stay. A commit given no message opens an editor, so it is refused unless it has `-m`, `-F` or `-C` (alone or ending a cluster, `-am`), `--message`, `--file`, `--no-edit`, `--reuse-message` or a plain `--fixup`: a bare `git commit` and a bare `--amend` ask. `--fixup=reword:` and `--fixup=amend:` (or with the value as the next word) open one too.
- `git tag`: `-e` alone or in a cluster, `--edit`. An annotated or signed tag (`-a`, `-s`, `-u` alone or in a cluster, `--annotate`, `--sign`, `--local-user`) opens an editor unless it has `-m` or `-F` (alone or in a cluster, `-am`), `--message` or `--file`; a plain `git tag v1`, `-l` and `-d` stay. The cluster checks stop at a letter that takes a value (`m F u n`), so `-ma` is a message.
- `git add`: `-i`, `-e`, `-p` alone or in a cluster, `--edit`, `--patch`.
- `gh` and `gh-app`: `-e`, any option starting `--edit` (`--editor`, `--edit`, `--edit-last`) and clusters holding `e`; and `issue create`, `pr create`, `issue comment` and `pr comment` given no body (`-b`, `--body`, `-F`, `--body-file`, or for `pr create` `-f`/`--fill*`).
- A word starting `-o` (`-o`, `-oProxyCommand=...`, `-oout`) is refused for every program but those where it is known to name no file or program (`HARMLESS_O`: `grep`, `egrep`, `fgrep`, `rg`, whose `-o` prints only the match, and `set`, which `set_options()` checks), so `grep -o` is approved while `ssh -o ProxyCommand=sh`, `unzip -o` and `7z x -oout` ask. Main refused only a bare `-o`; a list of programs whose `-o` writes would approve every program it forgot. An `o` later in a short cluster (`-qo`) is refused only for the programs where it writes, overwrites or takes a value that can run a program (`O_CLUSTER`: `unzip`, `7z`, `ssh`, `scp`, `sftp`, `curl`, `wget`, `cc`, `gcc`, `clang`, `sort`, `mount`). Elsewhere it is a harmless flag (`ls -lo`, `wc -lo`), another letter's value, or part of a single-dash long option (go's `-count=1`, `-timeout`), which a cluster rule would refuse. For git, whose short options take a value in the rest of the word (`status -uno`, `log -Sfoo`, `-Gfoo`, `commit -mdocs:x`), only a word starting `-o` is `-o`, and the cluster checks for `commit` and `fetch` (`git_short()`) stop at the first letter that takes a value (`commit`: `m F C c t S u`; `fetch`: `j o`), so `-mdocs` is a message, not `-c`. The word after a text option is text, so the `-o` check, `git_runs_program()` and gh's `-e` check skip it (`git commit -m "-o is refused"`, `gh-app issue comment 3 --body "-e is nice"`). Text options are keyed on the subcommand (`text_options_of()`), since the same letter means something else elsewhere (`git fetch -t` is `--tags`, `git log -m` takes no value, `gh pr checks -t` is a template): `-m`/`--message` for git's commit and merge, for notes only under `add` and `append`, and for stash only bare, under `push` or `save`, or with an option right after `stash` (`stash list` and `show` take log and diff options, where `-m` takes no value), `-m` alone for tag (`GIT_TEXT_OPTIONS`), and `-t`/`--title`/`-b`/`--body` for gh's issue and pr create, edit and comment (`GH_TEXT_OPTIONS`). A word that could make git run a program (starting `-c`, `--config`, `--config-env`, `--upload-pack`, `--receive-pack` or `--exec`) is checked even after a text option, so a skipped value never hides one (`git commit -m --upload-pack=x` asks), and so is a word starting `-o` or `--output` with no whitespace (`git commit -m -ofoo` asks, while the sentence `git commit -m "-o is refused"` stays text); a word with whitespace isn't skipped for that alone, as git parses `"--upload-pack=a b"` as an option. `expand_braces()` keeps an empty word (`''`, `""`), as the shell does, so both readers see `echo ''` and `git commit -m ''` alike.
- `~` (`PLAIN` lacks it) is taken unquoted only past a word's start and only in a word that is a git revision (`REVISION`: ref characters, `~N` ancestry, `..`/`...` ranges), so `git diff HEAD~1` and `git log HEAD~3..HEAD` are approved. A quoted `~` is just a character (`git commit -m "use ~/.cache"`, `--grep='a~b'`), as before. A `~` opening a word is home-directory expansion. Under zsh's EXTENDED_GLOB `a~b` matches files named `a` but not `b`, so such a word can only expand to a name it spells out. `^` is not taken: as a zsh glob operator (`HEAD^` matches `HEAD` followed by anything) it can expand to names the word doesn't spell; quoting it (`'HEAD^'`) is approved.
- `jq`: rejected when any argument contains `env` or `$ENV` (case-insensitive), `import` or `include`, or it has `-f`, `--from-file` or `-L`/`-L<dir>`. Data files it reads are checked like any other path argument (inside the project, not a secrets file).
- `set`: only `-o pipefail` and clusters of `e`, `u`, `x` (`-e`, `-eu`, `-euo pipefail`). It changes the calling shell, but only to fail sooner or louder.

`PIPE_FILTERS` goes away: every stage is judged by the same "approved" test, so `git log | gh-app pr create --body-file -` is approved when both are, and `git log | rm` is not.

The wrapper check moves into the per-command loop: if any command of a sequence was unwrapped from `devenv shell` and an allow rule matches it as written (`devenv shell --quiet -- rm -rf build` against `devenv shell *`), the guard asks, as it does today for a single command.

Every rule is matched against each command of the call in both spellings. `analyse()` records, for each command with a wrapper, its words as written, the commands it unwraps to and whether it is opaque (`Unwrapped.written`, merged across inner scripts). Deny and ask rules are matched against the whole text, every unwrapped command (and git with global options dropped) and every written command; `inner_rules()` adds the inner command of each rule spelled with the wrapper (`devenv shell --quiet -- gh-app issue create *` gives `gh-app issue create *`), so the rule catches the command however it is wrapped. An allow rule's inner form approves a command only where it was unwrapped from the wrapper. The final wrapper ask covers every written command, not just the first: one an allow rule matches as written asks when it is opaque or its inner commands aren't approved.

### 6. `decide()`'s allow check

```
plain = plain_commands(checked) if not away_from_root() else None
allow when plain is not None
       and plain == [w for w in commands]          # same simple commands, same order
       and not result.opaque and not result.functions
       and all(approved(w) for w in plain)
```

A loop's `for` still goes through `UNFOLLOWED` in the full reader, so a forbidden command in a loop body is denied as today, and the strict reader rejects the loop, so it gets no allow.

### 7. The gate's exit status

`scripts/check.sh 2>&1 | tail -40` loses the gate's status to `tail`, and the conventions forbid hiding it. The check runs in `analyse()` on the full reader's commands, so it covers every call that lexes: comments, expansions, `|&`, `$( )` and `bash -c` scripts, calls away from the project root and piped compound commands. `analyse()` walks the commands in order. A command runs the gate when its unwrapped program, or its words as written, is `scripts/check.sh` (or a path ending in `/scripts/check.sh`), or a shell, `source` or `.` whose script operand is (`bash scripts/check.sh`, `devenv shell -- sh -x scripts/check.sh`; `-o`/`+o` take a value). It is piped when its status goes into a pipe (`in_pipeline()`): the operator after it is `|` or `|&`, or a group or subshell holding it is a pipeline stage (`{ scripts/check.sh; } | tail`, `(git status; scripts/check.sh) | tail`, `for ...; do scripts/check.sh; done | tail`). It walks on from the gate with the levels `nesting()` gives: after a sequence operator (`;`, a newline, `&&`, `||`, `&`) at a level, pipes at that level or inside belong to another pipeline, until a closer takes the walk out a level. An earlier draft took any piped group in the call as piping the gate, which denied `scripts/check.sh && { echo a; } | cat` and a `{ git log -1; } | head -3` line before the gate. Piped with pipefail off, it sets `gate_piped`, and `decide()` denies with: `coldlogic guard: piping scripts/check.sh hides its exit status. Run it as set -o pipefail; ... | tail, or redirect it to "$TMPDIR/check.log" and read that.` This sits after the deny rule checks and before the ask and allow.

The call's status is also not the gate's when another command runs after it through `||`, `;`, a newline or `&` (`hides_status()`: a later command other than a lone `}`, `done`, `fi` or `esac`), or when a `&` at its level backgrounds the gate's list, last or not (`scripts/check.sh &`, `scripts/check.sh && git status &`): a background job's call exits 0. A `&` that ends the gate itself backgrounds it at any depth, whatever follows its subshell or group (`(scripts/check.sh &) && echo started`). Only operators at the gate's own nesting level count (`nesting()`: `(` depth plus a stack of the compound commands `{`, `if`, `while`, `until`, `for`, `case`, `select` open and `}`, `fi`, `done`, `esac` close). An opener counts wherever it is in command position (`openers()`): at a command's start, after `then`, `do`, `else`, `elif`, `!` or `time`, or after another opener, so `{ { scripts/check.sh; }; } | tail` and `if true; then if true; then scripts/check.sh; fi; fi | tail` are piped. Operators inside a compound command that `&&` leads to are skipped, since its status is the compound's (`scripts/check.sh && { echo a; echo b; }`, `... && if ...; then ...; fi`); when the gate's `;` is followed by the closer of its own group, the group's status is the gate's and the check moves out to the level the group closes into (`{ scripts/check.sh; } && echo ok` passes, `{ scripts/check.sh; }; echo x` denies). For a command a `)` ends, the operator after the closers counts: `lex()` records it as `closed_by`, with the `(` depth it sits at, since the empty command that operator ends isn't kept, so `(scripts/check.sh) || echo failed` is caught. For `(scripts/check.sh;)`, where an empty command meets the `)`, the last command at that depth, if `;` or a newline ended it, takes the operator after it (`leads_on()`); one a `&` ended keeps its `&`, so `(scripts/check.sh;) && x` passes and `(scripts/check.sh;) | tail` is piped. A gate inside a command or process substitution (`$( )`, backticks, `<( )`, `>( )`, which `lex()` hands on as `Substitution` scripts) never gives the call its status, so `analyse()` sets `gate_hidden` for it outright: `x=$(scripts/check.sh)`, `echo "$(scripts/check.sh)"`. `gate_hidden` makes `decide()` deny, saying to run the gate on its own or follow it only with `&& ...`, which runs only when the gate passed.

Pipefail is on only where the calling shell surely ran a `set` turning it on before the gate. Such a `set` (`-o pipefail`, `-euo pipefail`, no expansion, no `+` option) counts only when its first word is `set` itself (not behind a wrapper), it comes first or after `;` or a newline (not after `&&`, which a failed command skips, or `||`), it isn't ended by `|`, `|&` or `&` (a pipeline stage or background job runs in a subshell), and no `(`, `)`, reserved word (`{`, `if`, `for` and the rest) or unfollowed construct came before it in the text. Any other word naming pipefail (`set +o pipefail`, `set +o pipe_fail`) turns it off. A script in `$( )` or `bash -c` starts with it off. These rules are conservative: a call they misjudge gets a deny with the two forms that pass.

These are the decision changes from allow to deny, with the scanned heredoc bodies of decision 3 (an interpreter's body, once data, is now checked for denies).

### 8. Allow rules

`devenv.nix` gains `gh-app issue view *`, `gh-app issue list *`, `gh-app pr list *`, `git fetch *` and `git rev-list *`, and the App's routine writes `gh-app issue comment *`, `gh-app issue edit *` and `gh-app pr comment *`: `issue create` and `pr create` are already allowed, and posting as the App is routine under the conventions. `ls`, `grep` and `jq` need no rule: they are read-only commands. `git worktree list` is already covered by `git worktree *`.

## Risks / Trade-offs

- [A chain runs commands that were each fine alone but not together, e.g. `git switch x && scripts/check.sh`] → Each part would run without a prompt as its own call, so the chain adds nothing a session couldn't already do in two calls.
- [An allow rule names a program that runs what's piped into it] → Shells and interpreters reading stdin are never approved as a stage; any other program an allow rule names is trusted with any arguments already, stdin included.
- [`$TMPDIR` in the hook differs from the session's] → Both values are scratch roots; a session that reassigns `TMPDIR` does so with an assignment or `export`, neither of which is approved.
- [A heredoc delimiter quoted only in part (`<<E"OF"`)] → The strict reader accepts only a fully quoted delimiter; the full reader's quoting check is unchanged. Anything else gets no allow.
- [A function shadowing a forbidden program (`git() { ...; }; git push --force`) now asks instead of denying] → Ask still stops the call for Derek. Denying would also deny allowed calls through wrappers like #61's `gh`.
- [The gate piped without `pipefail` now denies] → The message gives the two forms that keep the status; both are approved.
- [The pipefail rules deny some calls that do keep the status, e.g. `git status && set -o pipefail; scripts/check.sh | tail` or a `set` after a loop] → A deny names the forms that pass; guessing in the other direction would hide a red gate.
- [A heredoc piped to a stage the guard can't classify] → The call gets no allow and its body stays data, so a deny isn't added on a guess; any shell or interpreter stage still has the body checked.
- [Interactive and editor options now ask (`git add -p`, `git commit -e`, `gh-app issue create --editor`)] → Nobody is at the terminal to answer them, so the call would hang; the plain forms stay allowed.
- [A body something may run is checked for denies, even when it is SQL, a remote script or code in another language] → A deny can only come from text that names a forbidden command or writes a project file; its strings are read roughly, so `system('git push -f')` counts. A body a known data consumer reads stays data. Ask rules don't look at it, so an ask rule can't fire on a guess.
- [A commit given no message, and a fetch that can drop refs, now ask where they were allowed] → Nobody is there to use the editor, and a forced or `:` refspec, `--update-head-ok` or `--prune` can lose local work; plain `git fetch [remote] [branch]` and commits with a message stay allowed.
- [Anything after the gate but `&& ...` now denies] → The call's status would be the last command's; the deny says to run the gate alone or chain with `&&`.
- [Known limits: spellings that feed the gate or a forbidden command to a shell on purpose] → The guard stops mistakes, not attackers (the sandbox is the boundary), so these stay out of scope: a shell reading a process substitution or a compound stage (`bash <(echo 'git push -f')`, `{ echo 'git push -f'; } | sh` built from parts it can't read), `bash -c "$(cat <<EOF ... EOF)"` whose script exists only once the substitution runs, and a dummy function defined in a subshell to shadow a program name. None is a spelling a session reaches by accident.
- [Decisions change for existing cases] → Most are from no decision or ask to allow; the gate piped without `pipefail`, and an interpreter's heredoc body naming a forbidden command, move to deny, and `git fetch --update-head-ok` from allow to ask. tasks.md lists each one so a reviewer sees them.

## Migration Plan

The guard ships with the module: a project picks it up on its next `devenv update` and shell entry. Rollback is reverting the commit; nothing persists.

## Open Questions

None. Settled: the App's `issue comment`, `issue edit` and `pr comment` join the allow rules (decision 8); the gate piped without `pipefail` is denied (decision 7); loops are not unrolled.
