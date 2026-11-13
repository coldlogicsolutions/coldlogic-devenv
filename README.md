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

The project's `devenv.lock` must pin a devenv from 2026-10-19 or later, since worktrees share one hooks directory and only from then does the installed hook read the committing worktree's own configuration.

The project's `devenv.nix` keeps only what is its own (Pulumi, cachix push, extra packages). It adds to the same `build`, `ci` and `developer` profiles. Permissions go through `claude.code.permissions`, whose lists concatenate. Allow rules name the command run inside the devenv wrapper (`cargo test *`, not `devenv shell -- cargo test *`): the guard hook applies them there; other Claude Code settings go through the same `files` key the module uses:

```nix
profiles.developer.module = { config, ... }: {
  claude.code.permissions.rules.Bash.allow = [ "git merge *" ];
  files."${config.claude.code.settingsPath}".json.enabledPlugins."playwright@claude-plugins-official" = true;
};
```

Sessions default to `opus`, which tracks the latest Opus, and subagents with no model of their own to `sonnet`. The plugin's `models.md` convention picks a model per subagent. To change a default, set `claude.code.model` or `claude.code.env.CLAUDE_CODE_SUBAGENT_MODEL` in the project.

Copy `templates/update-coldlogic-devenv.yaml` to `.github/workflows/` and register the repository in the infrastructure stack, which shares the App credentials it needs.

## Starting Claude Code

Start `claude` from the devenv shell (`devenv shell` or direnv), in the checkout. The shell's `claude` is a wrapper that refreshes the generated files first, so after a module update that changes only the generated files there is no need to enter a shell from a terminal and restart every session: restart `claude`.

- It refreshes the generated files only (`devenv:files`, such as `.claude/settings.json` and `.mcp.json`). Every other task a shell runs on entry, among them the plugin install, the OpenSpec skills and commands and the git hooks, still needs `devenv shell` from a terminal. When in doubt after an update, enter one: a plugin that is enabled but not installed is silently missing from the session.

- Every `claude` command outside a session that can start one waits for that refresh. Those that start none, by first argument (`--version`, `-v`, `--help`, `-h`, `update`, `upgrade`, `doctor`, `mcp`, `config`, `auth`, `setup-token`, `install`, `migrate-installer`, `plugin`, `plugins`), start at once; when in doubt, a command refreshes. It prints nothing unless the refresh fails, devenv's own output included; when it fails, devenv's output comes first, on stderr.
- It only works where the shell's `PATH` is used. The IDE extension's own launch and the desktop app don't go through it: for those, enter the shell from a terminal once, as before.
- Start it in the checkout whose settings it should read. In a subdirectory the checkout's files are refreshed, but Claude Code looks for `.claude/settings.json` where it starts.
- Only a git checkout with a `devenv.nix` or `devenv.yaml` at its top is refreshed. Anywhere else the wrapper starts `claude` at once, with no refresh and no check, even when the shell was entered in a project.
- The refresh uses the profile `devenv.yaml` selects, whatever `--profile` the shell was entered with.
- `COLDLOGIC_DEVENV_SESSION` marks a session. If a terminal has it (`printenv COLDLOGIC_DEVENV_SESSION`), it was opened from inside a session, and neither `claude` nor `devenv shell` refreshes there: open a fresh terminal.
- A `claude` run inside a session that the wrapper didn't start is recognised through `CLAUDE_CODE_CHILD_SESSION`, which needs Claude Code 2.1.172 or later. Before that version, run `claude` inside a session only with `COLDLOGIC_DEVENV_SESSION=1`.
- After a module update changes the settings, starting `claude` refreshes the link, but any session already running in that checkout deletes it again at its next tool call (#94). So close or restart every other session in the checkout first.
- A session that started without the settings and is still open can remove the link again (#100): close it.
- If the refresh fails, the wrapper says so on stderr. It still starts `claude` when the settings file (`claude.code.settingsPath`, `.claude/settings.json` by default) is there, as those settings still protect the session. When it isn't, it refuses and exits 1, since the session would have none of the module's guard hook, sandbox settings or permissions. To start it anyway: `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude`. A refresh interrupted with Ctrl-C or SIGTERM starts nothing: the wrapper passes the signal on to devenv, then dies of it (a shell shows 130, or 143 for SIGTERM).
- To run the real binary without the wrapper, take its path from `type -a claude`.

## What's here

| Path | What it adds |
| --- | --- |
| `devenv.nix` | `developer`: `git`, `openspec`, `gh-app`, `coldlogic-prune-worktrees`; the nixfmt hook; `claude.code` permissions and deny rules; the guard hook; the marketplace, plugin and sandbox settings (what the shell may write and reach, the checkout's sibling `<checkout>.worktrees` directory included, and the `.env` files it may not read, in the checkout and its sibling worktrees); sessions keep devenv's runtime dirs in `~/.cache/devenv/run` (`XDG_RUNTIME_DIR`), since the sandbox can't write `/tmp`; worktrees share the hooks git resolves, a session skips a hook install it can't write, and a missing hook is reported; the freshness warning; the `SessionStart` and `Stop` hooks and the terminal-shell task that start `coldlogic-prune-worktrees` in the background; OpenSpec's Claude Code skills and commands, generated with the module's `openspec` where the project ignores them (the sandbox can't write `.claude/skills` or `.claude/commands`, so tracked copies broke `git stash`, `rebase` and `switch`) |
| `packages/claude-guard.py` | The PreToolUse guard hook: denies force pushes, hard resets, deploys, a flake's dev shell, merges or approvals with the user's own `gh` credentials, approvals by the App and its merges through `gh-app api` (it merges through `gh-app pr merge`), a Bash call that changes a project file in the common ways (`sed -i`, `perl -i`, `tee`, a `>` redirect, a script opening a file for writing; it points the session to the Edit and Write tools, which the project's rules allow without a prompt), and secrets files (`.env`, `.dev.vars` and their variants, not `.example`), however a command spells or wraps them. It allows a call only when every command of its sequences (`&&`, `||`, `;`, newlines) and pipelines, each optionally behind `devenv shell --`, is one an allow rule names or one that only reads (`grep`, `head`, `sort`, `jq` and the like); quoted heredoc bodies are data, and redirects to `/dev/null`, `/dev/stderr` or a scratch file under `$TMPDIR` keep a call allowed. A heredoc or here-string body that anything but a known data consumer reads (a read-only filter, `git commit -F -` or `-F-`, `gh-app ... --body-file -` or `--body-file=-`, a `tee` to scratch files only) is checked for denies as a script. Every rule is matched against each command of a call both as written, wrapper included, and unwrapped. Loops, subshells, substitutions and other constructs it doesn't follow get no allow, a call that defines a shell function asks, piping `scripts/check.sh` into another command (directly, through a shell, or in a group or subshell that is piped) is denied, in any call it can read, unless a plain top-level `set -o pipefail` comes first, and so is following it with anything but `&& ...` at its own level (the operator after its subshell's `)` or group's `}` counts; what a `&&` leads to may hold any), backgrounding it with `&`, or running it inside `$( )`, backticks, `<( )` or `>( )`. Options that run a program, wait for an editor or drop refs (`git fetch --upload-pack`, `git commit -e`, `git tag -e`, a `git commit` or annotated or signed `git tag` without a message, `git fetch --prune` or a `+`/`:` refspec, any prefix git accepts of those long options, `tail -f`) get no allow, nor a word starting `-o` outside `grep`, `egrep`, `fgrep`, `rg` and `set`, nor a cluster holding `o` (`-qo`) for `unzip`, `7z`, `ssh`, `scp`, `sftp`, `curl`, `wget`, `cc`, `gcc`, `clang`, `sort` and `mount`. A `~` is plain only in a git revision (`HEAD~1`). Everything else goes to Claude Code's own rules. A linked worktree of the project's own repository, under `.claude/worktrees` or beside the checkout in `<checkout>.worktrees` (and nowhere else), is judged like the root, and so is a single `git -C` naming the checkout the command already runs in. The main checkout stays on its default branch (`origin/HEAD`, else an existing `main` or `master`, else `main`): where a command runs there, after any `git -C` and a literal `cd` or `pushd`, a `git switch` or `git checkout` that creates a branch, detaches HEAD or checks out anything else is denied, in any part of a call and any option prefix or cluster, with a pointer to `EnterWorktree` or `isolation: "worktree"`. `git switch main`, `git checkout HEAD` or `@`, file restores (`git checkout -- <paths>`, `<rev> -- <paths>`, `-p`, an existing path that names no branch, tag or remote branch, since git prefers the ref) and everything else are left alone, and so are linked worktrees anywhere and nested repositories: there `git switch --no-track -c <type>/<name> origin/main` and the other unforced switches run with no prompt under the `git switch *` rule, and the forced forms ask. In the project's repository, a `git switch` or `git checkout` that would set up tracking (`--track` or `-t`, or a new branch from a remote-tracking start point without `--no-track`) is denied with a pointer to `--no-track`, since the sandbox protects `.git/config`. The main checkout is found from the project root, through a linked worktree's `.git` file when the session starts in one. The project's own worktrees are found from it the same way, so a session that starts in one treats the others, and those under its own `.claude/worktrees`, as a session in the main checkout does, their `.claude` directories and shell edits included; the main checkout itself stays outside that session's project. A cd in a subshell, pipeline stage or background doesn't carry past it. Where it can't tell (a cd it can't read, `cd -`, `popd`, or `env -C` or `sudo -D`, also through the shell, `env -S`, `find -exec` or runner they start), such a switch asks, unless a deny elsewhere in the call wins. `git worktree add -B` and a forced `git worktree remove`, in any prefix git accepts, ask. A backstop, not a boundary. Its cases in `claude-guard-test.py` run when it builds. |
| `packages/prune-worktrees.nix` | `coldlogic-prune-worktrees`: removes the project's merged worktrees under `<checkout>.worktrees/` and `.claude/worktrees/`, their local branches and `branch.<name>` config when a merged PR covers the branch (a worktree on `main` or a lagging `staging` goes, the branch stays), and local branches no worktree has that are exactly the head of a PR merged into the default branch, then runs `git worktree prune` when every missing worktree is in those two places and their directories' parents exist on the checkout's device (an unmounted volume isn't pruned), and none was moved by hand with staged changes or abandoned commits. It never deletes a long-lived branch: the default branch, or one named, in any case, `main`, `master`, `develop`, `dev`, `staging`, `production`, `prod`, `release/*` or `hotfix/*`. A worktree counts as merged when it's in the local `origin/main` (it never fetches) or in the head commit of a PR from its branch merged into the default branch, from one `gh-app` call per run, which covers squash merges. It never removes the main checkout, a locked or dirty worktree (untracked files, skip-worktree or assume-unchanged entries, or a rebase in progress included, and ignored files other than regenerable or generated ones such as a top-level `node_modules`, `.claude/settings.json` or `.devenv` caches, so `.env`, or a devenv service's data under `.devenv/state`, keeps it), a branch only because it is an ancestor of main, unmerged commits (abandoned ones in a worktree's HEAD reflog included, unless a merged PR's head holds them), the session's own worktree, one a process works in or whose HEAD moved or that got dirty during the run, or anything with git or devenv activity in the last 6 hours, and it never forces a removal or touches a remote branch. The session hooks and the terminal shell run it detached (a session's own Bash can't, as the sandbox protects other worktrees' `.git`), at most once every 10 minutes; it prints nothing and logs to `.git/coldlogic-prune.log` each removal, before making it, with its commit and the command that restores it (shell-quoted, safe to paste), and each reason for keeping something when it changes. When that log can't be used (a link, a hard link, another user's file), it prints one line on stderr naming it and removes nothing. `coldlogic-prune-worktrees --dry-run` lists what it would remove, each worktree's branch included. Its cases in `prune-worktrees-test.sh` run when it builds |
| `packages/session-shell.nix` | `coldlogic-session-shell`: what a shell does differently inside a Claude Code session: whether the hook install is skipped, the missing-hook notice, whether this checkout is the one the session reads its Claude Code files from, and each notice once per session. Its cases in `session-shell-test.sh` run when it builds |
| `packages/claude-wrapper.nix` | `claude`, ahead of the real Claude Code on the developer shell's `PATH`. Outside a session it first refreshes the checkout's generated files (`devenv --quiet tasks run devenv:files`, at the top of the checkout the current directory is in), so every session it starts has current settings; then it starts the real `claude` with the same arguments, directory and streams, and with `COLDLOGIC_DEVENV_SESSION=1`, which marks everything that session runs. The shell counts as inside a session when that marker is set, or Claude Code's `CLAUDECODE` is, for sessions started another way. Inside a session the wrapper only starts `claude`. If the refresh fails it says so, and starts `claude` only when the settings file (`claude.code.settingsPath`) is there, unless `COLDLOGIC_START_WITHOUT_SETTINGS=1` is set. Its cases in `claude-wrapper-test.sh` run when it builds |
| `profiles/rust-lib` | Rust with wasm32 in `build`, at the version the module supports (`languages.rust.version`, 1.99.1; a project can set its own); the slimmed `ci` toolchain; rust-analyzer, docs and the check-only `rustfmt` and `clippy` hooks in `developer`, and the sandbox allowances for cargo's caches, crates.io and the Rust docs |
| `profiles/rust-worker` | `rust-lib` plus `worker-build`, `wasm-pack`, `topcoat` (for `topcoat fmt`, built with the profile's Rust), the `cloudflare` plugin, and the sandbox allowances for wrangler's and the Worker build tools' state and the Cloudflare hosts |
| `packages/topcoat-cli.nix` | The Topcoat CLI at the Topcoat version the projects pin, which `topcoat fmt` needs to read their macros. Bump it with that pin |
| `packages/gh-app.nix` | `gh-app <gh args>`: one `gh` call as `coldlogic-ai[bot]`. `gh-app pr merge` merges only the App's own PRs, approved at their head commit, and refuses `--admin`; with `--auto` it checks instead that the base branch's rules require an approval and dismiss it on push, since GitHub then holds the merge until that approval is in. The key path comes from `GH_APP_KEY` (default `~/.config/github/coldlogic-ai.pem`) |
| `scripts/adopt.sh` | Moves a project onto this module, or sets up a new one with it (see "Adopting it") |
| `templates/` | The workflow that proposes `devenv update coldlogic-devenv` as a PR, weekly and whenever main moves |
| `.github/workflows/dispatch-updates.yaml` | On every push to main, builds the `ci` and `developer` shells of each fixture in `tests/fixtures` on Linux and macOS and pushes them to the `coldlogic` cachix cache, then sends each repository with the update workflow the `coldlogic-devenv-updated` event, so it updates now. The update workflow aligns the project's `nixpkgs`, `rust-overlay` and `git-hooks` with the module's lock, so those cached shells are the project's, and turns on auto-merge for the PR |
| `scripts/check.sh` | The gate every change to this repository passes before a commit: the guard's test cases, `nixfmt --check`, `shellcheck`, `openspec validate --all --strict`, and builds of this repository's shell and of each fixture's `ci` and `developer` shells. It runs every check, prints a summary and exits non-zero if any failed. Its tools come from the nixpkgs revision `devenv.lock` pins (`scripts/check-tools.nix`), so a session, a terminal and CI agree |
| `.github/workflows/check.yaml` | Runs `scripts/check.sh` as the `check` job, on Linux, for every pull request and every push to main. It only reads the `coldlogic` cache and has no secrets |
| `tests/fixtures/` | A stand-in project per profile, built by the cache job with this repository's `devenv.lock` |

`rust-gui` (proxcarta) and `node-web` (paintinator, voxcarta) are added when those projects move to devenv.

## Working on the module

This repository's own `devenv.yaml` makes `devenv.nix` here its shell too, so sessions working on the module run under the settings, guard hook and plugin it gives every project.

Run the gate before each commit:

```
devenv shell --quiet -- scripts/check.sh
```

It exits non-zero if any check failed, and the pull request runs it again as the `check` job.

### Testing the guard

To find out what the guard decides for a command, don't run the command. The guard judges a call; it doesn't contain it. Whatever it lets through runs for real, and so does anything a probe script leaves behind when a heredoc ends early (#79: a reviewer's probe posted PR comments and made a commit).

Use one of these instead:

- Add a case to `packages/claude-guard-test.py` and run the cases:

  ```
  devenv shell --quiet -- python3 -I packages/claude-guard-test.py
  ```

- Load `packages/claude-guard.py` in Python and copy `POLICY` from that test file, as its first lines do. Set where the call runs with `guard.WORKING.update(cwd=<dir>, root=<project root>)`: without a cwd, path checks are skipped and the probe says `None` where the real guard would ask or deny. Then call `guard.decide("Bash", {"command": "<the command>"}, POLICY)` on the command as a string. It returns the decision and its reason, or `None` when the call is left to Claude Code's rules.

This holds for reviewers and subagents too: the command under test stays a string.

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
