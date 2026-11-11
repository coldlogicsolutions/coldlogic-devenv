# Spec Delta

## MODIFIED Requirements

### Requirement: Edits inside the checkout need no prompt
The module SHALL allow Edit and Write anywhere under the checkout's root, and anywhere under the main checkout's sibling worktree directory (`<main checkout>.worktrees`), as absolute rules written per checkout, without changing the user's chosen permission mode. Deny rules and the guard's asks SHALL still take precedence.

Tested by: none.

#### Scenario: Editing a source file
- **WHEN** a session edits `src/main.rs` in the checkout
- **THEN** no permission prompt appears

#### Scenario: Editing in an agent's worktree
- **WHEN** a subagent edits `<main checkout>.worktrees/agent-x/src/main.rs`
- **THEN** no permission prompt appears

### Requirement: The sandbox denies secrets and gpg configuration
The sandbox SHALL deny reads of `.env`, its usual local and environment variants and `secrets/**`, both at the checkout root and below it, and likewise at the top of each of the main checkout's sibling worktrees (`<main checkout>.worktrees/<name>`) and below it. It SHALL deny writes to `.env` in all of those places, and to gpg's configuration files and private keys, while allowing writes to the rest of the gpg home so commits can be signed.

Tested by: none.

#### Scenario: Reading a variant from a command
- **WHEN** a sandboxed command reads `.env.production` at the checkout root
- **THEN** the sandbox denies it

#### Scenario: Reading a secret in an agent's worktree
- **WHEN** a sandboxed command reads `<main checkout>.worktrees/agent-x/.env`
- **THEN** the sandbox denies it

#### Scenario: Changing an agent worktree's git link or Claude Code config
- **WHEN** a sandboxed command writes `<main checkout>.worktrees/agent-x/.git`, its `.claude/settings.json` or `.claude/settings.local.json`, or anything under its `.claude/hooks` or `.claude/skills`
- **THEN** the sandbox denies it

#### Scenario: Example file stays readable
- **WHEN** a sandboxed command reads `.env.example`
- **THEN** the sandbox allows it

### Requirement: The sandbox reaches only what the shared tools need
The sandbox SHALL allow writes to the nix, devenv, prek and npm caches, the gpg home, the main checkout's sibling worktree directory (`<main checkout>.worktrees`) and devenv's runtime directories (`/tmp/devenv-*`). It SHALL allow the nix daemon and gpg-agent sockets and local binding. It SHALL allow GitHub, Nix and cachix hosts, the npm registry, documentation hosts and GitHub Actions log storage. A profile or project SHALL add to these lists.

Tested by: manually, pending in #64.

#### Scenario: Reading a CI log
- **WHEN** a session runs `gh run view --log`
- **THEN** the sandbox lets it reach the Actions results service and its storage accounts

#### Scenario: A profile adds its registry
- **WHEN** a project uses the `rust-lib` profile
- **THEN** `crates.io` joins the module's allowed domains rather than replacing them

#### Scenario: devenv shell in an agent's worktree
- **WHEN** a subagent runs `devenv shell --quiet -- true` in `<main checkout>.worktrees/agent-x`
- **THEN** the sandbox lets it write that worktree's `.devenv` directory (pending verification in #64)

#### Scenario: A fresh worktree's first shell
- **WHEN** a session runs `devenv shell` for the first time in a worktree whose `/tmp/devenv-<hash>` doesn't exist yet
- **THEN** the sandbox lets devenv create it and write inside it (pending verification in #64: whether the sandbox honours the `/tmp/devenv-*` globs)

#### Scenario: Settings generated from a worktree
- **WHEN** the shell is entered from `<main checkout>.worktrees/x`, whose `.git` file names `<main checkout>/.git/worktrees/x`
- **THEN** the generated allowWrite and Edit rule name `<main checkout>.worktrees`, not `<main checkout>.worktrees/x.worktrees`

#### Scenario: Settings generated from a worktree with a relative gitdir
- **WHEN** the shell is entered from `<main checkout>.worktrees/x`, whose `.git` file reads `gitdir: ../../<main>/.git/worktrees/x`
- **THEN** the generated allowWrite and Edit rule name `<main checkout>.worktrees`

#### Scenario: A .git file of another kind
- **WHEN** the shell is entered from a checkout whose `.git` file doesn't name a directory under some `.git/worktrees` (a submodule's, say)
- **THEN** the generated rules name `<that checkout>.worktrees`

#### Scenario: Another project's worktrees stay closed
- **WHEN** a session runs a command that writes under `<other project>.worktrees`
- **THEN** the sandbox denies it
