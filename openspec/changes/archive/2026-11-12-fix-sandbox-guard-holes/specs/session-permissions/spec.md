# Spec Delta

## MODIFIED Requirements

### Requirement: The sandbox denies secrets and gpg configuration
The sandbox SHALL deny reads of `.env`, its usual local and environment variants and `secrets/**`, both at the checkout root and below it, and likewise at the top of each of the main checkout's sibling worktrees (`<main checkout>.worktrees/<name>`) and below it. It SHALL deny writes to `.env` and `secrets/**` in all of those places, and to gpg's configuration files and private keys, while allowing writes to the rest of the gpg home so commits can be signed.

Tested by: none.

#### Scenario: Reading a variant from a command
- **WHEN** a sandboxed command reads `.env.production` at the checkout root
- **THEN** the sandbox denies it

#### Scenario: Reading a secret in an agent's worktree
- **WHEN** a sandboxed command reads `<main checkout>.worktrees/agent-x/.env`
- **THEN** the sandbox denies it

#### Scenario: Writing under a secrets directory from a command
- **WHEN** a sandboxed command writes `secrets/key.pem` at the checkout root, `app/secrets/key.pem` below it, or either path in `<main checkout>.worktrees/agent-x`
- **THEN** the sandbox denies it

#### Scenario: Generated settings list the secrets write denies
- **WHEN** the shell is entered and the settings are generated
- **THEN** `sandbox.filesystem.denyWrite` in `.claude/settings.json` holds `<root>/secrets/**`, `<root>/**/secrets/**`, `<main checkout>.worktrees/*/secrets/**` and `<main checkout>.worktrees/*/**/secrets/**`

#### Scenario: Changing an agent worktree's git link or Claude Code config
- **WHEN** a sandboxed command writes `<main checkout>.worktrees/agent-x/.git`, its `.claude/settings.json` or `.claude/settings.local.json`, or anything under its `.claude/hooks` or `.claude/skills`
- **THEN** the sandbox denies it

#### Scenario: Example file stays readable
- **WHEN** a sandboxed command reads `.env.example`
- **THEN** the sandbox allows it
