# Proposal

## Why

coldlogic-devenv had no `openspec/` directory, so every change to it (#47, #48, #50) could truthfully say there were no specs to change and skip OpenSpec. Issue #52 makes OpenSpec mandatory in every repository, this one included. Future changes need a baseline to write deltas against, so this change records what the module does today. It doesn't change any behaviour.

## What Changes

- Initialise OpenSpec in this repository (`openspec/config.yaml`, schema `spec-driven`).
- Ignore OpenSpec's generated Claude Code skills and commands, as `scripts/adopt.sh` does for every project, so the module's own `coldlogic:openspec-files` task generates them here too.
- Add baseline specs for the module's existing behaviour, taken from the code and the README. Each requirement names the test that covers it, or says that none does.

## Capabilities

### New Capabilities

- `claude-guard`: the PreToolUse guard hook, which denies forbidden commands, secrets access and Bash file edits, and allows plain commands that an allow rule names.
- `gh-app`: running `gh` as the coldlogic-ai App, minting its installation token, and the checks `gh-app pr merge` applies.
- `session-permissions`: the Claude Code permission rules, model defaults and sandbox settings the module generates for every session.
- `generated-files`: how the shell treats the generated settings and `.mcp.json` inside a Claude Code session, which can't rewrite them (#37).
- `claude-plugins`: the marketplaces and plugins the settings enable, and the shell task that installs them for the checkout.
- `git-hooks`: the pre-commit hooks the module turns on, and a per-worktree hooks path.
- `toolchain-profiles`: the `rust-lib` and `rust-worker` profiles and their `build`, `ci` and `developer` layers.
- `module-updates`: keeping projects on the module's latest revision through the freshness warning, the cache and dispatch workflow, and the per-project update workflow.
- `openspec-files`: generating OpenSpec's Claude Code skills and commands from the module's `openspec`.
- `project-adoption`: `scripts/adopt.sh`, which moves a project onto the module.

### Modified Capabilities

None. No specs existed before this change.

## Impact

- New files only: `openspec/` and two `.gitignore` lines. No module code changes, so projects that import the module see no difference.
- Later changes to the module open an OpenSpec change against these specs.
