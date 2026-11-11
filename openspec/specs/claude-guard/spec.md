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
The guard SHALL deny file-tool writes inside a `.git` directory. It SHALL ask before file tools change the project's `.claude` directory, except inside the checkouts under `.claude/worktrees/<name>/`. That directory itself, and the `.claude` directory of any of the project's own worktrees, SHALL still ask.

Tested by: `claude-guard-test.py`, `FILES`, the `.claude` block and the "project's own worktrees" block.

#### Scenario: Writing git config
- **WHEN** a session writes `/p/nested/.git/config`
- **THEN** the guard denies it

#### Scenario: Editing project settings
- **WHEN** a session edits `<root>/.claude/settings.json` and it is a regular file
- **THEN** the guard asks (when it is devenv's symlink into the Nix store, the guard resolves it outside the project and leaves the call to Claude Code's rules)

#### Scenario: Writing inside a worktree under .claude
- **WHEN** a session writes `<root>/.claude/worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Editing settings inside a worktree
- **WHEN** a session edits `<root>/.claude/worktrees/x/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Editing a skill inside a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/skills/y/SKILL.md` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing the main checkout's settings from a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: Writing source in a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` writes `<project>.worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

### Requirement: Ask and deny rules apply inside wrappers
The guard SHALL match the session's deny and ask rules against both the command as written and each command it unwraps, including git with its global options dropped.

Tested by: `claude-guard-test.py`, the policy block and "A wrapper's own allow rule doesn't reach inside it".

#### Scenario: Deny rule behind a wrapper
- **WHEN** the deny rules list `cargo publish *` and a session runs `devenv shell -- cargo publish`
- **THEN** the guard denies it

#### Scenario: Deny rule behind an inert git option
- **WHEN** the deny rules list `git push *` and a session runs `git --literal-pathspecs push origin x`
- **THEN** the guard denies it

### Requirement: Only plain commands named by an allow rule are allowed
The guard SHALL allow a Bash call only when it is one plain command, optionally behind `devenv shell --` and piped into `tail`, `head`, `grep` or `wc`, that an allow rule names or that only reads inside the project. A plain command has no expansion, `cd`, file redirect, config override or construct the guard doesn't follow.

Tested by: `claude-guard-test.py`, "Allowed when every command inside matches" and the review sections.

#### Scenario: Wrapped allowed command
- **WHEN** the allow rules list `scripts/check.sh` and a session runs `devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40`
- **THEN** the guard allows it

#### Scenario: A rule for the wrapper doesn't allow what's inside
- **WHEN** the allow rules list `devenv shell *` and a session runs `devenv shell --quiet -- rm -rf build`
- **THEN** the guard asks

#### Scenario: Commit with a heredoc message
- **WHEN** a session runs `git commit -m "$(cat <<'EOF' ... EOF)"` and an allow rule covers `git commit *`
- **THEN** the guard allows it, treating the message as data

#### Scenario: Allowed program with a risky option
- **WHEN** an allow rule covers `git diff *` and a session runs `git diff --output=out.patch`
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
The guard SHALL count a directory as one of the project's own worktrees, wherever it sits, only when its `.git` file names a directory under the project's `.git/worktrees`, that directory's `gitdir` names it back, and its `commondir` resolves to the project's `.git`.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: An agent worktree beside the project
- **WHEN** `<project>.worktrees/x` was made by `git worktree add` from the project
- **THEN** the guard counts it as one of the project's own worktrees

#### Scenario: Metadata that doesn't name the directory back
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, but that directory's `gitdir` names another directory
- **THEN** the guard doesn't count it as one of the project's worktrees

### Requirement: The project's own worktrees are judged like its root
At the top of one of the project's own worktrees, or in a subdirectory of one with no other repository in between, a command SHALL get the same decision it would get in the project root. Paths inside such a worktree SHALL count as inside the project.

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

### Requirement: git -C naming one of the project's checkouts is dropped before rules match
When a command runs at the top of the project or one of its own worktrees, the guard SHALL drop a `git -C <dir>` whose `<dir>` is the top of the project or of one of its own worktrees, before allow rules match. Any other `-C` value SHALL stay, so the command matches no allow rule.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: -C naming the worktree the session runs in
- **WHEN** an allow rule covers `git status *` and a session at the top of `<project>.worktrees/x` runs `git -C <project>.worktrees/x status`
- **THEN** the guard allows it

#### Scenario: -C naming another of the project's checkouts
- **WHEN** an allow rule covers `git log *` and a session at the project root runs `git -C <project>.worktrees/x log --oneline`
- **THEN** the guard allows it

#### Scenario: -C naming a repository outside the project
- **WHEN** an allow rule covers `git status *` and a session runs `git -C /elsewhere/repo status`
- **THEN** the guard returns no allow

#### Scenario: -C from a subdirectory
- **WHEN** a session in `<project>/packages` runs `git -C <project>.worktrees/x status`
- **THEN** the guard returns no allow
