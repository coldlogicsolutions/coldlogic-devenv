# Proposal

## Why

Two protections the module already promises have a hole each, and one incident showed how the guard gets probed unsafely:

- The guard should ask before a file tool changes the project's Claude Code configuration. It doesn't for the one file that matters most, `.claude/settings.json`, because devenv generates it as a symlink into the Nix store and the guard judges only where the link leads, which is outside the project (#56). The spec documents the hole as it stands.
- Read, Edit and the sandbox's read deny all cover `secrets/**`, but the sandbox's write deny doesn't, so a Bash command can still write there (#59).
- A reviewer probed the guard by running test commands through a heredoc in Bash. The heredoc ended early and the commands ran for real (#79). Nothing in this repository says how to probe the guard safely.

## What Changes

- The guard asks before Edit, Write, MultiEdit or NotebookEdit changes a path in the project's `.claude` directory when the path's last component is a symlink, wherever the link leads. It judges such a path twice: fully resolved, as now, and with only its parent directory resolved. Either view naming `.claude` asks. Read is unchanged. Closes #56.
- The sandbox denies writes to `secrets/**` in the same four places it already denies reads: at the checkout root, below it, at the top of each sibling worktree and below it. Closes #59.
- README gets a short "Testing the guard" paragraph: probe it by calling `decide()` from Python or by adding cases to `claude-guard-test.py`, never by running the probe commands through Bash. Partly addresses #79; the review guidance in the plugin repository is handled there.

Out of scope:

- #83, a separate change after a user decision.
- Any enforcement in the guard by agent type (#79's second option). The guard stops easy mistakes; it isn't a boundary.
- Symlinked directories inside `.claude` (a link above the last component). See design.md.
- Any change to `resolve()`, `checkout_of()`, the lexer or `decide()`'s Bash branch.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: the requirement "File tools ask before changing .git or Claude Code configuration" now covers a `.claude` path whose last component is a symlink. Its "Editing project settings" scenario stops documenting the hole.
- `session-permissions`: the requirement "The sandbox denies secrets and gpg configuration" now denies writes to `secrets/**` as well as `.env`.

## Impact

- `packages/claude-guard.py`: `claude_config()` only.
- `packages/claude-guard-test.py`: one new block after the `.claude` block, and new rows in the file-tool list of the "project's own worktrees" block.
- `devenv.nix`: one flag on the `secrets/**` entry and two comments.
- `README.md`: one paragraph under "Working on the module".
- `openspec/specs/claude-guard/spec.md` and `openspec/specs/session-permissions/spec.md`, when the change is archived.
- Projects on the module: after their next update, a sandboxed command can no longer write under any directory named `secrets` in the checkout or its sibling worktrees. That includes git writing tracked files there during a switch, stash or rebase. Edits to the generated settings link prompt instead of going straight to Claude Code's rules.
