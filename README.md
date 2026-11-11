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
3. Adds the generated files to `.gitignore`, and stops tracking any committed copies (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml`), moving them to `.devenv/adopt-backup/` so their settings can be ported. OpenSpec's Claude Code skills and commands (`.claude/skills/openspec-*/`, `.claude/commands/opsx/`) are untracked too, and left in place: the shell regenerates them.
4. Copies the update workflow into `.github/workflows/` (`--no-workflow` skips it).
5. Adds an `.envrc` that loads the shell through direnv, if there is none (`--no-envrc` skips it). An existing one is left alone; if it still uses the flake, or doesn't load devenv, that goes on the list at the end.
6. Runs `devenv update` (`--no-update` skips it). That moves every pin, `nixpkgs` included.

It never commits, and running it again changes nothing once a project is set up. It finishes with a list of what it couldn't do for you:

- **Settings in `devenv.nix` the module already provides**: `git`, `openspec`, `languages.rust`, `git-hooks`, `claude.code`. Drop the duplicates. Keep what is the project's own, written as the next section describes.
- **A tracked `.claude/settings.json`**: port its project-specific allow rules and plugins to `devenv.nix`.
- **A flake dev shell**: the guard hook denies `nix develop`. Move the dev shell's packages and environment into `devenv.nix`, then remove it, and switch `.envrc` from `use flake` to `use devenv`.

Then enter the shell (`devenv shell`, or `direnv reload`) to generate the settings and hooks, check that the project builds, and open a PR. If the repository isn't in the infrastructure stack's `projects.ts` yet, register it there, so it gets the `coldlogic-ai` environment the update workflow needs.

Claude Code loads an enabled plugin only once it is installed for the project, and it can't install one here: `claude plugin install --scope project` also writes `.claude/settings.json`, and won't write through the symlink into the store. So the shell installs each plugin the settings enable (`coldlogic` and its dependencies, and `cloudflare` under `rust-worker`) that this checkout lacks. It copies the plugin from the marketplace Claude Code has fetched into its plugin cache and records a project-scope install, as `claude plugin install` would. Nothing goes in user settings or `settings.local.json`. It warns instead when Claude Code hasn't fetched the marketplace yet (start Claude Code in the project once), or when the shell runs inside a Claude Code session, whose sandbox protects `~/.claude/plugins` (enter it from a terminal).

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
| `devenv.nix` | `developer`: `git`, `openspec`, `gh-app`; the nixfmt hook; `claude.code` permissions and deny rules; the guard hook; the marketplace, plugin and sandbox settings (what the shell may write and reach, the checkout's sibling `<checkout>.worktrees` directory and devenv's `/tmp/devenv-*` runtime dirs included, and the `.env` files it may not read); per-worktree `core.hooksPath`; the freshness warning; OpenSpec's Claude Code skills and commands, generated with the module's `openspec` where the project ignores them (the sandbox can't write `.claude/skills` or `.claude/commands`, so tracked copies broke `git stash`, `rebase` and `switch`) |
| `packages/claude-guard.py` | The PreToolUse guard hook: denies force pushes, hard resets, deploys, a flake's dev shell, merges or approvals with the user's own `gh` credentials, approvals by the App and its merges through `gh-app api` (it merges through `gh-app pr merge`), a Bash call that changes a project file in the common ways (`sed -i`, `perl -i`, `tee`, a `>` redirect, a script opening a file for writing; it points the session to the Edit and Write tools, which the project's rules allow without a prompt), and secrets files (`.env`, `.dev.vars` and their variants, not `.example`), however a command spells or wraps them. It allows a command only when it is one plain command, optionally behind `devenv shell --`, that an allow rule names; everything else goes to Claude Code's own rules. A linked worktree of the project's own repository, under `.claude/worktrees` or beside the checkout in `<checkout>.worktrees`, is judged like the root, and so is `git -C` naming one of them. A backstop, not a boundary. Its cases in `claude-guard-test.py` run when it builds. |
| `profiles/rust-lib` | Rust with wasm32 in `build`, at the version the module supports (`languages.rust.version`, 1.99.1; a project can set its own); the slimmed `ci` toolchain; rust-analyzer, docs and the check-only `rustfmt` and `clippy` hooks in `developer`, and the sandbox allowances for cargo's caches, crates.io and the Rust docs |
| `profiles/rust-worker` | `rust-lib` plus `worker-build`, `wasm-pack`, `topcoat` (for `topcoat fmt`, built with the profile's Rust), the `cloudflare` plugin, and the sandbox allowances for wrangler's and the Worker build tools' state and the Cloudflare hosts |
| `packages/topcoat-cli.nix` | The Topcoat CLI at the Topcoat version the projects pin, which `topcoat fmt` needs to read their macros. Bump it with that pin |
| `packages/gh-app.nix` | `gh-app <gh args>`: one `gh` call as `coldlogic-ai[bot]`. `gh-app pr merge` merges only the App's own PRs, approved at their head commit, and refuses `--admin`; with `--auto` it checks instead that the base branch's rules require an approval and dismiss it on push, since GitHub then holds the merge until that approval is in. The key path comes from `GH_APP_KEY` (default `~/.config/github/coldlogic-ai.pem`) |
| `scripts/adopt.sh` | Moves a project onto this module, or sets up a new one with it (see "Adopting it") |
| `templates/` | The workflow that proposes `devenv update coldlogic-devenv` as a PR, weekly and whenever main moves |
| `.github/workflows/dispatch-updates.yaml` | On every push to main, builds the `ci` and `developer` shells of each fixture in `tests/fixtures` on Linux and macOS and pushes them to the `coldlogic` cachix cache, then sends each repository with the update workflow the `coldlogic-devenv-updated` event, so it updates now. The update workflow aligns the project's `nixpkgs`, `rust-overlay` and `git-hooks` with the module's lock, so those cached shells are the project's, and turns on auto-merge for the PR |
| `tests/fixtures/` | A stand-in project per profile, built by the cache job with this repository's `devenv.lock` |

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
