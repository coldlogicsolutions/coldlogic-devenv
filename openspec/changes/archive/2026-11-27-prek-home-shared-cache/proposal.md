# Proposal

## Why

In a session working in a `.claude/worktrees/<name>` worktree, `git commit` fails in the pre-commit hook with `Failed to open log file <main checkout>/.devenv/profiles/developer/state/prek/prek.log: Operation not permitted` (#135). devenv's git-hooks integration puts prek's state in the checkout's devenv state (`PREK_HOME = ${config.devenv.state}/prek`), and the installed hook sets no environment of its own, so a commit can carry the main checkout's `PREK_HOME`, which the sandbox stops allowing once the session moves into the worktree.

## What Changes

- The developer profile sets `PREK_HOME` to the user's prek cache, `<home>/.cache/prek`, overriding devenv's per-checkout default. That path is the same from every checkout and worktree, and the sandbox already allows writing it (`~/.cache/prek` in `allowWrite`), so no sandbox or permission rule changes.
- devenv's own `enterShell` line (`mkdir -p "$PREK_HOME"`) keeps working and now creates the cache directory.
- A Nix assertion beside the definition fails evaluation when the developer shell's `PREK_HOME` isn't `<home>/.cache/prek`; the gate's existing shell builds evaluate it.
- README's `devenv.nix` row says where prek keeps its state and why.

Rollout: a running session keeps the `PREK_HOME` it inherited from the shell that started it until it is restarted from a shell entered after this change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `git-hooks`: adds a requirement that prek's state lives in the shared user cache, so a commit from a session's worktree runs the hook.

## Impact

- `devenv.nix` (developer profile module): one `env.PREK_HOME` definition with `lib.mkForce`, and one entry in devenv's `assertions` option checking it. No change to `scripts/check.sh`.
- `README.md`: the `devenv.nix` row.
- Every project that imports the module: prek's log, lock and hook environments move from `.devenv/profiles/developer/state/prek` (or `.devenv/state/prek`) to `~/.cache/prek`, which is shared across checkouts. prek's first commit after the change rebuilds its hook environments there; the old directory is left in place and is unused.
