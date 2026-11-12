# Spec Delta

## MODIFIED Requirements

### Requirement: Only plain commands named by an allow rule are allowed
The guard SHALL allow a Bash call only when every command is approved and the call uses only forms named below. A command is approved when an allow rule names it, optionally behind `devenv shell --`, or when it only reads inside the project. An approved command has no expansion other than `$TMPDIR`, no `cd`, file redirect outside scratch, config override, risky option or construct the guard doesn't follow.

Tested by: `claude-guard-test.py`, the allow, compound-command and review sections.

#### Scenario: Wrapped allowed command
- **WHEN** the allow rules list `scripts/check.sh` and a session runs `devenv shell --quiet -- scripts/check.sh 2>&1`
- **THEN** the guard allows it

#### Scenario: A rule for the wrapper doesn't allow what's inside
- **WHEN** the allow rules list `devenv shell *` and a session runs `devenv shell --quiet -- rm -rf build`
- **THEN** the guard asks

#### Scenario: Commit with a heredoc message
- **WHEN** a session runs `git commit -m "$(cat <<'EOF' ... EOF)"` and an allow rule covers `git commit *`
- **THEN** the guard allows it, treating the message as data

#### Scenario: Commit with a heredoc message in a chain
- **WHEN** allow rules cover `git add *` and `git commit *` and a session runs `git add -A && git commit -m "$(cat <<'EOF' ... EOF)"`
- **THEN** the guard allows it; the message is data only where the commit is its own command in a `&&`, `;` or newline chain whose earlier commands are all plain

#### Scenario: A revision with ~
- **WHEN** allow rules cover `git diff *` and `git log *` and a session runs `git diff HEAD~1` or `git log HEAD~3..HEAD`
- **THEN** the guard allows it; `git diff HEAD^` gets no allow (`^` is a zsh glob operator), nor an unquoted `~` opening a word or outside a revision, while a quoted `~` (`git log --grep='a~b'`) stays plain

#### Scenario: Allowed program with a risky option
- **WHEN** an allow rule covers `git diff *` and a session runs `git diff --output=out.patch`
- **THEN** the guard asks

#### Scenario: An option that runs a program
- **WHEN** an allow rule covers `git fetch *` and a session runs `git fetch --upload-pack=evil origin` or `git fetch --upl=evil origin`
- **THEN** the guard asks. Likewise `--receive-pack`, `--exec`, an `ext::` or `fd::` URL, `git -c` and `git --config-env` with any allowed git command

#### Scenario: A fetch that can drop local work or refs
- **WHEN** an allow rule covers `git fetch *` and a session runs `git fetch origin +main:main`, `git fetch origin main:main`, or a fetch with `-f`/`--force`, `-u`/`--update-head-ok`, `-p`/`--prune`, `-P`/`--prune-tags` or `--refmap`, or any prefix of those long options from one letter after `--` (`--fo`, `--pru`)
- **THEN** the guard asks, and still allows `git fetch origin main` and `git fetch --progress origin`

#### Scenario: An option that waits for an editor
- **WHEN** allow rules cover the command and a session runs `git branch --edit-description`, `git commit -e -m x`, `git tag -e -m x v1`, `git add -p`, `gh-app issue create --title x --editor` or `gh-app issue comment 1 --edit-last`
- **THEN** the guard asks: nobody is there to use the editor or the interactive prompt

#### Scenario: A message nobody gives
- **WHEN** allow rules cover the command and a session runs `git commit` or `git commit --amend` without `-m`, `-F`, `-C` or `--no-edit`, `git commit --fixup=reword:HEAD` or `--fixup=amend:HEAD`, `git tag -a v1`, `git tag -s v1` or `git tag -u key v1` without `-m` or `-F`, or `gh-app issue create --title x` without a body
- **THEN** the guard asks: git or gh would open an editor for it

#### Scenario: -o that names no file
- **WHEN** a session runs `git log | grep -o foo`
- **THEN** the guard allows it: `-o` keeps an allow only for programs where it is known to name no file or program (`grep`, `egrep`, `fgrep`, `rg`, `set`)

#### Scenario: A git option's value in the word
- **WHEN** allow rules cover `git status *`, `git log *` and `git commit *` and a session runs `git status -uno`, `git log -Sfoo`, `git log -Gfoo` or `git commit -mdocs:x`
- **THEN** the guard allows it: for git only a word starting `-o` is `-o`, and a letter after one that takes a value is part of the value

#### Scenario: An o later in the word
- **WHEN** allow rules cover `ls *`, `wc *` and `go test *` and a session runs `ls -lo`, `wc -lo README.md` or `go test -count=1 -timeout 30s ./...`
- **THEN** the guard allows it: an `o` after a word's first letter counts as `-o` only for `unzip`, `7z`, `ssh`, `scp`, `sftp`, `curl`, `wget`, `cc`, `gcc`, `clang`, `sort` and `mount` (`unzip -qo`)

#### Scenario: A message that starts with a dash
- **WHEN** allow rules cover `git commit *` and `gh-app issue comment *` and a session runs `git commit -m "-o is refused"`, `git commit -m "-e"` or `gh-app issue comment 3 --body "-e is nice"`
- **THEN** the guard allows it: the word after `-m` or `--message` for git's commit and merge, notes add and append, and a bare stash, stash push and stash save, `-m` for git's tag, and `-t`, `--title`, `-b` or `--body` for gh's issue and pr create, edit and comment is text, not an option; nowhere else is a word skipped, and a word that could make git run a program (`--upload-pack`, `--receive-pack`, `--exec`, `-c`, `--config`) is checked even as text, as is one naming an output file (`-o`, `--output`) unless it holds whitespace, so `git fetch -t --upload-pack=x origin` and `git stash list -m --output=x` still ask

#### Scenario: An empty word
- **WHEN** a session runs `git status; echo ""; git log -1`, `git commit -m ''` or `grep -n '' f`
- **THEN** the guard allows it: an empty quoted word is kept, as the shell keeps it

#### Scenario: -o anywhere else
- **WHEN** allow rules cover `ssh *`, `unzip *` and `7z *` and a session runs `ssh -o ProxyCommand=sh host`, `unzip -o a.zip` or `7z x -oout a.7z`
- **THEN** the guard asks

### Requirement: Ask and deny rules apply inside wrappers
The guard SHALL match the session's deny, ask and allow rules against each command of a call in both spellings: as written, wrapper included, and unwrapped, including git with its global options dropped. A rule written with the wrapper SHALL also stand for its inner command, an allow rule only where that command runs through the wrapper.

Tested by: `claude-guard-test.py`, the policy block and "A wrapper's own allow rule doesn't reach inside it".

#### Scenario: Deny rule behind a wrapper
- **WHEN** the deny rules list `cargo publish *` and a session runs `devenv shell -- cargo publish`
- **THEN** the guard denies it

#### Scenario: A wrapper-spelled ask rule in a chain
- **WHEN** the ask rules list `devenv shell --quiet -- gh-app issue create *` and a session runs `git status && devenv shell --quiet -- gh-app issue create --title x --body y`
- **THEN** the guard asks, as it does for that command alone or unwrapped

#### Scenario: A wrapper-spelled allow rule
- **WHEN** the allow rules list `git status *` and `devenv shell --quiet -- cargo test *` and a session runs `git status && devenv shell --quiet -- cargo test`
- **THEN** the guard allows it, and gives `git status && cargo test` no allow

#### Scenario: Deny rule behind an inert git option
- **WHEN** the deny rules list `git push *` and a session runs `git --literal-pathspecs push origin x`
- **THEN** the guard denies it

## ADDED Requirements

### Requirement: Sequences and pipelines are approved part by part
The guard SHALL allow a call whose commands are joined by `&&`, `||`, `;`, newlines and `|` when each command, and each pipeline stage, is approved on its own. It SHALL return no allow when any part isn't approved, and SHALL still deny or ask when any part is forbidden or matches a deny or ask rule. A stage that is a shell or interpreter reading its script from the pipe SHALL never be approved.

Tested by: `claude-guard-test.py`, "Sequences and pipelines" cases.

#### Scenario: Two allowed commands
- **WHEN** allow rules cover `git status *` and `git log *` and a session runs `git status && git log -1`
- **THEN** the guard allows it

#### Scenario: Newline and semicolon sequences
- **WHEN** an allow rule covers `git worktree *` and `git branch *` and a session runs `git worktree list; git branch -vv`
- **THEN** the guard allows it

#### Scenario: Each command wrapped
- **WHEN** an allow rule covers `gh-app issue view *` and a session runs `devenv shell --quiet -- gh-app issue view 36; devenv shell --quiet -- gh-app issue view 21`
- **THEN** the guard allows it

#### Scenario: One part not approved
- **WHEN** a session runs `git status && rm -rf build`
- **THEN** the guard returns no allow

#### Scenario: One part covered by an ask rule
- **WHEN** an ask rule covers `git push *` and a session runs `git status; git push -u origin feat`
- **THEN** the guard asks

#### Scenario: One part forbidden
- **WHEN** a session runs `git status && git push --force`
- **THEN** the guard denies it

#### Scenario: A wrapper rule in one part
- **WHEN** the allow rules list `devenv shell *` and a session runs `git status && devenv shell --quiet -- rm -rf build`
- **THEN** the guard asks

#### Scenario: Piping into an interpreter
- **WHEN** a session runs `git log | python3`
- **THEN** the guard returns no allow

### Requirement: Constructs that hide commands still get no allow
The guard SHALL return no allow for a call that uses background `&`, `|&`, a subshell or `{ }` group, `!`, command or process substitution, backticks, `eval`, `cd`, a variable assignment, a comment, a here-string, an input redirect from a file, a line continuation, a loop (`for`, `while`, `until`, `select`), `case`, `if`, or any expansion other than `$TMPDIR`. It SHALL still deny a forbidden command inside any of them.

Tested by: `claude-guard-test.py`, "Still not followed" cases.

#### Scenario: Background job
- **WHEN** a session runs `git status & git log`
- **THEN** the guard returns no allow

#### Scenario: Subshell
- **WHEN** a session runs `(git status; git log)`
- **THEN** the guard returns no allow

#### Scenario: Substitution in a sequence
- **WHEN** a session runs `git status && git log $(git rev-parse HEAD)`
- **THEN** the guard returns no allow

#### Scenario: cd in a sequence
- **WHEN** a session runs `git status && cd sub && git log`
- **THEN** the guard returns no allow

#### Scenario: A for loop of allowed commands
- **WHEN** an allow rule covers `gh-app issue view *` and a session runs `for i in 36 21; do devenv shell --quiet -- gh-app issue view $i; done`
- **THEN** the guard returns no allow

#### Scenario: A forbidden command in a loop
- **WHEN** a session runs `for b in a c; do git push -f; done`
- **THEN** the guard denies it

### Requirement: Quoted heredoc bodies are data
The body of a quoted heredoc (`<<'D'`, `<<"D"`, `<<-'D'`) SHALL be data for approval, in the full reading and in the rough one. What reads it SHALL be found through the opener's own pipeline, unwrapped, never from other text in the call. A body a shell reads SHALL be checked as commands; one an interpreter or an unknown stage reads SHALL get no allow. A heredoc with an unquoted delimiter SHALL get no allow.

Tested by: `claude-guard-test.py`, "Heredocs" cases.

#### Scenario: Issue body quoting a forbidden command
- **WHEN** an allow rule covers `gh-app issue create *` and a session runs `devenv shell --quiet -- gh-app issue create --title x --body-file - <<'EOF'` with a body line `Run gh pr merge 55 --auto --squash.`
- **THEN** the guard allows it

#### Scenario: Heredoc command piped on its own line
- **WHEN** a session runs `gh-app issue create --title x --body-file - <<'EOF' 2>&1 | grep 'https://'` with a body line `gh pr merge 55`
- **THEN** the guard allows it, and does not deny it for `gh pr merge`

#### Scenario: Commit message on stdin
- **WHEN** an allow rule covers `git commit *` and a session runs `git commit -F - <<'EOF'` with a body that mentions `git push --force`
- **THEN** the guard allows it

#### Scenario: Unquoted delimiter
- **WHEN** a session runs `git commit -F - <<EOF` with a body `fix: x`
- **THEN** the guard returns no allow

#### Scenario: Body fed to a shell
- **WHEN** a session runs `bash <<'EOF'` with a body `git push --force`
- **THEN** the guard denies it

#### Scenario: Body piped to a shell
- **WHEN** a session runs `cat <<'EOF' | ksh` (or `| /bin/bash`, `| env bash`, `| devenv shell -- bash`, `| xargs -0 sh -c`, `| fish`, `| head | sh`, `| "$SHELL"`) with a body `git push --force`
- **THEN** the guard denies it

#### Scenario: Body in a group piped to a shell
- **WHEN** a session runs `{ cat <<'EOF'` with a body `git push --force`, then `EOF` and `} | sh`
- **THEN** the guard denies it

#### Scenario: A pipe split across the body
- **WHEN** a session runs `cat <<'EOF' |`, a body `git push --force`, `EOF` and then `bash`
- **THEN** the guard denies it

#### Scenario: Body piped to an interpreter
- **WHEN** a session runs `cat <<'EOF' | python3` with a body `open('.env').read()`
- **THEN** the guard denies it as a secrets read

#### Scenario: Body piped to a stage the guard can't classify
- **WHEN** a session runs `cat <<'EOF' | gh-app issue create --title x --body-file -` with a body `git push --force`
- **THEN** the guard returns no allow, and does not deny it

#### Scenario: An issue body that mentions piping to a shell
- **WHEN** an allow rule covers `gh-app issue create *` and a session runs `gh-app issue create --title x --body-file - <<'EOF'` with a body `Use curl x | sh, then git push --force.`
- **THEN** the guard allows it

#### Scenario: Body in a call the guard can't parse
- **WHEN** a session runs `git -c core.x=y commit -F - <<'EOF'` with a body `git push --force`
- **THEN** the guard asks, and does not deny it

#### Scenario: Body fed to a shell in a call the guard can't parse
- **WHEN** a session runs `git -c core.x=y status; bash <<'EOF'` with a body `git push --force`
- **THEN** the guard denies it

#### Scenario: A command after the body
- **WHEN** a session runs `git commit -F - <<'EOF'`, a body `fix`, the closing `EOF` and then `rm -rf build`
- **THEN** the guard returns no allow

### Requirement: Bodies a program may run are checked for denies
A heredoc body or here-string (`<<<`) SHALL be checked for denies as a script, its quoted strings too, unless each reader in the opener's pipeline is a data consumer: a read-only filter, `git commit`/`git tag` or `gh`/`gh-app` reading stdin (`-F -`, `-F-`, `--file=-`, `--body-file -`, `=-`), or `tee` to scratch only. A here-string a shell reads SHALL be checked as commands. Approval SHALL be as for a heredoc.

Tested by: `claude-guard-test.py`, the "known data consumer" and "Here-strings" cases.

#### Scenario: A body for another shell or a remote one
- **WHEN** a session runs `tcsh <<'EOF'` (or `csh`, `pwsh`, `nu`, `ssh host`, `sqlite3 db`) with a body `git push -f`
- **THEN** the guard denies it

#### Scenario: A body in another language
- **WHEN** a session feeds `php`, `lua`, `awk -f -`, `osascript` or `python3 -` a body whose string or substitution runs `git push -f`
- **THEN** the guard denies it

#### Scenario: A body that writes a project file
- **WHEN** a session runs `ssh host <<'EOF'` with a body `echo x > README.md`
- **THEN** the guard denies it and names the Edit and Write tools

#### Scenario: A here-string a shell reads
- **WHEN** a session runs `bash <<< 'git push -f'`, `git status && sh <<<'git reset --hard'` or `cat <<<'git push -f' | sh`
- **THEN** the guard denies it

#### Scenario: A body a data consumer reads
- **WHEN** an allow rule covers `git commit *` and a session runs `git commit -F - <<'EOF'` with a body that mentions `git push -f`
- **THEN** the guard allows it

#### Scenario: Prose copied to scratch
- **WHEN** a session runs `tee "$TMPDIR/b.md" <<'EOF'` with a body saying "Never run git push --force"
- **THEN** the guard doesn't deny it; a `tee` to `/etc/b.md`, or piped on to `sh`, is still denied

### Requirement: Redirects to devices and scratch keep a command approved
A redirect SHALL keep a command approved when it duplicates a descriptor (`2>&1`, `>&2`), or writes or appends to `/dev/null`, `/dev/stdout`, `/dev/stderr` or a scratch file under `$TMPDIR` (spelled `$TMPDIR`, `${TMPDIR}`, quoted or not), `/tmp`, `/private/tmp` or `/private/var/folders`, judged after resolving `..` and symlinks. A write elsewhere outside the project SHALL get no allow; a write into it stays denied.

Tested by: `claude-guard-test.py`, "Redirects" cases.

#### Scenario: Output to scratch
- **WHEN** an allow rule covers `git log *` and a session runs `git log > "$TMPDIR/log.txt" 2>&1`
- **THEN** the guard allows it

#### Scenario: Errors discarded in a pipeline
- **WHEN** an allow rule covers `git log *` and a session runs `git log 2>/dev/null | head -5`
- **THEN** the guard allows it

#### Scenario: A path out of scratch
- **WHEN** a session runs `git log > "$TMPDIR/../../../../../../../../etc/x"`
- **THEN** the guard returns no allow

#### Scenario: Output into the project
- **WHEN** a session runs `git log > out.txt`
- **THEN** the guard denies it and names the Edit and Write tools

#### Scenario: Output to the home directory
- **WHEN** a session runs `git log > ~/x`
- **THEN** the guard returns no allow

### Requirement: More read-only filters are approved
`sort`, `uniq` and `jq` SHALL count as read-only, `sort` and `uniq` only with listed options (`sort`: `-n -r -u -k -t -f -b -h -V -s -z`; `uniq`: `-c -d -D -u -i -z -f -s -w`; their long forms; clusters) and `uniq` with one operand at most and no `--`. `jq` SHALL get no allow when its filter mentions `env`, `$ENV`, `import` or `include`, or with `-f`, `--from-file` or `-L`; nor `tail` following a file, nor `grep -f`/`--file`.

Tested by: `claude-guard-test.py`, "Sequences and pipelines" cases.

#### Scenario: jq on a gh-app result
- **WHEN** an allow rule covers `gh-app pr view *` and a session runs `gh-app pr view 1 --json title | jq -r .title`
- **THEN** the guard allows it

#### Scenario: jq reading the environment
- **WHEN** a session runs `git log | jq -n env`
- **THEN** the guard returns no allow

#### Scenario: uniq writing an output file
- **WHEN** a session runs `git log | uniq - out.txt`
- **THEN** the guard returns no allow

#### Scenario: uniq operands after --
- **WHEN** a session runs `git log | uniq -- -x y`
- **THEN** the guard returns no allow

#### Scenario: tail following a file
- **WHEN** a session runs `git log | tail -f` or `tail --follow=name log.txt`
- **THEN** the guard returns no allow

#### Scenario: sort reading files named indirectly
- **WHEN** a session runs `git log | sort --files0-from=list.txt` or `git log | sort --random-source=seed`
- **THEN** the guard returns no allow, and still allows `git log | sort -k2,2 -t: -rn`

#### Scenario: grep patterns from a file
- **WHEN** a session runs `git log | grep -f patterns.txt` or `git log | grep --file=patterns.txt`
- **THEN** the guard returns no allow

### Requirement: set options that keep a pipeline's status are approved
The guard SHALL approve `set` when its only arguments are `-o pipefail` and short option clusters of `e`, `u` and `x` (`-euo pipefail` included), so a call can keep a pipeline's exit status. Any other `set` SHALL get no allow.

Tested by: `claude-guard-test.py`, "Sequences and pipelines" cases.

#### Scenario: The gate with pipefail
- **WHEN** the allow rules list `scripts/check.sh` and a session runs `set -o pipefail; devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`
- **THEN** the guard allows it

#### Scenario: Another set
- **WHEN** a session runs `set -- a b; git status`
- **THEN** the guard returns no allow

### Requirement: The gate's exit status is not piped away
The guard SHALL deny a call that pipes `scripts/check.sh` (any path ending in it, behind a wrapper or not) into another command with `|` or `|&`, unless pipefail is on. This SHALL apply to every call the guard can lex, in `$( )`, `bash -c` and a piped group or subshell holding the gate; no other pipe SHALL count. The reason SHALL name `set -o pipefail` and a redirect to `$TMPDIR` as the forms that keep the status.

Tested by: `claude-guard-test.py`, the two gate sections.

#### Scenario: The gate piped into tail
- **WHEN** a session runs `devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`
- **THEN** the guard denies it and names `set -o pipefail`

#### Scenario: The gate with pipefail set first
- **WHEN** the allow rules list `scripts/check.sh` and a session runs `set -o pipefail; devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`
- **THEN** the guard allows it

#### Scenario: The gate's output to scratch
- **WHEN** the allow rules list `scripts/check.sh` and a session runs `devenv shell --quiet -- scripts/check.sh > "$TMPDIR/check.log" 2>&1`
- **THEN** the guard allows it

#### Scenario: The gate piped in a call the strict reader doesn't read
- **WHEN** a session runs `scripts/check.sh 2>&1 | tail -3 # gate`, `scripts/check.sh |& tail`, `echo $(scripts/check.sh | tail)` or `{ scripts/check.sh; } | tail`
- **THEN** the guard denies it

#### Scenario: A pipe the gate isn't in
- **WHEN** a session runs `scripts/check.sh && { echo a; } | cat`, or `{ git log -1; } | head -3` and then, on the next line, `scripts/check.sh > "$TMPDIR/c.log" 2>&1`
- **THEN** the guard doesn't deny it: the gate's status goes into no pipe

#### Scenario: A piped compound command nested in another
- **WHEN** a session runs `{ { scripts/check.sh; }; } | tail`, `if true; then if true; then scripts/check.sh; fi; fi | tail` or `for i in 1; do if true; then scripts/check.sh; fi; done | tail`
- **THEN** the guard denies it: an opener after `then`, `do`, `else`, `elif`, `!`, `time` or another opener nests as one at a command's start does

### Requirement: Only && may follow the gate
The guard SHALL deny a call that runs `scripts/check.sh` and then, after `||`, `;`, a newline or `&`, another command, or that backgrounds it with `&`, since the call's status is then not the gate's; `&& ...` MAY follow it. It SHALL also deny piping the gate where a shell runs it as its script (`bash scripts/check.sh | tail`, `devenv shell -- sh scripts/check.sh | tail`), unless pipefail is on.

Tested by: `claude-guard-test.py`, "Only `&& ...` may follow the gate" cases.

#### Scenario: Another command's status
- **WHEN** a session runs `scripts/check.sh || true`, `scripts/check.sh; echo done`, or the gate, a newline and `echo x`
- **THEN** the guard denies it

#### Scenario: A backgrounded gate
- **WHEN** a session runs `scripts/check.sh &`, `scripts/check.sh && git status &`, `(scripts/check.sh &) && echo started` or `{ ( scripts/check.sh & ); }`
- **THEN** the guard denies it: the call's status is 0 whatever the gate's is, and a `&` ending the gate backgrounds it at any depth

#### Scenario: A command after &&
- **WHEN** the allow rules list `scripts/check.sh` and `git status *` and a session runs `scripts/check.sh && git status`
- **THEN** the guard allows it

#### Scenario: The gate through a shell in a pipe
- **WHEN** a session runs `bash scripts/check.sh | tail`, `sh scripts/check.sh | tail` or `devenv shell -- sh scripts/check.sh | tail`
- **THEN** the guard denies it

### Requirement: The gate keeps its status out of subshells and substitutions
For the gate check, only operators at the gate's own nesting level SHALL count, and, once the gate ends its subshell or group, those after its closing `)` or `}`; operators inside a compound command that `&&` leads to SHALL NOT. Running `scripts/check.sh` inside a command or process substitution (`$( )`, backticks, `<( )`, `>( )`) SHALL be denied.

Tested by: `claude-guard-test.py`, "What follows a subshell's `)`" and "Operators inside a compound command" cases.

#### Scenario: A compound command after &&
- **WHEN** a session runs `scripts/check.sh && { echo a; echo b; }`, `{ scripts/check.sh; } && echo ok` or `scripts/check.sh && if git diff --quiet; then echo clean; fi`
- **THEN** the guard doesn't deny it, and still denies `{ scripts/check.sh; }; echo x`

#### Scenario: A command after the subshell
- **WHEN** a session runs `(scripts/check.sh) || echo failed`, `(scripts/check.sh); echo done` or `((scripts/check.sh)) || true`
- **THEN** the guard denies it, and leaves `(scripts/check.sh) && git status` to Claude Code's rules

#### Scenario: The gate in a substitution
- **WHEN** a session runs `x=$(scripts/check.sh); echo done`, `x=$(scripts/check.sh)`, `echo "$(scripts/check.sh)"` or ``echo `scripts/check.sh` ``
- **THEN** the guard denies it

### Requirement: pipefail counts only where the calling shell surely sets it
For the gate check, pipefail SHALL count as on only after a `set` turning it on that the calling shell itself runs before the gate: first in the call or after `;` or a newline, not piped, backgrounded or wrapped, and before any subshell, group, loop or `if`. Any later mention of pipefail SHALL turn it off. A script in `$( )` or `bash -c` SHALL start with it off.

Tested by: `claude-guard-test.py`, "pipefail counts only where the calling shell is sure to set it first" cases.

#### Scenario: pipefail set where it may not take effect
- **WHEN** a session runs `true || set -o pipefail; scripts/check.sh | tail`, `echo | set -o pipefail; ...`, `set -o pipefail | cat; ...`, `devenv shell -- set -o pipefail; ...` or `(set -o pipefail); ...`
- **THEN** the guard denies it

#### Scenario: pipefail turned off again
- **WHEN** a session runs `set -o pipefail; set +o pipefail; scripts/check.sh | tail`
- **THEN** the guard denies it

### Requirement: Shell function definitions ask
A call that defines a shell function (`name()`, `name ()`, `function name`) SHALL get no allow. A call in it to a name it defines SHALL ask, in the full and the rough reading, rather than be judged as the program of that name. The function's body SHALL still be checked, so a forbidden command in it is still denied.

Tested by: `claude-guard-test.py`, "Shell functions" cases.

#### Scenario: A function named gh
- **WHEN** a session runs `gh() { devenv shell --quiet -- gh-app "$@"; }` and then, on the next line, `gh pr merge 55 --auto --squash`
- **THEN** the guard asks, and does not deny it

#### Scenario: A forbidden command in the body
- **WHEN** a session runs `f() { git push --force; }; f`
- **THEN** the guard denies it

#### Scenario: A call to a name the call doesn't define
- **WHEN** a session runs `f() { :; }; gh pr merge 1`
- **THEN** the guard denies it
