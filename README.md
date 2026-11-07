# coldlogic-devenv

The devenv module every Cold Logic project imports: toolchain profiles, the git-hooks policy, Claude Code settings and deny rules, enablement of the [`coldlogic` plugin](https://github.com/coldlogicsolutions/claude-plugins-coldlogic), and `gh-app`.

## Adopting it

`scripts/adopt.sh` moves a project onto this module, or sets up a new one with it. Run it from the project's root, with a clean working tree:

```sh
../coldlogic-devenv/scripts/adopt.sh                  # from a checkout
curl -fsSL https://raw.githubusercontent.com/coldlogicsolutions/coldlogic-devenv/main/scripts/adopt.sh | bash   # or from GitHub
```

It picks a profile from the project (`rust-worker` for a Cargo project with a wrangler config, `rust-lib` for other Cargo projects, none otherwise); `--profile rust-lib|rust-worker|none` overrides that. Then it:

1. Adds the `git-hooks`, `rust-overlay` and `coldlogic-devenv` inputs, the imports and `profile: developer` to `devenv.yaml`, creating it if needed. Existing inputs, `nixpkgs` included, are left alone.
2. Creates an empty `devenv.nix` if there is none.
3. Adds the generated files to `.gitignore`, and stops tracking any committed copies (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml`), moving them to `.devenv/adopt-backup/` so their settings can be ported.
4. Copies the update workflow into `.github/workflows/` (`--no-workflow` skips it).
5. Runs `devenv update` (`--no-update` skips it). That moves every pin, `nixpkgs` included.

It never commits, and running it again changes nothing once a project is set up. It finishes with a list of what it couldn't do for you:

- **Settings in `devenv.nix` the module already provides**: `git`, `openspec`, `languages.rust`, `git-hooks`, `claude.code`. Drop the duplicates. Keep what is the project's own, written as the next section describes.
- **A tracked `.claude/settings.json`**: port its project-specific allow rules and plugins to `devenv.nix`.
- **A flake dev shell**: the guard hook denies `nix develop`. Move the dev shell's packages and environment into `devenv.nix`, then remove it, and switch `.envrc` from `use flake` to `use devenv`.

Then enter the shell (`devenv shell`, or `direnv reload`) to generate the settings and hooks, check that the project builds, and open a PR. If the repository isn't in the infrastructure stack's `projects.ts` yet, register it there, so it gets the `coldlogic-ai` environment the update workflow needs.

Inside a Claude Code sandbox, devenv can't write `/tmp`. Run the script as `XDG_RUNTIME_DIR=$TMPDIR scripts/adopt.sh`.

## Using it

These are the changes the script makes, for doing them by hand. Add the input and the imports to the project's `devenv.yaml`. The module uses `git-hooks` and `rust-overlay`, and devenv doesn't take inputs from an imported module, so the project declares them too:

```yaml
inputs:
  git-hooks:
    url: github:cachix/git-hooks.nix
  nixpkgs:
    url: github:NixOS/nixpkgs/nixpkgs-unstable
  rust-overlay:
    url: github:oxalica/rust-overlay
    inputs:
      nixpkgs:
        follows: nixpkgs
  coldlogic-devenv:
    url: github:coldlogicsolutions/coldlogic-devenv
    flake: false
imports:
  - coldlogic-devenv
  - coldlogic-devenv/profiles/rust-worker
profile: developer
```

The project's `devenv.nix` keeps only what is its own (Pulumi, cachix push, extra packages). It adds to the same `build`, `ci` and `developer` profiles. Permissions go through `claude.code.permissions`, whose lists concatenate. Allow rules name the command run inside the devenv wrapper (`cargo test *`, not `devenv shell -- cargo test *`): the guard hook applies them there; other Claude Code settings go through the same `files` key the module uses:

```nix
profiles.developer.module = { config, ... }: {
  claude.code.permissions.rules.Bash.allow = [ "git merge *" ];
  files."${config.claude.code.settingsPath}".json.enabledPlugins."playwright@claude-plugins-official" = true;
};
```

Sessions default to `opus`, which tracks the latest Opus, and subagents with no model of their own to `sonnet`. The plugin's `models.md` convention picks a model per subagent. To change a default, set `claude.code.model` or `claude.code.env.CLAUDE_CODE_SUBAGENT_MODEL` in the project.

Copy `templates/update-coldlogic-devenv.yaml` to `.github/workflows/` and register the repository in the infrastructure stack, which shares the App credentials it needs.

## What's here

| Path | What it adds |
| --- | --- |
| `devenv.nix` | `developer`: `git`, `openspec`, `gh-app`; the nixfmt hook; `claude.code` permissions and deny rules; the guard hook; the marketplace, plugin and sandbox settings (what the shell may write and reach, and the `.env` files it may not read); per-worktree `core.hooksPath`; the freshness warning |
| `packages/claude-guard.py` | The PreToolUse guard hook: denies force pushes, hard resets, deploys, a flake's dev shell, merges or approvals with the user's own `gh` credentials, approvals by the App, and secrets files (`.env`, `.dev.vars` and their variants, not `.example`), however a command spells or wraps them. It allows a command only when it is one plain command, optionally behind `devenv shell --`, that an allow rule names; everything else goes to Claude Code's own rules. A backstop, not a boundary. Its cases in `claude-guard-test.py` run when it builds. |
| `profiles/rust-lib` | Rust with wasm32 in `build`; the slimmed `ci` toolchain; rust-analyzer, docs and the check-only `rustfmt` and `clippy` hooks in `developer` |
| `profiles/rust-worker` | `rust-lib` plus `worker-build`, `wasm-pack`, and the `cloudflare` plugin |
| `packages/gh-app.nix` | `gh-app <gh args>`: one `gh` call as `coldlogic-ai[bot]`. `gh-app pr merge` merges only the App's own PRs, approved at their head commit, and refuses `--admin`. The key path comes from `GH_APP_KEY` (default `~/.config/github/coldlogic-ai.pem`) |
| `scripts/adopt.sh` | Moves a project onto this module, or sets up a new one with it (see "Adopting it") |
| `templates/` | The workflow that proposes `devenv update coldlogic-devenv` as a PR, weekly and whenever main moves |
| `.github/workflows/dispatch-updates.yaml` | On every push to main, sends each repository with that workflow the `coldlogic-devenv-updated` event, so it updates now |

`rust-gui` (proxcarta) and `node-web` (paintinator, voxcarta) are added when those projects move to devenv.

## Working on the module

This repository's own `devenv.yaml` makes `devenv.nix` here its shell too, so sessions working on the module run under the settings, guard hook and plugin it gives every project.

## Staying current

Each project pins the module in `devenv.lock`, so CI images keyed on that file stay stable. The update workflow proposes the update as a PR, weekly and whenever the module's main moves, and the shell warns when the pin is behind:

```
coldlogic-devenv is behind (locked 1a2b3c4, latest 5d6e7f8); run: devenv update coldlogic-devenv
```

The plugin's SessionStart hook runs the same comparison, so Claude mentions it too.

## Local development

Point one project at a checkout while you work on the module. devenv 2.2 and later picks up changes to a local `path:` input automatically. Never commit this change:

```yaml
  coldlogic-devenv:
    url: path:../coldlogic-devenv/
    flake: false
```

For the plugin, run Claude Code with `claude --plugin-dir ../claude-plugins-coldlogic/plugins/coldlogic`.
