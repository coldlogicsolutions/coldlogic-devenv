# session-permissions Specification

## Purpose
The Claude Code permission rules, model defaults and sandbox settings that the module writes into every project's generated settings. Together they let routine work run without prompts while blocking the common mistakes.

## Requirements

### Requirement: Model defaults are overridable
The developer profile SHALL default sessions to the `opus` model and subagents with no model of their own to `sonnet` (`CLAUDE_CODE_SUBAGENT_MODEL`). It SHALL set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. A project SHALL be able to override both model defaults.

Tested by: none.

#### Scenario: Project picks its own model
- **WHEN** a project sets `claude.code.model = "sonnet"`
- **THEN** its generated settings name `sonnet`

### Requirement: Routine commands are allowed and destructive variants ask
The module SHALL allow `scripts/check.sh`, the read and commit `git` subcommands (`status`, `diff`, `log`, `add`, `commit`, `switch`, `branch`, `worktree`), `gh-app pr view|checks|create|merge`, `gh-app issue create` and `openspec`. It SHALL ask for the forcing and discarding variants of `git switch`, `git branch` and `git worktree remove`. Project rules SHALL add to these lists.

Tested by: none (rule lists); the guard's handling of them is tested in `claude-guard-test.py`.

#### Scenario: Forced branch deletion
- **WHEN** a session runs `git branch -D feat`
- **THEN** Claude Code asks first

#### Scenario: Project adds an allow rule
- **WHEN** a project adds `git merge *` to `claude.code.permissions.rules.Bash.allow`
- **THEN** the generated settings allow both the module's rules and `git merge *`

### Requirement: Forbidden commands have plain deny rules
The module SHALL deny the plain spellings of force pushes, `git reset --hard`, `wrangler deploy`, `npx wrangler deploy` and `nix develop`, both bare and with arguments, as a fallback for when the guard hook doesn't run.

Tested by: none.

#### Scenario: Bare spelling
- **WHEN** a session runs `git push --force` and the guard hook isn't running
- **THEN** Claude Code's deny rules still refuse it

### Requirement: Secrets are denied to Read and Edit at any depth
The module SHALL add Read and Edit deny rules for `**/.env` and `**/secrets/**`.

Tested by: none.

#### Scenario: Nested secrets directory
- **WHEN** a session reads `app/secrets/key.pem` with the Read tool
- **THEN** Claude Code denies it

### Requirement: Edits inside the checkout need no prompt
The module SHALL allow Edit and Write anywhere under the checkout's root, and anywhere under the main checkout's sibling worktree directory (`<main checkout>.worktrees`), as absolute rules written per checkout, without changing the user's chosen permission mode. Deny rules and the guard's asks SHALL still take precedence.

Tested by: none.

#### Scenario: Editing a source file
- **WHEN** a session edits `src/main.rs` in the checkout
- **THEN** no permission prompt appears

#### Scenario: Editing in an agent's worktree
- **WHEN** a subagent edits `<main checkout>.worktrees/agent-x/src/main.rs`
- **THEN** no permission prompt appears

### Requirement: Bash runs sandboxed with no escape
The generated settings SHALL enable the sandbox, auto-allow Bash commands that run in it, disallow running commands outside it, and enable weaker network isolation so `gh` can verify TLS on macOS.

Tested by: none.

#### Scenario: Command blocked by the sandbox
- **WHEN** a sandboxed command fails because the sandbox blocks a write
- **THEN** Claude Code doesn't retry it outside the sandbox

### Requirement: The sandbox denies secrets and gpg configuration
The sandbox SHALL deny reads of `.env`, its usual local and environment variants and `secrets/**`, both at the checkout root and below it. It SHALL deny writes to `.env` and to gpg's configuration files and private keys, while allowing writes to the rest of the gpg home so commits can be signed.

Tested by: none.

#### Scenario: Reading a variant from a command
- **WHEN** a sandboxed command reads `.env.production` at the checkout root
- **THEN** the sandbox denies it

#### Scenario: Example file stays readable
- **WHEN** a sandboxed command reads `.env.example`
- **THEN** the sandbox allows it

### Requirement: The sandbox reaches only what the shared tools need
The sandbox SHALL allow writes to the nix, devenv, prek and npm caches, the gpg home, the main checkout's sibling worktree directory (`<main checkout>.worktrees`) and devenv's runtime directories (`/tmp/devenv-*`). It SHALL allow the nix daemon and gpg-agent sockets and local binding. It SHALL allow GitHub, Nix and cachix hosts, the npm registry, documentation hosts and GitHub Actions log storage. A profile or project SHALL add to these lists.

Tested by: none.

#### Scenario: Reading a CI log
- **WHEN** a session runs `gh run view --log`
- **THEN** the sandbox lets it reach the Actions results service and its storage accounts

#### Scenario: A profile adds its registry
- **WHEN** a project uses the `rust-lib` profile
- **THEN** `crates.io` joins the module's allowed domains rather than replacing them

#### Scenario: devenv shell in an agent's worktree
- **WHEN** a subagent runs `devenv shell --quiet -- true` in `<main checkout>.worktrees/agent-x`
- **THEN** the sandbox lets it write that worktree's `.devenv` directory

#### Scenario: A fresh worktree's first shell
- **WHEN** a session runs `devenv shell` for the first time in a worktree whose `/tmp/devenv-<hash>` doesn't exist yet
- **THEN** the sandbox lets devenv create it

#### Scenario: Settings generated from a worktree
- **WHEN** the shell is entered from `<main checkout>.worktrees/x`, whose `.git` file names `<main checkout>/.git/worktrees/x`
- **THEN** the generated allowWrite and Edit rule name `<main checkout>.worktrees`, not `<main checkout>.worktrees/x.worktrees`

#### Scenario: Another project's worktrees stay closed
- **WHEN** a session runs a command that writes under `<other project>.worktrees`
- **THEN** the sandbox denies it
