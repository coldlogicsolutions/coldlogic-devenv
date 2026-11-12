# Spec Delta

## ADDED Requirements

### Requirement: Generated settings name the checkout they were generated for
The generated Claude Code settings SHALL set `COLDLOGIC_SESSION_ROOT` to the root of the checkout they were generated in. A session carries it into every command it runs, so a shell entered elsewhere can tell that it isn't in the checkout the session reads its Claude Code files from (session-notices).

Tested by: none.

#### Scenario: Generated settings name the checkout
- **WHEN** the shell is entered in a checkout and the settings are generated
- **THEN** `.env.COLDLOGIC_SESSION_ROOT` in that checkout's `.claude/settings.json` is that checkout's root

#### Scenario: A command in a worktree the session entered
- **WHEN** a session started in the main checkout runs a command in a worktree made with EnterWorktree or for a subagent
- **THEN** the command's environment still has `COLDLOGIC_SESSION_ROOT` naming the main checkout

## MODIFIED Requirements

### Requirement: The sandbox reaches only what the shared tools need
The sandbox SHALL allow writes to the nix, devenv, prek and npm caches, the gpg home and the main checkout's sibling worktree directory (`<main checkout>.worktrees`). It SHALL allow the nix daemon and gpg-agent sockets and local binding. It SHALL allow GitHub, Nix and cachix hosts, the npm registry, documentation hosts and GitHub Actions log storage. A profile or project SHALL add to these lists.

Tested by: manually, by the checklist in the #64 follow-up.

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
- **WHEN** a session runs `devenv shell` for the first time in a worktree whose runtime dir doesn't exist yet
- **THEN** the sandbox lets devenv create it under the devenv cache and write inside it

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

### Requirement: Sessions keep devenv's runtime dirs in the devenv cache
The generated Claude Code settings SHALL set `XDG_RUNTIME_DIR` to `<home>/.cache/devenv/run`, so `devenv shell` in a session creates its runtime dir inside a path the sandbox already allows, and a session SHALL need no `/tmp` write access for it.

Tested by: manually, by the checklist in the #64 follow-up.

#### Scenario: Generated settings name the runtime dir
- **WHEN** the shell is entered and the settings are generated
- **THEN** `.env.XDG_RUNTIME_DIR` in `.claude/settings.json` is `<home>/.cache/devenv/run`

#### Scenario: A new agent worktree's runtime dir
- **WHEN** a session runs `devenv shell --quiet -- true` for the first time in a new `<main checkout>.worktrees/agent-x`
- **THEN** devenv creates `<home>/.cache/devenv/run/devenv-<hash>` and the command doesn't fail on the sandbox
