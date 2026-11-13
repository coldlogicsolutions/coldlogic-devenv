# Spec Delta

## ADDED Requirements

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
