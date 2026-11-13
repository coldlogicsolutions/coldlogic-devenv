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
The module SHALL allow `scripts/check.sh`, `openspec`, git's `status`, `diff`, `log`, `add`, `commit`, `switch`, `branch`, `worktree`, `fetch` and `rev-list`, and gh-app's `pr view|checks|create|merge|list|comment` and `issue create|view|list|comment|edit`. It SHALL ask for the forcing and discarding variants of `git switch`, `git branch` and `git worktree remove`. Project rules SHALL add to these lists.

Tested by: none for the lists; `claude-guard-test.py` tests the guard's reading of them.

#### Scenario: Forced branch deletion
- **WHEN** a session runs `git branch -D feat`
- **THEN** Claude Code asks first

#### Scenario: Project adds an allow rule
- **WHEN** a project adds `git merge *` to `claude.code.permissions.rules.Bash.allow`
- **THEN** the generated settings allow both the module's rules and `git merge *`

#### Scenario: Viewing an issue as the App
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue view 36`
- **THEN** no permission prompt appears

#### Scenario: Commenting on an issue as the App
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue comment 36 --body-file "$TMPDIR/body.md"`
- **THEN** no permission prompt appears

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

### Requirement: Generated settings name the checkout they were generated for
The generated Claude Code settings SHALL set `COLDLOGIC_SESSION_ROOT` to the root of the checkout they were generated in. A session carries it into every command it runs, so a shell entered elsewhere can tell that it isn't in the checkout the session reads its Claude Code files from (session-notices).

Tested by: none.

#### Scenario: Generated settings name the checkout
- **WHEN** the shell is entered in a checkout and the settings are generated
- **THEN** `.env.COLDLOGIC_SESSION_ROOT` in that checkout's `.claude/settings.json` is that checkout's root

#### Scenario: A command in a worktree the session entered
- **WHEN** a session started in the main checkout runs a command in a worktree made with EnterWorktree or for a subagent
- **THEN** the command's environment still has `COLDLOGIC_SESSION_ROOT` naming the main checkout

### Requirement: Memory reads and saves are allowed
When the memory store is configured (shared-memory), the module SHALL allow the `memory` server's `memory_search`, `memory_list`, `memory_health`, `memory_stats` and `memory_store` tools, each by its full name and never by a pattern over the whole server. Without the store, no memory rule SHALL be generated.

Tested by: the settings self-check in `devenv.nix`, in the gate's configured build.

#### Scenario: Searching
- **WHEN** a session calls `mcp__memory__memory_search`
- **THEN** no permission prompt appears

#### Scenario: Saving
- **WHEN** a session calls `mcp__memory__memory_store`
- **THEN** no permission prompt appears

#### Scenario: A tool the rules don't name
- **WHEN** a session calls a `memory` tool that has no rule, such as `mcp__memory__memory_graph` or one a later version of the service adds
- **THEN** the user's permission mode decides, as for any tool without a rule

#### Scenario: Store not configured
- **WHEN** the settings are generated without `COLDLOGIC_MEMORY_URL`
- **THEN** the module adds no rule starting `mcp__memory__`, `mcp__claude_ai_memory__` or `mcp__claude_ai_Memory__`, no `memory` server and no memory variable
- **AND** a project's own rules, servers and variables are kept, those named `memory` included, and the self-check doesn't count them against the module
- **AND** the merged settings have no hook named `coldlogic-memory-recall` and no `SessionStart` hook that runs it, so wiring that loses its condition fails the self-check

#### Scenario: A project that replaces the MCP servers
- **WHEN** the store is configured and a project sets `claude.code.mcpServers` with `lib.mkForce`, replacing the module's servers
- **THEN** the self-check reads the module's own server definition, which holds `mcp.devenv.sh` and `memory`, and the shell still builds

### Requirement: Destructive memory tools ask
When the memory store is configured, the module SHALL ask for the `memory` server's tools that change or remove stored memories: `memory_delete`, `memory_update`, `memory_cleanup`, `memory_consolidate`, `memory_quality`, `memory_resolve`, `memory_distill`, `mistake_note_update`, `mistake_note_delete` and `unquarantine_memory`. None of them SHALL also be allowed.

Tested by: the settings self-check in `devenv.nix`, in the gate's configured build; manually against the live store.

#### Scenario: Deleting
- **WHEN** a session calls `mcp__memory__memory_delete`, in any permission mode that can prompt
- **THEN** Claude Code asks first

#### Scenario: Consolidating
- **WHEN** a session calls `mcp__memory__memory_consolidate` or `mcp__memory__memory_cleanup`
- **THEN** Claude Code asks first

### Requirement: Local sessions use only the tailnet memory server
When the memory store is configured, the module SHALL deny the tools of the claude.ai connector for the same store, named `Memory` or `memory` (`mcp__claude_ai_Memory__*`, `mcp__claude_ai_memory__*`: tool names keep the display name's case), so a local session sees one set of memory tools and every memory call is covered by the rules above. A connector with any other name isn't covered.

Tested by: the settings self-check in `devenv.nix`; manually in a session with the connector added.

#### Scenario: The connector is added to the account
- **WHEN** a local session starts with the store configured, on an account that has the connector, named `Memory` or `memory`
- **THEN** the session has the `mcp__memory__*` tools and none named `mcp__claude_ai_Memory__*` or `mcp__claude_ai_memory__*`

#### Scenario: A connector under another name
- **WHEN** the account's connector for the store is named anything else, such as `Shared Memory`
- **THEN** its tools aren't denied, and the session sees both sets

### Requirement: Session commands can't reach the memory store
The module SHALL NOT let the sandbox's allowed domains cover the memory store's host, by its name or by a wildcard that matches it, with any port or case. Only the MCP server connection and the recall hook, both outside the Bash sandbox, reach it, so no command a session runs can read, change or delete memories through the REST API around the rules above.

Tested by: the settings self-check in `devenv.nix`, in the gate's configured build; manually against the live store.

#### Scenario: Deleting over REST from a command
- **WHEN** a session runs `curl -X DELETE "$COLDLOGIC_MEMORY_URL/api/memories/<hash>"` in the sandbox
- **THEN** the sandbox refuses the connection

#### Scenario: Generated domains
- **WHEN** the settings are generated with `COLDLOGIC_MEMORY_URL=https://memory.example.ts.net`
- **THEN** `sandbox.network.allowedDomains` doesn't hold `memory.example.ts.net`

#### Scenario: A wildcard that covers the host
- **WHEN** the generated allowed domains would hold `*.example.ts.net`, `*.ts.net`, `*` or `*.EXAMPLE.ts.net:443` with `COLDLOGIC_MEMORY_URL=https://memory.example.ts.net`
- **THEN** the settings self-check fails, so the shell doesn't build, even where the project added the entry itself
- **AND** the failure names each covering entry and the host, and says to narrow the entry or unset `COLDLOGIC_MEMORY_URL`
- **AND** `example.ts.net` or `*.other.ts.net` alone doesn't fail it
