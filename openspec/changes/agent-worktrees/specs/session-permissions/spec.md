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
