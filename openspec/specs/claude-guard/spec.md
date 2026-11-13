# claude-guard Specification

## Purpose
The coldlogic guard is a Claude Code PreToolUse hook. It decides each tool call from what the call would actually run, so wrappers and odd spellings can't get past permission rules. It is a backstop against mistakes, not a security boundary.

## Requirements

### Requirement: Guard runs on every file and shell tool
The module SHALL register the guard as a PreToolUse hook on `Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob`. The hook SHALL read the session's Bash allow, ask and deny rules from a policy file the module generates, and SHALL add the Bash ask and deny rules from the user's, managed and checkout settings. Allow rules SHALL come only from the policy file.

Tested by: none (wiring in `devenv.nix`); the decisions below are tested.

#### Scenario: Project rules reach the guard
- **WHEN** a project adds `claude.code.permissions.rules.Bash.allow = [ "git merge *" ]`
- **THEN** the guard's policy file lists `git merge *` among its allow rules

### Requirement: Guard tests gate its build
The guard package SHALL run `claude-guard-test.py` when it builds, and SHALL fail to build if any case fails, so a guard that fails its cases never reaches a shell.

Tested by: `packages/claude-guard.nix`.

#### Scenario: A failing case stops the build
- **WHEN** a change to `claude-guard.py` makes any case in `claude-guard-test.py` return a different decision
- **THEN** building `coldlogic-claude-guard` fails and no shell gets the changed guard

### Requirement: Forbidden commands are denied however they are spelled
The guard SHALL deny force pushes (including `--force-with-lease`, `+refspec`, combined short flags and `--mirror`), `git reset --hard`, `wrangler deploy`/`publish`/`rollback` without `--dry-run`, `nix develop` and `nix-shell`. It SHALL apply this inside wrappers, shells, substitutions, heredocs fed to a shell, compound commands and git global options.

Tested by: `claude-guard-test.py`, `BASH` cases under "Forbidden however it's spelled" and the review sections.

#### Scenario: Wrapped force push
- **WHEN** a session runs `devenv shell --quiet -- git push --force`
- **THEN** the guard denies it

#### Scenario: Force push behind git global options
- **WHEN** a session runs `git -c core.x=y push -f`
- **THEN** the guard denies it

#### Scenario: Hard reset inside a shell
- **WHEN** a session runs `bash -c 'git reset --hard'`
- **THEN** the guard denies it

#### Scenario: Deploy through a package runner
- **WHEN** a session runs `pnpm exec wrangler deploy`
- **THEN** the guard denies it

#### Scenario: Ordinary push is left to the rules
- **WHEN** a session runs `git push -u origin feat` and an ask rule covers `git push *`
- **THEN** the guard asks, and doesn't deny

### Requirement: The user's gh credentials can't merge or approve
The guard SHALL deny `gh pr merge`, `gh pr review --approve` (in any spelling), `gh alias` and any `gh api` call that merges, approves or creates a review, since the user's credentials stand in for the review the ruleset requires.

Tested by: `claude-guard-test.py`, `gh` cases.

#### Scenario: Merge with the user's credentials
- **WHEN** a session runs `gh pr merge 12 --squash`
- **THEN** the guard denies it

#### Scenario: Approval through the API
- **WHEN** a session runs `gh api repos/o/r/pulls/12/reviews -f event=APPROVE`
- **THEN** the guard denies it

#### Scenario: Answering a review thread
- **WHEN** a session replies to or resolves a review thread through `gh api graphql`
- **THEN** the guard leaves the call to Claude Code's rules

### Requirement: The App merges only through gh-app pr merge and never approves
The guard SHALL deny `gh-app pr review --approve`, `gh-app alias`, and `gh-app api` calls that merge, enable auto-merge, approve or create a review. It SHALL leave `gh-app pr merge` to the rules, since that wrapper checks the PR first.

Tested by: `claude-guard-test.py`, `gh-app` cases.

#### Scenario: Merge through the API
- **WHEN** a session runs `gh-app api -X PUT repos/o/r/pulls/1/merge`
- **THEN** the guard denies it

#### Scenario: Merge through the wrapper
- **WHEN** a session runs `gh-app pr merge --auto --squash 12`
- **THEN** the guard doesn't deny it

### Requirement: Secrets files are denied to tools and commands
The guard SHALL deny file tools on, and commands that read or write, `.env`, `.dev.vars` and their variants (any case, globs, brace and ANSI-C spellings, symlinks to them) and anything under a `secrets` directory. It SHALL allow template variants ending in `.example`, `.sample`, `.template` or `.dist`, and `.envrc`.

Tested by: `claude-guard-test.py`, "Secrets files" `BASH` cases and `FILES`.

#### Scenario: Reading .env from a command
- **WHEN** a session runs `cat app/.env`
- **THEN** the guard denies it and points to `.env.example`

#### Scenario: Glob that matches a secrets file
- **WHEN** a session runs `cat .e*`
- **THEN** the guard denies it

#### Scenario: Template file
- **WHEN** a session reads `/p/.env.example` with the Read tool
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Mentioning a secrets file without reading it
- **WHEN** a session runs `git check-ignore -v .dev.vars`
- **THEN** the guard doesn't deny it

### Requirement: Bash edits to project files point to Edit and Write
The guard SHALL deny a Bash call that changes a file inside the project or its worktrees through `sed -i`, `perl -i`, `tee`, a `>` or `>>` redirect, or an inline script that opens a file for writing. The reason SHALL tell the session to use the Edit or Write tool. Writes to `$TMPDIR`, `/tmp`, devices and paths outside the project SHALL pass.

Tested by: `claude-guard-test.py`, "Changing a project file from Bash" cases and the absolute-path and sibling-worktree blocks.

#### Scenario: In-place sed
- **WHEN** a session runs `sed -i 's/a/b/' src/main.rs`
- **THEN** the guard denies it and names the Edit and Write tools

#### Scenario: Redirect to scratch
- **WHEN** a session runs `echo x > "$TMPDIR/body.md"`
- **THEN** the guard doesn't deny it

#### Scenario: Edit in a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` runs `echo x > src/a.rs`
- **THEN** the guard denies it

### Requirement: File tools ask before changing .git or Claude Code configuration
The guard SHALL deny file-tool writes inside a `.git` directory. It SHALL ask before file tools change the project's `.claude` directory, except inside the checkouts under `.claude/worktrees/<name>/`. That directory itself, and the `.claude` of any of the project's own worktrees, SHALL still ask. A file link SHALL ask if it sits in, or resolves into, such a `.claude`. Reads SHALL be left alone.

Tested by: `claude-guard-test.py`, `FILES` and the `.claude`, linked-file and own-worktrees blocks.

#### Scenario: Writing git config
- **WHEN** a session writes `/p/nested/.git/config`
- **THEN** the guard denies it

#### Scenario: Editing project settings
- **WHEN** a session edits `<root>/.claude/settings.json` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing the generated settings link
- **WHEN** a session edits or writes `<root>/.claude/settings.json` and it is devenv's symlink into the Nix store
- **THEN** the guard asks

#### Scenario: A settings link whose target is missing
- **WHEN** a session writes `<root>/.claude/settings.local.json` and it is a symlink to a file outside the project that doesn't exist
- **THEN** the guard asks

#### Scenario: A link elsewhere that leads into .claude
- **WHEN** a session edits `<root>/alias.json` and it is a symlink to `<root>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: A link outside .claude that leads out of the project
- **WHEN** a session edits `<root>/notes.json` and it is a symlink to a file outside the project
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Reading the generated settings link
- **WHEN** a session reads `<root>/.claude/settings.json` and it is devenv's symlink into the Nix store
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Writing inside a worktree under .claude
- **WHEN** a session writes `<root>/.claude/worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Editing settings inside a worktree
- **WHEN** a session edits `<root>/.claude/worktrees/x/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Editing a skill inside a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/skills/y/SKILL.md` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing a sibling worktree's generated settings link
- **WHEN** a session in `<project>` or in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/settings.json` and it is a symlink to a file outside the project
- **THEN** the guard asks

#### Scenario: Editing the main checkout's settings from a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: Another repository's settings link
- **WHEN** a session in `<project>.worktrees/x` edits `<other>.worktrees/w/.claude/settings.json`, in a worktree of another repository, whether it is a regular file, a symlink or missing
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Writing source in a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` writes `<project>.worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

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

### Requirement: Commands the guard can't follow, and guard failures, ask
The guard SHALL ask, naming the reason, for a command it can't lex. A rough reading SHALL still deny one that contains a forbidden command. If the hook itself raises an error, it SHALL ask, never allow. In plan mode it SHALL return no allow.

Tested by: `claude-guard-test.py`, "Unparsable" cases; the error and plan-mode paths have no case.

#### Scenario: Unclosed quote
- **WHEN** a session runs `echo 'unclosed`
- **THEN** the guard asks

#### Scenario: Unclosed quote hiding a forbidden command
- **WHEN** a session runs `echo 'unclosed; git reset --hard`
- **THEN** the guard denies it

### Requirement: The project's own worktrees are recognised by their git metadata
A directory SHALL count as the project's own worktree only when it sits in `<project>.worktrees`, `<project>/.claude/worktrees` or `<root>/.claude/worktrees`, its `.git` file names a directory in `<project>/.git/worktrees` that names it back, and that one's `commondir` resolves to `<project>/.git` (paths read as git reads them). `<project>` SHALL be the main checkout a linked-worktree root's `.git` file names, else the root.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: An agent worktree beside the project
- **WHEN** `<project>.worktrees/x` was made by `git worktree add` from the project
- **THEN** the guard counts it as one of the project's own worktrees

#### Scenario: Metadata that doesn't name the directory back
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, but that directory's `gitdir` names another directory
- **THEN** the guard doesn't count it as one of the project's worktrees

#### Scenario: A worktree of the project somewhere else
- **WHEN** a session runs `git status` in `/elsewhere/wt`, a linked worktree of the project outside both places
- **THEN** the guard returns no allow

#### Scenario: Relative worktree paths
- **WHEN** a sibling worktree's `.git` file and its `gitdir` back-pointer hold relative paths (git's `worktree.useRelativePaths`), and a session there runs `git status`
- **THEN** the guard allows it

#### Scenario: A worktree with no commondir
- **WHEN** a sibling worktree's `.git/worktrees/x` has no `commondir`, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: A sibling of a root that is a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, a linked worktree of the main checkout `<main>`, and `<main>.worktrees/y` and `<main>/.claude/worktrees/n` were made by `git worktree add` from it
- **THEN** the guard counts `<main>.worktrees/y` and `<main>/.claude/worktrees/n` as the project's own worktrees

#### Scenario: A worktree under a linked root's own .claude
- **WHEN** the session's root is `<main>.worktrees/x` and `<main>.worktrees/x/.claude/worktrees/m` was made by `git worktree add` from it (EnterWorktree)
- **THEN** the guard counts it as one of the project's own worktrees for that session, and not for a session rooted in `<main>` or `<main>.worktrees/y`

#### Scenario: A root whose .git file is relative
- **WHEN** the session's root is `<main>.worktrees/x`, whose `.git` file holds a relative path, an allow rule covers `git status *`, and a session in `<main>.worktrees/y` runs `git status`
- **THEN** the guard allows it

#### Scenario: The same checks from a root that is a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session runs `git status` in a directory that only claims to be a worktree, a worktree whose `commondir` leads elsewhere, another repository's worktree, or a worktree of the project outside both places
- **THEN** the guard returns no allow

#### Scenario: A root whose .git file names no main checkout
- **WHEN** the session's root has a `.git` file whose directory has no `commondir` (a broken worktree, a submodule), or whose `commondir` isn't a checkout's `.git` directory (a worktree of a bare repository)
- **THEN** the guard takes the root itself for `<project>`, as before: a command in the root is judged as in any project root, and `git status` in `<main>.worktrees/y` returns no allow

### Requirement: The project's own worktrees are judged like its root
At the top of one of the project's own worktrees, or in a subdirectory of one with no other repository in between, a command SHALL get the same decision it would get in the project root, and paths inside such a worktree SHALL count as inside the project, whether the session's root is the main checkout or one of those worktrees. For a session rooted in a linked worktree, the main checkout SHALL NOT count as one of them.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: git status in a sibling worktree
- **WHEN** an allow rule covers `git status *` and a session in `<project>.worktrees/x`, a linked worktree of the project, runs `git status`
- **THEN** the guard allows it

#### Scenario: Branch creation in a sibling worktree
- **WHEN** an allow rule covers `git switch *` and a session in `<project>.worktrees/x` runs `git switch -c feat/y`
- **THEN** the guard allows it

#### Scenario: Forced switch in a sibling worktree
- **WHEN** an ask rule covers `git switch -f *` and a session in `<project>.worktrees/x` runs `git switch -f main`
- **THEN** the guard asks

#### Scenario: Adding a file in a subdirectory of a sibling worktree
- **WHEN** an allow rule covers `git add *` and a session in `<project>.worktrees/x/packages` runs `git add a.py`
- **THEN** the guard allows it

#### Scenario: A subdirectory of a worktree under .claude
- **WHEN** an allow rule covers `git log *` and a session in `<project>/.claude/worktrees/x/src` runs `git log`
- **THEN** the guard allows it

#### Scenario: A directory that only claims to be a worktree
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, whose `gitdir` names another directory, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: A worktree whose commondir leads elsewhere
- **WHEN** a worktree's `.git/worktrees/x/commondir` resolves to a directory other than the project's `.git`, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: Another repository's worktree
- **WHEN** a session runs `git status` in a worktree of a different repository
- **THEN** the guard returns no allow

#### Scenario: A nested repository inside a sibling worktree
- **WHEN** a session runs `git status` in `<project>.worktrees/x/vendor/lib`, which has its own `.git` directory
- **THEN** the guard returns no allow

#### Scenario: A path out of a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` runs `cat ../y/README.md`
- **THEN** the guard returns no allow

#### Scenario: A relative program below a worktree's top
- **WHEN** an allow rule covers `scripts/check.sh` and a session in `<project>.worktrees/x/packages` runs `scripts/check.sh`
- **THEN** the guard asks

#### Scenario: A sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, allow rules cover `git status *`, `git log *` and `git add *`, and a session runs `git status` in `<main>.worktrees/y`, `git add a.py` in `<main>.worktrees/y/packages`, or `git log` in `<main>/.claude/worktrees/n/src`
- **THEN** the guard allows it

#### Scenario: A sibling worktree's .claude, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session edits `<main>.worktrees/y/.claude/skills/s/SKILL.md`, a regular file, or `<main>/.claude/worktrees/n/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Source and .git in a sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session writes `<main>.worktrees/y/src/main.rs` or `<main>.worktrees/y/.git`
- **THEN** the guard leaves the first to Claude Code's rules and denies the second

#### Scenario: A shell edit in a sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session in `<main>.worktrees/y/packages` runs `echo x > ../src/b.rs`, which names no scratch file
- **THEN** the guard denies it, as a Bash call changing a project file

#### Scenario: -C naming a sibling, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, an allow rule covers `git status *`, and a session at the top of `<main>.worktrees/x` runs `git -C <main>.worktrees/y status`
- **THEN** the guard returns no allow, while the same command at the top of `<main>.worktrees/y` is allowed

#### Scenario: The main checkout, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, allow rules cover `git status *` and `git switch *`, and a session in `<main>` runs `git status` or `git switch main`
- **THEN** the guard asks

### Requirement: git -C naming the checkout a command runs in is dropped before rules match
At the top of the project or one of its own worktrees, the guard SHALL drop a single `git -C <dir>` naming that same directory, absolute or relative, before allow rules match. Any other `-C`, another checkout's top included, and every `-C` when there are several, SHALL stay, so the command matches no allow rule: git would read relative arguments from the other directory.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: -C naming the worktree the session runs in
- **WHEN** an allow rule covers `git status *` and a session at the top of `<project>.worktrees/x` runs `git -C <project>.worktrees/x status`
- **THEN** the guard allows it

#### Scenario: A relative -C naming the same worktree
- **WHEN** an allow rule covers `git status *` and a session at the top of `<project>.worktrees/x` runs `git -C ../x status`
- **THEN** the guard allows it

#### Scenario: -C naming another of the project's checkouts
- **WHEN** an allow rule covers `git log *` and a session at the project root runs `git -C <project>.worktrees/x log --oneline`
- **THEN** the guard returns no allow

#### Scenario: Chained -C
- **WHEN** an allow rule covers `git status *` and a session at the top of `<project>.worktrees/x` runs `git -C . -C . status`
- **THEN** the guard returns no allow

#### Scenario: -C naming a repository outside the project
- **WHEN** an allow rule covers `git status *` and a session runs `git -C /elsewhere/repo status`
- **THEN** the guard returns no allow

#### Scenario: -C from a subdirectory
- **WHEN** a session in `<project>/packages` runs `git -C <project>.worktrees/x status`
- **THEN** the guard returns no allow

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

### Requirement: The main checkout stays on its default branch
Where a command runs in the project's main checkout, after any `git -C`, the guard SHALL deny a `git switch` or `git checkout` that creates a branch, detaches HEAD, or checks out anything but the default branch (`origin/HEAD`, else an existing `main` or `master`, else `main`), in any spelling git accepts, anywhere in a call, pointing to a worktree. A linked worktree or nested repository SHALL be judged as before.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: Creating a branch in the main checkout
- **WHEN** a session at the main checkout's top or in a subdirectory runs `git switch -c feat/x`, `git switch --cr feat/x`, `git switch -qc feat/x`, `git checkout -b feat/x` or `git checkout -qb feat/x`
- **THEN** the guard denies it with "Branch work goes in a worktree: EnterWorktree, or isolation: \"worktree\" on a subagent (git.md)."

#### Scenario: Switching to another branch, a commit or a tag
- **WHEN** a session in the main checkout runs `git switch feat/x`, `git switch -`, `git switch --detach origin/main`, `git checkout v1.0`, `git checkout abc1234` or `git checkout feat/x --`
- **THEN** the guard denies it

#### Scenario: In a chain, behind a wrapper, or through -C
- **WHEN** a session runs `git status && git switch -c feat/x`, `devenv shell --quiet -- git switch -c feat/x`, `bash -c 'git switch -c feat/x'` or, from a linked worktree, `git -C <main> switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: Back to main
- **WHEN** an allow rule covers `git switch *` and a session in the main checkout runs `git switch main`
- **THEN** the guard allows it

#### Scenario: A session started in a linked worktree
- **WHEN** the session's project root is a linked worktree and a command in the main checkout runs `git switch -c feat/x`
- **THEN** the guard denies it, finding the main checkout through the worktree's `.git` file and `commondir`

#### Scenario: A harness worktree
- **WHEN** an allow rule covers `git switch *` and a session in `<main>.worktrees/x` or `<main>/.claude/worktrees/x` runs `git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it

#### Scenario: A nested repository
- **WHEN** a session in `<main>/vendor/lib`, which has its own `.git` directory, runs `git switch -c feat/x`
- **THEN** the guard doesn't deny it

#### Scenario: Another default branch
- **WHEN** `origin/HEAD` names `trunk` and a session in the main checkout runs `git switch trunk` or `git switch main`
- **THEN** the guard allows the first and denies the second

#### Scenario: No origin/HEAD
- **WHEN** a repository has no `origin/HEAD` and only a `master` branch, loose or packed, and a session in its main checkout runs `git switch master` or `git switch main`
- **THEN** the guard allows the first and denies the second

### Requirement: File restores in the main checkout are not branch switches
In the main checkout, the guard SHALL NOT deny a `git checkout` that only restores files or stays put: paths after `--`, a tree-ish and paths, `-p`, `--pathspec-from-file`, `HEAD` or `@`, or a single operand that holds a glob or names an existing path from where it runs and no branch, tag or remote branch. Any other single operand SHALL count as a branch, commit or tag.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: Restoring a file
- **WHEN** a session in the main checkout runs `git checkout -- README.md`, `git checkout HEAD -- README.md`, `git checkout feat/x -- README.md`, `git checkout origin/main README.md`, `git checkout README.md`, `git checkout .` or `git checkout -p`
- **THEN** the guard doesn't deny it

#### Scenario: A file that is gone
- **WHEN** a session in the main checkout runs `git checkout missing.txt`, and no such path exists
- **THEN** the guard denies it as a checkout, and names `git checkout -- <path>` and `git restore`

#### Scenario: HEAD
- **WHEN** a session in the main checkout runs `git checkout HEAD` or `git checkout @`
- **THEN** the guard doesn't deny it, and still denies `git checkout HEAD~1`

#### Scenario: A path that is also a ref
- **WHEN** the main checkout has a `docs/` directory and a `docs` branch, tag or remote branch (loose or in `packed-refs`), and a session there runs `git checkout docs`
- **THEN** the guard denies it, as git checks out the ref, and doesn't deny `git checkout -- docs`

### Requirement: A branch switch after a cd is judged where the cd leads
After a `cd` or `pushd` to an existing literal directory, the guard SHALL judge a `git switch` or `git checkout` from there; a cd in a subshell, pipeline stage or background SHALL NOT carry past it. Where it can't tell (another cd, or `env -C`/`sudo -D`, also through what they run), one that would leave the default branch SHALL ask, unless an absolute `git -C` names where. A deny in the call SHALL win.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: cd into the main checkout
- **WHEN** a session in a linked worktree runs `cd <main> && git switch -c feat/x`, or a session in the main checkout runs `cd sub && git switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: cd within a linked worktree
- **WHEN** a session in a linked worktree runs `cd packages/foo && git switch --no-track -c feat/x origin/main`
- **THEN** the guard doesn't ask or deny it for the main checkout

#### Scenario: A cd in a subshell
- **WHEN** a session in the main checkout runs `(cd <worktree>); git switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: Where the cd leads can't be read
- **WHEN** a session runs `cd "$D" && git switch -c feat/x`, `cd - && git switch -c feat/x`, `env -C <main> git switch -c feat/x` or `env -C <main> bash -c 'git switch -c feat/x'`
- **THEN** the guard asks

#### Scenario: A deny elsewhere wins
- **WHEN** a session runs `cd "$D"; git switch -c feat/x; cargo publish`, and a deny rule covers `cargo publish *`
- **THEN** the guard denies it

#### Scenario: An absolute -C after a cd
- **WHEN** a session runs `cd sub && git -C <main> switch -c feat/x`, or, in the main checkout, `cd /tmp && git -C <main> switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: A cd after the switch
- **WHEN** a session in the main checkout runs `git switch -c feat/x && cd sub`
- **THEN** the guard denies it

### Requirement: A forced worktree remove and worktree add -B get no allow
The guard SHALL give no allow to `git worktree remove` with `-f` in any cluster or any prefix git accepts of `--force`, or to `git worktree add -B`, alone or in a cluster (`-qB`), so an allow rule naming `git worktree` asks.

Tested by: `claude-guard-test.py`, the #87 cases.

#### Scenario: A forced remove in a shorter spelling
- **WHEN** an allow rule covers `git worktree *` and a session runs `git worktree remove --fo wt`, `git worktree remove -f wt` or `git worktree remove wt --forc`
- **THEN** the guard asks, and still allows `git worktree remove wt`

#### Scenario: Resetting a branch with -B
- **WHEN** an allow rule covers `git worktree *` and a session runs `git worktree add -B feat/x wt origin/main` or `git worktree add -qB feat/x wt origin/main`
- **THEN** the guard asks, and still allows `git worktree add -b feat/x wt origin/main`

### Requirement: A linked worktree creates and switches branches without a prompt
Under the module's `git switch` allow and ask rules, in a linked worktree of the project, the guard SHALL allow `git switch -c` or `--create <type>/<name> [start]` with `--no-track` or from a start point that sets up no tracking, `git switch <branch>` and `git switch -`, wherever the session is rooted. `-C` SHALL be judged as before, apart from the tracking deny above; the forced forms SHALL still ask.

Tested by: `claude-guard-test.py`, the #44 cases in the "main checkout stays on main" block.

#### Scenario: A new branch from origin/main
- **WHEN** a session rooted in the main checkout or in the worktree runs, in `<main>.worktrees/x` or `<main>/.claude/worktrees/x`, `git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it, with no permission prompt

#### Scenario: Other untracked create forms
- **WHEN** a session in a linked worktree runs `git switch -c feat/x`, `git switch --no-track --create feat/x origin/main`, `devenv shell --quiet -- git switch --no-track -c feat/x origin/main` or `git fetch origin main && git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it

#### Scenario: The forced forms
- **WHEN** a session in a linked worktree runs `git switch -f feat/x`, `git switch -fc feat/x` or `git switch --discard-changes feat/x`
- **THEN** the guard asks

### Requirement: A branch create that would set up tracking is denied
In the project's main checkout or a linked worktree of its repository, the guard SHALL deny a `git switch` or `git checkout` that would write tracking configuration: one whose last tracking option is `--track` or `-t`, or one creating a branch from a remote-tracking start point with no tracking option. The reason SHALL name `--no-track`. Anything else SHALL be judged as before.

Tested by: `claude-guard-test.py`, the #45 cases in the "main checkout stays on main" block.

#### Scenario: A new branch from a remote branch
- **WHEN** an allow rule covers `git switch *`, `origin/main` is a remote-tracking branch (loose or in `packed-refs`), and a session in `<main>.worktrees/x` or `<main>/.claude/worktrees/x` runs `git switch -c feat/x origin/main`, `git switch --create feat/x origin/main`, `git switch -C feat/x origin/main` or `git checkout -b feat/x origin/main`
- **THEN** the guard denies it, and the reason says the command would write tracking configuration to `.git/config`, which the sandbox protects, and to add `--no-track`

#### Scenario: Asked for by option
- **WHEN** a session in a linked worktree runs `git switch --track -c feat/x origin/main`, `git switch -t origin/feat/x`, `git checkout --track origin/feat/x` or `git checkout -tb feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: With --no-track
- **WHEN** a session in a linked worktree runs `git switch --no-track -c feat/x origin/main`, `git switch -c feat/x --no-track origin/main` or `git switch --track --no-track -c feat/x origin/main`
- **THEN** the guard doesn't deny it for tracking, and the first two are allowed under a `git switch *` allow rule

#### Scenario: The last tracking option wins
- **WHEN** a session in a linked worktree runs `git switch --no-track --track -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: A start point that sets up no tracking
- **WHEN** a session in a linked worktree runs `git switch -c feat/x`, `git switch -c feat/x main`, `git switch -c feat/x origin/main~1`, or `git switch -c feat/x origin/gone` where no such remote-tracking branch exists
- **THEN** the guard doesn't deny it for tracking

#### Scenario: No branch is made
- **WHEN** a session in a linked worktree runs `git switch --detach origin/main`, `git switch --orphan feat/x`, `git switch feat/x` or `git checkout origin/main -- README.md`
- **THEN** the guard doesn't deny it for tracking

#### Scenario: In a chain, behind a wrapper, or after a cd
- **WHEN** a session in a linked worktree runs `git fetch origin main && git switch -c feat/x origin/main`, `devenv shell --quiet -- git switch -c feat/x origin/main`, `bash -c 'git switch -c feat/x origin/main'` or `cd packages/foo && git switch -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: From the main checkout, through -C
- **WHEN** a session in the main checkout runs `git -C <main>.worktrees/x switch -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: In the main checkout itself
- **WHEN** a session in the main checkout runs `git switch -c feat/x origin/main`
- **THEN** the guard denies it with the main checkout's reason, pointing to a worktree, as before

#### Scenario: A nested repository
- **WHEN** a session in `<main>/vendor/lib`, which has its own `.git` directory, runs `git switch -c feat/x origin/main`
- **THEN** the guard decides it as before

### Requirement: A devenv version or help query only reads
The guard SHALL approve a devenv version or help query, spelled exactly as the scenarios show, as a command that only reads, with no allow rule, bare or behind `devenv shell --`; devenv prints the text and exits before anything runs. Ask and deny rules SHALL still apply to it. Any other `devenv` command line SHALL be judged as before.

Tested by: `claude-guard-test.py`, the "Module allow list" block.

#### Scenario: The version query
- **WHEN** a session runs `devenv --version`, `devenv -V` or `devenv version`, or `devenv shell --quiet -- devenv --version`, and no rule names any of them
- **THEN** the guard allows it

#### Scenario: The help query
- **WHEN** a session runs `devenv --help`, `devenv -h`, `devenv help`, `devenv shell --help`, `devenv tasks -h` or `devenv help shell`, bare or wrapped, and no rule names any of them
- **THEN** the guard allows it

#### Scenario: Help with anything more, or for no subcommand
- **WHEN** a session runs `devenv --help shell`, `devenv shell --help extra`, `devenv shell --help -- rm -rf x`, `devenv -q shell --help` or `devenv --hel`
- **THEN** the guard asks; `devenv bogus --help`, `devenv help bogus` and `devenv help shell extra` get no allow

#### Scenario: In a chain or a pipeline
- **WHEN** an allow rule covers `git status *` and a session runs `devenv --version && git status` or `devenv --version | head -1`
- **THEN** the guard allows it

#### Scenario: An ask or deny rule
- **WHEN** the ask rules list `devenv *`, or the deny rules do, and a session runs `devenv --version`
- **THEN** the guard asks, or denies it

#### Scenario: Anything after the option
- **WHEN** a session runs `devenv --version shell -- rm -rf x`, `devenv --version extra` or `devenv --quiet --version`
- **THEN** the guard asks, as it does for any devenv option it doesn't know

#### Scenario: A forbidden command after the option
- **WHEN** a session runs `devenv -V shell -- git push --force`
- **THEN** the guard denies it

#### Scenario: Another spelling of the program or the option
- **WHEN** a session runs `/nix/store/x/bin/devenv --version` or `devenv --versio`
- **THEN** the guard asks

#### Scenario: Other subcommands
- **WHEN** a session runs `devenv update`, `devenv up`, `devenv version extra` or `devenv shell --quiet -- rm -rf build`
- **THEN** the guard returns no allow

#### Scenario: With another command or a redirect
- **WHEN** a session runs `devenv --version; rm -rf build` or `devenv --version > out.txt`
- **THEN** the guard returns no allow for the first and denies the second as a write to a project file

### Requirement: The module's allowed commands are allowed bare and wrapped
Against the allow list the module ships, the guard SHALL allow the routine forms of each command reported in issues #42, #43, #61, #62, #85 and #86, run bare and run behind `devenv shell --quiet --` alike. Its tests SHALL hold a copy of that list and fail when the copy differs from `devenv.nix` in a run from the checkout, the gate's; the package build has no `devenv.nix` to compare.

Tested by: `claude-guard-test.py`, the "Module allow list" table.

#### Scenario: Read-only git
- **WHEN** a session runs `git log`, `git log --oneline -5`, `git log --oneline | head -5`, `git log -p -1`, `git -C . log --oneline -5`, `git status` or `git diff origin/main...HEAD`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: -C naming the checkout the session is in
- **WHEN** a session at the top of the project runs `git -C <that directory> log --oneline -5` or `git -C <that directory> status`
- **THEN** the guard allows it

#### Scenario: -C naming another directory
- **WHEN** a session runs `git -C /elsewhere log`
- **THEN** the guard returns no allow

#### Scenario: A git command no rule names
- **WHEN** a session runs `git show HEAD`, `git blame README.md` or `git rev-parse HEAD`
- **THEN** the guard returns no allow

#### Scenario: Issues and pull requests as the App
- **WHEN** a session runs `gh-app issue view 42 --json title,body,comments`, `gh-app issue list --state open --search guard`, `gh-app pr list`, or `gh-app issue create --title t` with a single-quoted multi-line `--body`, a plain double-quoted one, `--body-file "$TMPDIR/body.md"` or `--body-file` and an absolute scratch path, bare or wrapped
- **THEN** the guard allows it

#### Scenario: A body the shell would expand
- **WHEN** a session runs `gh-app issue create --title t --body` with a double-quoted body holding a backtick-quoted `git status` or `$HOME`, or a body written as `"$(cat <<'EOF' ... EOF)"`
- **THEN** the guard returns no allow; with `gh pr merge 5` between the backticks it denies the call, since the shell would run it

#### Scenario: A body on stdin that quotes forbidden commands
- **WHEN** a session runs `gh-app issue create --title t --body-file - <<'EOF'` with a body `Run gh pr merge 55 --auto --squash, then git push --force.`, alone or with `2>&1 | grep 'https://'` after the opener
- **THEN** the guard allows it

#### Scenario: Auto-merge as the App
- **WHEN** a session runs `gh-app pr merge 31 --auto --squash`, `gh-app pr merge 31 -R coldlogicsolutions/claude-plugins-coldlogic --auto --squash` or `gh-app pr merge --auto --squash 31`, bare or wrapped
- **THEN** the guard allows it, and still denies `gh pr merge 31 --auto --squash`

#### Scenario: A comment on another repository's issue
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue comment 49 -R coldlogicsolutions/coldlogic-devenv --body-file` and an absolute scratch path, or the same with a plain `--body`
- **THEN** the guard allows it

#### Scenario: A cd before the command
- **WHEN** a session runs `cd /Users/x/Projects/infrastructure && devenv shell --quiet -- gh-app issue comment 78 -R coldlogicsolutions/coldlogic-devenv --body x`
- **THEN** the guard returns no allow

#### Scenario: A gh function, bare and behind the wrapper
- **WHEN** a session runs `gh() { devenv shell --quiet -- gh-app "$@"; }` and then `gh pr merge 55 --auto --squash`
- **THEN** the guard asks; with `devenv shell --quiet -- ` before the definition, which wraps only its first line, the guard can't read the call, and its rough reading denies it for `gh pr merge`
