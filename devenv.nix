# The parts every Cold Logic project shares. A project imports this plus one
# profile under `profiles/`, which supplies the language toolchain; both add
# to the same `build`, `ci` and `developer` profiles, and so can the project's
# own devenv.nix.
{ pkgs, ... }:
let
  gh-app = import ./packages/gh-app.nix { inherit pkgs; };
  claude-guard = import ./packages/claude-guard.nix { inherit pkgs; };
  claude-plugins-install = pkgs.writeShellApplication {
    name = "claude-plugins-install";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
      gnugrep
      gnutar
      jq
    ];
    text = builtins.readFile ./packages/claude-plugins-install.sh;
  };
  # Where gpg keeps its sockets and lock files, so commits can be signed
  # inside the sandbox. devenv evaluates impurely, so this is the user's.
  gnupgHome =
    let
      set = builtins.getEnv "GNUPGHOME";
    in
    if set != "" then set else "${builtins.getEnv "HOME"}/.gnupg";
  # The agent's socket, for the sandbox to allow. Evaluation can't run
  # gpgconf, so a socket outside the home (a gpgconf.ctl override) is named
  # with COLDLOGIC_GPG_AGENT_SOCKET, set to `gpgconf --list-dirs agent-socket`.
  # The sandbox allows a single socket only on macOS: on Linux it ignores
  # allowUnixSockets, and only allowAllUnixSockets, which this doesn't set,
  # would let a session reach the agent.
  gpgAgentSocket =
    let
      set = builtins.getEnv "COLDLOGIC_GPG_AGENT_SOCKET";
    in
    if set != "" then set else "${gnupgHome}/S.gpg-agent";
in
{
  # Every shell substitutes from the cache this repository's
  # dispatch-updates workflow pushes the profiles' shells to.
  cachix.pull = [ "coldlogic" ];

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
          # The guard hook below applies these to each command inside a
          # wrapper, so `devenv shell --quiet -- scripts/check.sh` is allowed
          # by the `scripts/check.sh` rule. Allowing the wrapper itself would
          # allow anything run through it.
          rules.Bash.allow = [
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
            # gh-app merges only the App's own PRs, approved at their head
            # commit (packages/gh-app.sh); GitHub's ruleset requires the
            # approval as well.
            "gh-app pr merge *"
            "gh-app issue create *"
            "openspec *"
          ];
          # Covered by the allow rules above, but they throw away work the way
          # `git reset --hard` does, so a user decides.
          rules.Bash.ask = [
            "git switch -f *"
            "git switch --force *"
            "git switch --discard-changes *"
            "git switch * -f"
            "git switch * --discard-changes"
            "git switch -fc *"
            "git branch -D *"
            "git branch * -D"
            "git branch --delete --force *"
            "git branch -f *"
            "git branch --force *"
            "git branch * -f"
            "git branch * --force"
            "git worktree remove -f *"
            "git worktree remove --force *"
            "git worktree remove * -f"
            "git worktree remove * --force"
          ];
          # The guard hook denies force pushes, `git reset --hard`, deploys and
          # a flake's dev shell however they are spelled or wrapped. These
          # catch the plain spellings if the hook ever doesn't run. A trailing
          # ` *` is only optional in a rule with no other wildcard, so each is
          # listed bare and with arguments.
          rules.Bash.deny =
            lib.concatMap
              (command: [
                command
                "${command} *"
              ])
              [
                "git push --force"
                "git push -f"
                "git push * --force"
                "git push * -f"
                "wrangler deploy"
                "npx wrangler deploy"
                # Tools come from the devenv shell, never a flake's dev shell.
                "nix develop"
                "git reset --hard"
                "git reset * --hard"
              ];
          # Claude Code also merges these into the sandbox, so no command can
          # read or write them either. A file a tool in the shell needs, like
          # wrangler's `.dev.vars`, can't go here: the guard hook keeps Claude's
          # own tools, and commands naming it, away from it instead.
          rules.Read.deny = [
            "**/.env"
            "**/secrets/**"
          ];
          # Edits and writes anywhere in the checkout (its worktrees included)
          # need no prompt: it is under git, and the gate and review still run
          # before a commit. The deny rules above and below win over it, and
          # the guard hook asks before a change to `.git` or `.claude`. An
          # allow rule rather than `defaultMode = "acceptEdits"`, which would
          # replace the mode the user picked (auto, say). `//` makes the path
          # absolute: the file is generated per checkout.
          rules.Edit.allow = [ "/${config.devenv.root}/**" ];
          rules.Edit.deny = [
            "**/.env"
            "**/secrets/**"
          ];
        };
      };

      # Decides each tool call from what it would run (packages/claude-guard.py).
      # It reads the session's Bash rules, the project's included, from a file
      # written here.
      claude.code.hooks.coldlogic-guard = {
        hookType = "PreToolUse";
        matcher = "Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob";
        command = "${claude-guard}/bin/coldlogic-claude-guard ${
          pkgs.writeText "coldlogic-claude-guard-policy.json" (
            builtins.toJSON (
              lib.genAttrs [ "allow" "ask" "deny" ] (
                kind:
                # Rules can be written under `rules` or, the older way,
                # directly under `permissions`.
                (config.claude.code.permissions.rules.Bash.${kind} or [ ])
                ++ (config.claude.code.permissions.Bash.${kind} or [ ])
              )
            )
          )
        }";
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
        enabledPlugins = {
          "coldlogic@coldlogic-plugins" = true;
          # The coldlogic plugin's dependencies, from its plugin.json. Claude
          # Code would enable them as it installs the plugin, but the install
          # below writes no settings. It installs them from plugin.json, and
          # warns when one there is missing here.
          "codex@openai-codex" = true;
          "pr-review-toolkit@claude-plugins-official" = true;
          "code-review@claude-plugins-official" = true;
          "commit-commands@claude-plugins-official" = true;
          "context7@claude-plugins-official" = true;
        };
        enabledMcpjsonServers = [ "mcp.devenv.sh" ];

        # Paths are absolute: the file is generated per checkout and never
        # committed.
        sandbox = {
          enabled = true;
          # A sandboxed command runs without a prompt: the sandbox's write and
          # network limits are the boundary, and the deny and ask rules and
          # the guard hook still apply. Requiring an allow rule for every
          # command prompted on routine work (fetch, push, reading files).
          autoAllowBashIfSandboxed = true;
          # Off so that a command the sandbox blocks fails rather than being
          # retried outside it. What a session legitimately needs goes into
          # this module, or the project's devenv.nix, through a reviewed PR.
          allowUnsandboxedCommands = false;
          # `gh`, and so `gh-app`, can't verify TLS on macOS without trustd.
          # Claude Code documents this as a possible way to exfiltrate data.
          enableWeakerNetworkIsolation = true;
          filesystem = {
            # No command reads a `.env` file, or its usual variants, at any
            # depth. They are named rather than matched with `.env.*`: Claude
            # Code applies these to its own tools too, ignoring allowRead, so
            # `.env.*` would also hide `.env.example`. The guard hook denies
            # any other `.env.*` named in a command or a file tool. `**/`
            # doesn't match the root here, so each is listed twice.
            denyRead =
              lib.concatMap
                (name: [
                  "${config.devenv.root}/${name}"
                  "${config.devenv.root}/**/${name}"
                ])
                [
                  ".env"
                  ".env.local"
                  ".env.*.local"
                  ".env.development"
                  ".env.production"
                  ".env.staging"
                  ".env.test"
                ]
              ++ [
                "${config.devenv.root}/secrets/**"
                "${config.devenv.root}/**/secrets/**"
              ];
            # A write deny overrides allowWrite, so only `.env` itself is
            # listed. The guard hook keeps other `.env.*` files from being
            # written by name.
            denyWrite = [
              "${config.devenv.root}/.env"
              "${config.devenv.root}/**/.env"
              # gpg needs to write its lock files in its home (allowWrite),
              # but not its configuration or the private keys, which the
              # agent holds outside the sandbox.
              "${gnupgHome}/gpg.conf"
              "${gnupgHome}/gpg-agent.conf"
              "${gnupgHome}/common.conf"
              "${gnupgHome}/dirmngr.conf"
              "${gnupgHome}/scdaemon.conf"
              "${gnupgHome}/gpgsm.conf"
              "${gnupgHome}/tpm2daemon.conf"
              "${gnupgHome}/sshcontrol"
              "${gnupgHome}/private-keys-v1.d"
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
              # gpg's lock files, for signed commits (see denyWrite).
              gnupgHome
            ];
          };
          network = {
            # `devenv shell` needs the daemon, and a build it runs happens
            # outside this sandbox, so this limits a mistake, not an attacker.
            allowUnixSockets = [
              "/nix/var/nix/daemon-socket/socket"
            ]
            # Signs commits. The agent, outside the sandbox, holds the key
            # and asks for the passphrase through pinentry when its cache
            # has expired.
            ++ [ gpgAgentSocket ];
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
              # Documentation and source a session reads from the shell.
              "docs.rs"
              "doc.rust-lang.org"
              "raw.githubusercontent.com"
              "developers.cloudflare.com"
              "nixos.org"
              "search.nixos.org"
              # GitHub Actions logs (`gh run view --log`), so a session can
              # read why CI failed: the results service, and the storage
              # accounts it redirects to, as GitHub lists them in
              # `gh api meta --jq .domains.actions`. Named one by one rather
              # than *.blob.core.windows.net, which is anyone's Azure storage.
              "results-receiver.actions.githubusercontent.com"
            ]
            ++ map (n: "productionresultssa${toString n}.blob.core.windows.net") (
              lib.range 0 19 ++ lib.range 30 49 ++ lib.range 100 199
            );
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
          # The remote's HEAD, remembered for an hour so that not every shell
          # waits on the network: `<time> <remote> <rev>`. Only an entry that
          # says the lock is current is used, so an update or a torn write
          # just fetches again.
          cache="''${DEVENV_STATE:-$DEVENV_ROOT/.devenv/state}/coldlogic-freshness"
          now=$(date +%s)
          latest=""
          at="" cached_remote="" cached_rev=""
          { read -r at cached_remote cached_rev <"$cache"; } 2>/dev/null || true
          case "$at" in
            "" | *[!0-9]*) at=0 ;;
          esac
          age=$((now - at))
          if [ "$cached_remote" = "$remote" ] && [ "$cached_rev" = "$locked" ] && [ "$age" -ge 0 ] && [ "$age" -lt 3600 ]; then
            latest=$cached_rev
          else
            latest=$(GIT_TERMINAL_PROMPT=0 timeout 3 git ls-remote "$remote" HEAD 2>/dev/null | cut -f1) || true
            if [ -n "$latest" ]; then
              mkdir -p "$(dirname "$cache")" 2>/dev/null &&
                echo "$now $remote $latest" >"$cache" 2>/dev/null || true
            fi
          fi
          if [ -n "$latest" ] && [ "$latest" != "$locked" ]; then
            echo "coldlogic-devenv is behind (locked ''${locked:0:7}, latest ''${latest:0:7}); run: devenv update coldlogic-devenv" >&2
          fi
          exit 0
        '';
        before = [ "devenv:enterShell" ];
      };

      # Claude Code loads an enabled plugin only once it is installed for the
      # project, and can't install one here (see the script). Installs each
      # enabled plugin this checkout lacks, at project scope. A shell inside a
      # sandboxed session can't write ~/.claude/plugins, so it warns instead.
      # Never fails the shell.
      tasks."coldlogic:plugins-installed" = {
        exec = "${claude-plugins-install}/bin/claude-plugins-install \"${config.claude.code.settingsPath}\" \"$DEVENV_ROOT\"";
        after = [ "devenv:files" ];
        before = [ "devenv:enterShell" ];
      };

      # OpenSpec's Claude Code skills and commands, generated from the
      # module's openspec rather than tracked: the sandbox doesn't let a
      # session write .claude/skills or .claude/commands, so git failed
      # partway through any stash, rebase or switch that rewrote tracked
      # copies (#32). Only where the project ignores them (adopt.sh adds the
      # lines), so a project still tracking them never has its tree changed.
      # Other tools' files (.agents/, .github/prompts/) are left to the
      # project. Runs again only when openspec changes or the files are
      # gone. A shell inside a sandboxed session can't write them, so it
      # warns instead. Never fails the shell.
      tasks."coldlogic:openspec-files" = {
        exec = ''
          export PATH=${
            pkgs.lib.makeBinPath (
              with pkgs;
              [
                coreutils
                git
                openspec
              ]
            )
          }:$PATH
          cd "$DEVENV_ROOT" || exit 0
          [ -f openspec/config.yaml ] || exit 0
          for f in .claude/skills/openspec-explore/SKILL.md .claude/commands/opsx/explore.md; do
            git check-ignore -q "$f" 2>/dev/null || exit 0
          done
          stamp="''${DEVENV_STATE:-$DEVENV_ROOT/.devenv/state}/coldlogic-openspec"
          want=${pkgs.openspec}
          # Any of them, not a named one: a later openspec may rename them.
          present=""
          if compgen -G '.claude/skills/openspec-*/SKILL.md' >/dev/null && compgen -G '.claude/commands/opsx/*.md' >/dev/null; then
            present=1
          fi
          if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ] && [ -n "$present" ]; then
            exit 0
          fi
          if out=$(DO_NOT_TRACK=1 OPENSPEC_TELEMETRY=0 openspec init --tools claude --no-animation </dev/null 2>&1); then
            mkdir -p "$(dirname "$stamp")" 2>/dev/null && echo "$want" >"$stamp" 2>/dev/null || true
          elif [ -n "$present" ]; then
            echo "coldlogic: OpenSpec's Claude Code skills may be out of date; enter the shell from a terminal, outside a Claude Code session, to regenerate them" >&2
          else
            echo "coldlogic: couldn't generate OpenSpec's Claude Code skills; enter the shell from a terminal, outside a Claude Code session" >&2
            printf '%s\n' "$out" | grep -m1 '^Failed' >&2 || true
          fi
          exit 0
        '';
        before = [ "devenv:enterShell" ];
      };
    };
}
