# The parts every Cold Logic project shares. A project imports this plus one
# profile under `profiles/`, which supplies the language toolchain; both add
# to the same `build`, `ci` and `developer` profiles, and so can the project's
# own devenv.nix.
{ pkgs, ... }:
let
  gh-app = import ./packages/gh-app.nix { inherit pkgs; };
in
{
  profiles.developer.module =
    { config, lib, ... }:
    {
      packages = with pkgs; [
        git
        openspec
        gh-app
      ];

      git-hooks.hooks.nixfmt.enable = true;

      claude.code = {
        enable = true;
        model = lib.mkDefault "opus";
        env = {
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          # What a subagent runs on when nothing else picks a model.
          CLAUDE_CODE_SUBAGENT_MODEL = lib.mkDefault "sonnet";
        };
        permissions = {
          # A starting point. Anything broader belongs in the project.
          rules.Bash.allow = [
            "devenv shell --quiet -- *"
            "scripts/check.sh"
            "git status *"
            "git diff *"
            "git log *"
            "git add *"
            "git commit *"
            "git switch *"
            "git branch *"
            "git worktree *"
            # Sessions act on GitHub as the App (see gh-app).
            "gh-app pr view *"
            "gh-app pr checks *"
            "gh-app pr create *"
            "openspec *"
          ];
          # A rule matches the start of the command, so each is repeated behind
          # the devenv wrapper. A sandboxed command runs without a prompt unless
          # one of these matches, and `bash -c` inside the wrapper still gets
          # past them: they are a backstop, not a boundary. A project's own deny
          # rules are not wrapped.
          rules.Bash.deny =
            let
              denied = [
                "git push --force *"
                "git push -f *"
                "git push * --force *"
                "git push * -f *"
                "wrangler deploy *"
                "npx wrangler deploy *"
                # Tools come from the devenv shell, never a flake's dev shell.
                "nix develop *"
                # A backstop to auto mode's classifier.
                "git reset --hard *"
              ];
            in
            denied ++ map (command: "devenv * -- ${command}") denied;
          # Covers Claude's file tools only; the sandbox below covers the shell.
          rules.Read.deny = [
            "./.env"
            "./.env.*"
            "./**/secrets/**"
          ];
        };
      };

      # Merges with the definition claude.nix writes under the same key, which
      # has no option for these. A project adds its own keys the same way.
      files."${config.claude.code.settingsPath}".json = {
        extraKnownMarketplaces = {
          coldlogic-plugins = {
            source = {
              source = "github";
              repo = "coldlogicsolutions/claude-plugins-coldlogic";
            };
            autoUpdate = true;
          };
          # Hosts a dependency of the coldlogic plugin. Claude Code installs
          # a dependency only from a marketplace it knows.
          openai-codex.source = {
            source = "github";
            repo = "openai/codex-plugin-cc";
          };
        };
        enabledPlugins."coldlogic@coldlogic-plugins" = true;
        enabledMcpjsonServers = [ "mcp.devenv.sh" ];

        # Stops `cat .env` in the shell, which `Read` deny rules don't reach.
        # Paths are absolute: the file is generated per checkout and never
        # committed.
        sandbox = {
          enabled = true;
          filesystem = {
            denyRead = [
              "${config.devenv.root}/.env"
              "${config.devenv.root}/.env.*"
              "${config.devenv.root}/**/secrets/**"
            ];
            # What `devenv shell` and the toolchains inside it write to.
            allowWrite = [
              "~/.cache/nix"
              "~/.cache/devenv"
              "~/.local/share/devenv"
              "~/.cargo/registry"
              "~/.cargo/git"
              "~/.cache/prek"
              "~/.npm"
              # wrangler's state and the Worker build tools' downloads, on
              # macOS and Linux.
              "~/Library/Preferences/.wrangler"
              "~/.config/.wrangler"
              "~/Library/Caches/worker-build"
              "~/.cache/worker-build"
              "~/Library/Caches/.wasm-pack"
              "~/.cache/.wasm-pack"
            ];
          };
          network = {
            # `devenv shell` needs the daemon, and a build it runs happens
            # outside this sandbox, so this limits a mistake, not an attacker.
            allowUnixSockets = [ "/nix/var/nix/daemon-socket/socket" ];
            # `wrangler dev` and the integration suites listen on localhost.
            allowLocalBinding = true;
            allowedDomains = [
              "github.com"
              "api.github.com"
              "codeload.github.com"
              "objects.githubusercontent.com"
              "release-assets.githubusercontent.com"
              "cache.nixos.org"
              "cachix.org"
              "*.cachix.org"
              "crates.io"
              "*.crates.io"
              "static.rust-lang.org"
              "registry.npmjs.org"
              "workers.cloudflare.com"
            ];
          };
        };
      };

      # git-hooks.nix installs the pre-commit hook into the *shared* hooks
      # dir (`git rev-parse --git-dir`, which for worktrees resolves to the
      # common .git/hooks) and bakes the installing worktree's absolute
      # `.pre-commit-config.yaml` path into it. Whichever worktree last ran
      # `devenv shell` wins for every other worktree. Give each worktree its
      # own per-worktree hooks dir so `prek install` writes there instead.
      # A task ordered before the install, not enterShell (which runs after
      # it): otherwise a fresh worktree's first shell installs into the shared
      # dir and then points itself at an empty one.
      tasks."coldlogic:worktree-hooks-path" = {
        exec = ''
          git_dir="$(git -C "$DEVENV_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || git_dir=""
          if [ -n "$git_dir" ]; then
            # Writes only on a change: the sandbox can't write .git/config, and
            # this runs on every `devenv shell` a session starts.
            if [ "$(git -C "$DEVENV_ROOT" config --local --type=bool --get extensions.worktreeConfig)" != true ]; then
              git -C "$DEVENV_ROOT" config extensions.worktreeConfig true
            fi
            if [ "$(git -C "$DEVENV_ROOT" config --worktree --get core.hooksPath)" != "$git_dir/hooks" ]; then
              git -C "$DEVENV_ROOT" config --worktree core.hooksPath "$git_dir/hooks"
            fi
          fi
        '';
        before = [ "devenv:git-hooks:install" ];
      };

      # Warns when this module is locked behind its remote, and is otherwise
      # silent; it never fails the shell. The plugin's staleness.sh runs the
      # same comparison for Claude sessions. Keep the two in step.
      tasks."coldlogic:setup-freshness" = {
        exec = ''
          export PATH=${
            pkgs.lib.makeBinPath (
              with pkgs;
              [
                coreutils
                git
                jq
              ]
            )
          }:$PATH
          lock="$DEVENV_ROOT/devenv.lock"
          [ -f "$lock" ] || exit 0
          node=$(jq -c '.nodes."coldlogic-devenv".locked // empty' "$lock")
          [ -n "$node" ] || exit 0
          locked=$(jq -r '.rev // empty' <<<"$node")
          case "$(jq -r '.type' <<<"$node")" in
            github) remote="https://github.com/$(jq -r '"\(.owner)/\(.repo)"' <<<"$node")" ;;
            git) remote=$(jq -r '.url' <<<"$node") ;;
            *) exit 0 ;; # a local path: input while developing the module
          esac
          [ -n "$locked" ] || exit 0
          latest=$(GIT_TERMINAL_PROMPT=0 timeout 3 git ls-remote "$remote" HEAD 2>/dev/null | cut -f1) || true
          if [ -n "$latest" ] && [ "$latest" != "$locked" ]; then
            echo "coldlogic-devenv is behind (locked ''${locked:0:7}, latest ''${latest:0:7}); run: devenv update coldlogic-devenv" >&2
          fi
          exit 0
        '';
        before = [ "devenv:enterShell" ];
      };
    };
}
