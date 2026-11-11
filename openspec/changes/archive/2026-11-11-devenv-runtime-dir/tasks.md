# Tasks

## 1. Settings

- [x] 1.1 In `devenv.nix`, add `XDG_RUNTIME_DIR = "${builtins.getEnv "HOME"}/.cache/devenv/run";` to `claude.code.env`, with a comment saying why (devenv's default `/tmp/devenv-<hash>` isn't writable in the sandbox, and the sandbox drops glob allows; #64). Verify `nixfmt --check devenv.nix` passes.
- [x] 1.2 Remove the four `/tmp/devenv-*` and `/private/tmp/devenv-*` entries and their comment from `sandbox.filesystem.allowWrite`. Verify `grep -n 'devenv-\*' devenv.nix` finds nothing.
- [x] 1.3 In `README.md`'s `devenv.nix` row, replace the `/tmp/devenv-*` clause and its "pending verification in #64" note with: sessions keep devenv's runtime dirs in `~/.cache/devenv/run` (`XDG_RUNTIME_DIR`). Verify by reading the row back.
- [x] 1.4 Run `devenv shell --quiet -- openspec validate devenv-runtime-dir --strict` and verify it reports the change valid.

## 2. Verification (manual, after merge)

- [ ] 2.1 Derek enters `devenv shell` once from a terminal in the main checkout, so the settings relink. Then `jq '.env.XDG_RUNTIME_DIR, .sandbox.filesystem.allowWrite' .claude/settings.json` must show `<home>/.cache/devenv/run` and no `devenv-*` entries. Report on #64.
- [ ] 2.2 In a new Claude Code session, a subagent with `isolation: worktree` runs `devenv shell --quiet -- true`. Verify it doesn't fail on `Failed to create ... devenv-<hash>`, and that `ls -dt ~/.cache/devenv/run/devenv-*` shows a new dir. Report on #64.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges.
