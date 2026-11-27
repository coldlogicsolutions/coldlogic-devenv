# Tasks

Run every command through `devenv shell --quiet -- <cmd>`, each in its own Bash call, unpiped. Change files only with the Edit and Write tools. Do not change `scripts/check.sh`.

## 1. Point PREK_HOME at the user cache, with its assertion

- [x] 1.1 In `devenv.nix`, in the `let` block of `profiles.developer.module`, directly after the binding `hooksExpected = config.git-hooks.enable && expectedHooks != [ ];`, add:

  ```nix
        # prek's state directory in every developer shell: the user's prek
        # cache (see env.PREK_HOME below).
        prekHome = "${builtins.getEnv "HOME"}/.cache/prek";
  ```

  Verify: `git diff devenv.nix` shows only this addition.
- [x] 1.2 In the same module's returned attribute set, directly after the line `git-hooks.hooks.nixfmt.enable = true;`, add a blank line and then this block (keep the comments):

  ```nix
        # devenv's git-hooks integration keeps prek's state (its log, lock and
        # hook environments) in the checkout's own devenv state, at plain
        # priority, and the installed hook sets no environment. A session that
        # moves into a worktree with EnterWorktree then commits with the main
        # checkout's PREK_HOME, which its sandbox no longer lets it write
        # (#135). The user's prek cache is one path from every checkout,
        # prek's own default, and in the sandbox's allowWrite below; devenv's
        # enterShell still creates it. mkForce: devenv's definition has plain
        # priority, so a second plain one would conflict.
        env.PREK_HOME = lib.mkIf config.git-hooks.enable (lib.mkForce prekHome);
        # Fails the shell's evaluation, so the gate's shell builds, when the
        # override above is lost or outranked.
        assertions = lib.optional config.git-hooks.enable {
          assertion = (config.env.PREK_HOME or null) == prekHome;
          message = "coldlogic: PREK_HOME is ${
            config.env.PREK_HOME or "unset"
          }, not the user's prek cache ${prekHome}, so a session's worktree commits can't run the pre-commit hook (#135)";
        };
  ```

  Do not change the sandbox `allowWrite` list: `"~/.cache/prek"` is already there. Verify: `git diff devenv.nix` shows only the 1.1 binding and this block.
- [x] 1.3 Run `devenv shell --quiet -- printenv PREK_HOME`. Verify: the shell evaluates (no `coldlogic: PREK_HOME is` assertion error) and the last line printed is `$HOME/.cache/prek` expanded (for example `/Users/<you>/.cache/prek`), not a path under `.devenv`. Then run `devenv shell --quiet -- test -d "$HOME/.cache/prek"` and verify it exits 0 (devenv's enterShell `mkdir -p "$PREK_HOME"` created it).
- [x] 1.4 Prove the assertion can fail: temporarily change the 1.2 definition line to `env.PREK_HOME = lib.mkIf config.git-hooks.enable (lib.mkForce "${prekHome}-x");` with Edit, run `devenv shell --quiet -- true` (the assertion fails the shell's own evaluation, which is also what the gate's `devenv build shell` steps evaluate), and verify it fails with the message starting `coldlogic: PREK_HOME is` and ending `-x, not the user's prek cache ...`. Then restore `(lib.mkForce prekHome)` with Edit and verify `git diff devenv.nix` shows only the 1.1 binding and the 1.2 block.
- [x] 1.5 In `README.md`, in the `devenv.nix` row of the "What's here" table (the row starting `` | `devenv.nix` | `developer`: ``), after the clause `` sessions keep devenv's runtime dirs in `~/.cache/devenv/run` (`XDG_RUNTIME_DIR`), since the sandbox can't write `/tmp`; `` insert `` prek keeps its state in `~/.cache/prek` (`PREK_HOME`), one path from every checkout and worktree, rather than devenv's per-checkout `.devenv` state, which a session's sandbox can't write from another worktree, and evaluation fails if that is lost; ``. Verify: `git diff README.md` changes only that row and the inserted text sits between the `XDG_RUNTIME_DIR` clause and `worktrees share the hooks git resolves`.

## 2. Gate

- [x] 2.1 Run `devenv shell --quiet -- scripts/check.sh`. Verify: the summary marks every check pass (`nixfmt`, `openspec validate`, every `build: shell` and every fixture `developer` build included; fix any formatting `nixfmt` reports to what `nixfmt --check` accepts) and the last line is `check: all passed`.

## Workflow follow-up

- Manual check for the git-hooks spec, after merge: restart `claude` from a terminal shell in the main checkout, enter a `.claude/worktrees/<name>` worktree with EnterWorktree, and make a commit both with a bare `git commit` and with `devenv shell --quiet -- git commit`; the pre-commit hook runs and `~/.cache/prek/prek.log` is updated.
- PR description: note that running sessions keep the old `PREK_HOME` until restarted, and that the old `.devenv/.../state/prek` directories are unused and can be removed by hand.
- Archive the change after review.
