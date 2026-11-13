# Proposal

## Why

Issue #93 groups six reports (#42, #43, #61, #62, #85, #86) of commands the module allows that still prompt or get denied. Most of what they ask for already works on main (the archived `guard-compound-commands` and `agent-worktrees` changes), but nothing pins those exact commands down, and one gap in the guard remains: it asks for `devenv --version`.

## What Changes

- **A devenv version query runs without a prompt.** The guard treats exactly `devenv --version`, `devenv -V` and `devenv version` as commands that only read, bare or behind `devenv shell --`, instead of asking about an unknown `devenv` option. No allow rule is added. Any other `devenv` option or subcommand is judged as today (#85).
- **A regression table for the module's own allow list.** `claude-guard-test.py` gains a table of every command from those six issues, each run bare and behind `devenv shell --quiet --`, against a copy of the allow list in `devenv.nix`, with the forms that must stay without an allow: a double-quoted body with backticks, a `cd X &&` prefix, other devenv options, and `git -C /elsewhere` (#42, #43, #61, #62, #85, #86).
- The README's guard row names the version query.

This closes #42, #43, #61 and #85. #62 and #86 stay open: they are denials by auto mode's classifier of commands the guard already allows (see design.md).

Not in this change: new allow rules (`git show`, `git blame`, `git rev-parse`), any edit to `devenv.nix`, and a `--body "$(cat <<'EOF' ... EOF)"` form for issue and PR bodies. The supported body forms are `--body-file` and a single-quoted `--body`; both already work.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: adds the devenv version query as a command that only reads, and the requirement that the module's allow list is tested as written, bare and wrapped.

## Impact

- `packages/claude-guard.py`: a small helper, and one or two lines each in `devenv_command()`, the strict reader's wrapper check in `plain_commands()`, and `read_only()`.
- `packages/claude-guard-test.py`: one block appended.
- `README.md`: the `packages/claude-guard.py` row.
- Every project that imports the module gets the guard change on its next lock update. No rule changes, and no decision moves from allow to ask or deny.
