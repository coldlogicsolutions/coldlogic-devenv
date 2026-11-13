# Proposal

## Why

Claude Code's auto memory is one directory per project on one machine. Nothing is shared between projects, machines or cloud sessions, and a session can't delete its own memory files, because the sandbox protects `~/.claude` (#83). Derek decided on 2026-11-13 (#107) to replace it with one self-hosted mcp-memory-service store, scoped by tags. The service itself is hosted from his dotfiles repository. This change is the client side: what a project on this module needs so that its local sessions use that store.

## What Changes

Two switches, both environment variables read where the shell is evaluated, and independent of each other. With both unset the generated files are exactly what they are today, so this can merge before the host exists.

`COLDLOGIC_DISABLE_AUTO_MEMORY=1` (Derek's answer, 2026-11-13) turns built-in auto memory off (`autoMemoryEnabled: false`) in the generated settings. Unset, a project keeps today's built-in memory, whether or not the store is configured. With it on and the store configured, the store is the only memory, which is what closes #83: a memory is deleted with `memory_delete`, not by removing a file under `~/.claude`.

`COLDLOGIC_MEMORY_URL` adds everything else:

- A `memory` HTTP MCP server in the generated `.mcp.json`, at `<COLDLOGIC_MEMORY_URL>/mcp` with no credentials, and `memory` in `enabledMcpjsonServers`. Its tools are `mcp__memory__*`.
- A `SessionStart` hook, `coldlogic-memory-recall`. It reads the memories tagged for the project (`scope:project:<owner>/<repo>`, from the git remote), the user (`scope:user:<login>`, the login from `COLDLOGIC_MEMORY_USER`) and the organisation (`scope:org`) over REST, and prints one line per memory under a label that marks them as untrusted notes, with a short text on when to save and which scope tag to use, worded for whether auto memory is off. It stays under 9,000 characters, never fails a session, and prints one line when the store can't be reached.
- Permission rules for the server's tools: the read tools and `memory_store` are allowed; `memory_delete`, `memory_update`, `memory_cleanup`, `memory_consolidate` and the other changing or removing tools ask. The store's host is not added to the sandbox's allowed domains, so a session's commands can't call the REST API around those rules.
- The tools of the claude.ai connector for the same store, which Derek names `Memory` or `memory` (`mcp__claude_ai_Memory__*`, `mcp__claude_ai_memory__*`; tool names keep the display name's case, and any other name isn't covered), are denied in local sessions, so a session sees one set of memory tools: the tailnet one.

Also:

- `COLDLOGIC_MEMORY_URL`, `COLDLOGIC_MEMORY_USER` and `COLDLOGIC_DISABLE_AUTO_MEMORY` are carried in the generated settings' `env` when set, so a shell entered inside a session evaluates the same files as the terminal that started it.
- A one-off command, `coldlogic-memory-migrate`, imports `~/.claude/projects/*/memory/*.md` into the store with scope tags from a path-to-scope table, and leaves the files in place. It is a dry run unless `--apply` is given.
- The gate builds this repository's shell a second time with the store configured and auto memory off, so those branches are evaluated in CI.
- `README.md` documents the variables, the hook, the rules, the migration and what cloud sessions don't get.

Not in this change: the service, its package, the tailnet and tunnel, OAuth and backups (dotfiles); the claude.ai connector (Derek's account); anything for cloud sessions beyond a note in the README (Derek's answer), since they receive none of the generated files (design.md, decision 12).

## Capabilities

### New Capabilities
- `shared-memory`: how a project's local sessions are connected to the shared memory store: when it is configured, the MCP server entry, the switch that turns auto memory off, what is recalled at session start and how it is labelled, the scope tags, behaviour when the store is down, and the import of existing auto memory files.

### Modified Capabilities
- `session-permissions`: adds the rules for the memory server's tools (which are allowed, which ask, the connector's denied) and that the store's host stays out of the sandbox's allowed domains.
- `gate`: the gate also builds the shell with the memory store configured.

## Impact

- New: `packages/memory-recall.sh`, `packages/memory-recall-test.sh`, `packages/memory-recall.nix`, `packages/memory-migrate.py`, `packages/memory-migrate-test.py`, `packages/memory-migrate.nix`.
- `devenv.nix` (developer profile): reads `COLDLOGIC_MEMORY_URL`, `COLDLOGIC_MEMORY_USER` and `COLDLOGIC_DISABLE_AUTO_MEMORY` at evaluation, as it reads `GNUPGHOME`; the two packages; when the store is configured, `claude.code.mcpServers.memory`, the hook, the rules and `enabledMcpjsonServers`; when the switch is on, `autoMemoryEnabled`; and the `env` entries for whichever are set.
- `scripts/check.sh`: one more build step.
- `README.md`.
- Runtime dependencies of the hook: curl, jq, git, coreutils. The hook runs outside the Bash sandbox, as hooks do, and that is the only way it reaches the tailnet.
- Projects on the module change only on machines that set one of the variables. Where `COLDLOGIC_DISABLE_AUTO_MEMORY=1` is set, existing auto memory stops loading as soon as the settings are regenerated, whether or not the store is configured or the migration has run.
- Depends on the host contract in #107: the tailnet base URL serves REST under `/api` and MCP at `/mcp` without auth, the server is named `memory`, and so is the claude.ai connector. This change adds two names to that contract, for dotfiles to set beside the URL: `COLDLOGIC_MEMORY_USER` (the login for `scope:user:<login>`) and `COLDLOGIC_DISABLE_AUTO_MEMORY`. The REST and tool names used here were read from mcp-memory-service's source on 2026-11-13, not from a running instance; the tasks check them against the live host.
