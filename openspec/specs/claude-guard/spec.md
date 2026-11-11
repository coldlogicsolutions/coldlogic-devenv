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
The guard SHALL deny Edit, Write, MultiEdit and NotebookEdit on a path inside a `.git` directory. It SHALL ask before they change a path in the project's `.claude` directory, except inside `.claude/worktrees/<name>/`, which are checkouts of the project. The worktree directory itself, and a `.claude` directory inside a worktree, SHALL still ask.

Tested by: `claude-guard-test.py`, `FILES` and the `.claude` block.

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
