# Proposal

## Why

A terminal `devenv shell` recreates `.claude/settings.json` in the main checkout, and within half a minute the link is gone again (#94). With other Claude Code sessions closed it survives, so a running session removes it. Without the link a session has no project permissions, hooks or guard, and the freshness check blocks all work.

Two mechanisms fit, and neither is proven. One is devenv's own link step: `devenv:files` runs `ln -sf` whenever the link differs from the target its evaluation expects, and the sandbox lets the unlink through while denying the create (#68). Our status check decides first and devenv's script acts second, so anything that changes between the two, or any case the check misjudges, reaches `ln -sf`. The other is Claude Code itself removing a settings file that changed under it. This change removes the first for good, and stops a session from changing the settings link at all, which also tells us whether the second is real.

The same status check has a second cost. When it skips `devenv:files`, it skips every generated file, including ones a session can write. A fresh worktree then never gets `.pre-commit-config.yaml`, and `devenv:git-hooks:install` fails on every shell (#78).

## What Changes

- In a Claude Code session, `devenv:files` and `devenv:files:cleanup` never run, whatever state the links are in. Today they run when a check says the links are current. Outside a session they run as before.
- A session never writes `.claude/settings.json`: it doesn't create, replace, rename or remove it. Only a terminal shell refreshes it. Today a session tries an atomic relink of it.
- A new session-only task links every other generated file devenv would link (symlink mode), through the atomic relink in `packages/session-relink.sh`: a temporary link renamed over the old one. A file the sandbox refuses keeps what it has, and the rest are still linked. So `.pre-commit-config.yaml` and `.mcp.json` are linked in a session whatever state the settings link is in.
- The relink script loses its `--state` check. It existed to decide when cleanup was safe to run in a session, and cleanup no longer runs there.
- The script's `--print` output says whether each file is missing or out of date.
- The `coldlogic:generated-files-stale` notice still covers the settings link. It lists missing files apart from out-of-date ones, and adds: after the terminal refresh, restart every Claude Code session open in the checkout, this one included, since a running session can undo it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `generated-files`: a session never runs devenv's two file tasks and never writes the settings link. It links the other generated files itself, one at a time and atomically. The two requirements about when session cleanup is safe are removed, since cleanup never runs in a session. The notice requirement gains the missing/out-of-date split and the restart advice.

## Impact

- `devenv.nix`: the `protectedFiles`, `sessionRelink` and `sessionStatus` bindings, the statuses of `devenv:files` and `devenv:files:cleanup`, a new `coldlogic:session-files` task, and `coldlogic:generated-files-stale`.
- `packages/session-relink.sh`, `packages/session-relink-test.sh`, `packages/session-relink.nix`.
- Every project on the module gets this on its next lock bump. A checkout whose link is already gone still needs one terminal `devenv shell`.
- A session whose sandbox is off no longer fixes its own settings link. It needs a terminal shell like any other.
- In a session, files in devenv's `copy` or `seed` mode are no longer refreshed; a terminal shell does that. Nothing in this module or its fixtures uses those modes.
- Out of scope: #93 group 2 (#67's `core.hooksPath` write, warn-once notices, and whether `enterShell` runs in a fresh worktree), Claude Code's own handling of settings paths, and devenv's `ln -sf` outside a session.
