# The parts every Cold Logic project shares. A project imports this plus one
# profile under `profiles/`, which supplies the language toolchain; both add
# to the same `build`, `ci` and `developer` profiles, and so can the project's
# own devenv.nix.
{ pkgs, ... }:
let
  gh-app = import ./packages/gh-app.nix { inherit pkgs; };
  claude-guard = import ./packages/claude-guard.nix { inherit pkgs; };
  session-relink = import ./packages/session-relink.nix { inherit pkgs; };
  prune-worktrees = import ./packages/prune-worktrees.nix { inherit pkgs gh-app; };
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
    let
      # The generated files devenv links (not its copy or seed modes). The
      # notice compares all of them.
      generatedLinks = lib.filterAttrs (_: file: (file.copyMode or "symlink") == "symlink") config.files;
      # The ones a session links itself: all but the settings, which a session
      # never creates, replaces or removes. Only a terminal shell refreshes it.
      sessionLinks = removeAttrs generatedLinks [ config.claude.code.settingsPath ];
      # packages/session-relink.sh with `opts`, then `--`, then each file in
      # `links` and the store path it should link to. Run from $DEVENV_ROOT.
      # Exits 1 when nothing is stale, 0 when something is, and anything else
      # on an error.
      sessionRelink =
        opts: links:
        "${session-relink}/bin/coldlogic-session-relink ${
          lib.escapeShellArgs (
            opts
            ++ [ "--" ]
            ++ lib.concatLists (
              lib.mapAttrsToList (name: file: [
                name
                "${file.file}"
              ]) links
            )
          )
        }";
      # The status of devenv's two file tasks: skip (exit 0) in a session,
      # run (exit 1) outside one. Nothing else may decide it.
      skipInSession = ''
        [ -n "''${CLAUDECODE:-}" ]
      '';
      # What no session reads or writes, at any depth in the checkout. Each
      # `path` becomes a Read and an Edit deny rule (`**/<path>`) and sandbox
      # denyRead entries; one with `denyWrite` also a sandbox denyWrite entry.
      # Claude Code merges the Read rules into the sandbox, but there `**/`
      # doesn't match the root, so the sandbox entries name each path twice:
      # at the root and below it.
      secrets = [
        {
          path = ".env";
          # Its usual variants, kept from reads only, and only as sandbox
          # denyRead entries: Claude Code applies denyRead to its own tools
          # too, so a Read rule would add nothing. They are named rather than
          # matched with `.env.*`: denyRead wins over allowRead there, so
          # `.env.*` would also hide `.env.example`. The guard hook denies any other `.env.*` named in
          # a command or a file tool. A write deny overrides allowWrite, so
          # only `.env` itself is write-denied; the guard hook keeps other
          # `.env.*` files from being written by name.
          readVariants = [
            ".env.local"
            ".env.*.local"
            ".env.development"
            ".env.production"
            ".env.staging"
            ".env.test"
          ];
          denyWrite = true;
        }
        { path = "secrets/**"; }
      ];
      secretRules = map (secret: "**/${secret.path}") secrets;
      inCheckout = path: [
        "${config.devenv.root}/${path}"
        "${config.devenv.root}/**/${path}"
      ];
      # The main checkout, also when the shell is entered from a linked
      # worktree, whose `.git` file reads `gitdir: <main>/.git/worktrees/<name>`
      # (`<main>` absolute, or relative to the worktree, as git writes it with
      # worktree.useRelativePaths). A WorktreeCreate hook can place agent
      # worktrees (`isolation: worktree`) at `<main>.worktrees/<name>`, beside
      # the main checkout. It goes by the common git dir, so agents spawned
      # from a worktree land beside the main checkout too, not beside that
      # worktree. Any other `.git` (a directory, a submodule's
      # `gitdir: ../.git/modules/<name>`, a layout not known here) leaves the
      # checkout itself, on purpose: its own `.worktrees` is the closest guess,
      # and it opens nothing outside the checkout's parent.
      checkoutFromDotGit =
        root: content:
        let
          linked = builtins.match "gitdir: (.*)/\\.git/worktrees/[^/]+[[:space:]]*" content;
          dir = builtins.head linked;
        in
        if linked == null || dir == "" then
          root
        # `/. +` makes a path, which drops the `..` a relative one has.
        else
          toString (/. + (if lib.hasPrefix "/" dir then dir else "${root}/${dir}"));
      # Evaluated with every shell: the layouts checkoutFromDotGit must read.
      checkoutFromDotGitCases = [
        (checkoutFromDotGit "/w" "gitdir: /a/m/.git/worktrees/x\n" == "/a/m")
        (checkoutFromDotGit "/a/m.worktrees/x" "gitdir: ../../m/.git/worktrees/x\n" == "/a/m")
        (checkoutFromDotGit "/a/m/.claude/worktrees/x" "gitdir: ../../../.git/worktrees/x" == "/a/m")
        (checkoutFromDotGit "/a/m/sub" "gitdir: ../.git/modules/sub\n" == "/a/m/sub")
        (checkoutFromDotGit "/w" "gitdir: /.git/worktrees/x\n" == "/w")
        (checkoutFromDotGit "/w" "not a gitdir line" == "/w")
      ];
      mainCheckout =
        let
          dotGit = "${config.devenv.root}/.git";
        in
        assert lib.assertMsg (lib.all lib.id checkoutFromDotGitCases)
          "coldlogic: checkoutFromDotGit misreads a worktree's .git file";
        if builtins.pathExists dotGit && builtins.readFileType dotGit == "regular" then
          checkoutFromDotGit config.devenv.root (builtins.readFile dotGit)
        else
          config.devenv.root;
      siblingWorktrees = "${mainCheckout}.worktrees";
      # Paths in each of the project's sibling worktrees, as inCheckout's in
      # the checkout: at a worktree's top and below it.
      inSiblingWorktrees = path: [
        "${siblingWorktrees}/*/${path}"
        "${siblingWorktrees}/*/**/${path}"
      ];
      # What a sibling worktree's sandbox write (allowWrite) must not reach
      # at its top, as the main checkout's are protected: its `.git` file and
      # its Claude Code settings, hooks and skills.
      siblingWorktreeConfig = map (path: "${siblingWorktrees}/*/${path}") [
        ".git"
        ".claude/settings.json"
        ".claude/settings.local.json"
        ".claude/hooks"
        ".claude/skills"
      ];
    in
    {
      packages = with pkgs; [
        git
        openspec
        gh-app
        # For `coldlogic-prune-worktrees --dry-run`; the hooks and the task
        # below run it themselves.
        prune-worktrees
      ];

      git-hooks.hooks.nixfmt.enable = true;

      claude.code = {
        enable = true;
        model = lib.mkDefault "opus";
        env = {
          CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          # What a subagent runs on when nothing else picks a model.
          CLAUDE_CODE_SUBAGENT_MODEL = lib.mkDefault "sonnet";
          # devenv makes its runtime dir at `${XDG_RUNTIME_DIR:-/tmp}/devenv-<hash
          # of the checkout>` before it reads this file, so only the
          # environment that launches it can move the dir. The sandbox can't
          # write `/tmp` and drops glob entries from allowWrite (#64), so
          # sessions keep the dir in the devenv cache, which it allows.
          XDG_RUNTIME_DIR = "${builtins.getEnv "HOME"}/.cache/devenv/run";
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
            "git fetch *"
            "git rev-list *"
            # Sessions act on GitHub as the App (see gh-app).
            "gh-app pr view *"
            "gh-app pr checks *"
            "gh-app pr list *"
            "gh-app pr comment *"
            "gh-app pr create *"
            # gh-app merges only the App's own PRs, approved at their head
            # commit (packages/gh-app.sh); GitHub's ruleset requires the
            # approval as well.
            "gh-app pr merge *"
            "gh-app issue create *"
            "gh-app issue view *"
            "gh-app issue list *"
            "gh-app issue comment *"
            "gh-app issue edit *"
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
          rules.Read.deny = secretRules;
          # Edits and writes anywhere in the checkout (its worktrees included)
          # and in the main checkout's sibling worktrees (`<main>.worktrees`,
          # see mainCheckout) need no prompt: they are under git, and the gate
          # and review still run before a commit. The deny rules above and
          # below win over it, and the guard hook asks before a change to
          # `.git` or `.claude`. An allow rule rather than
          # `defaultMode = "acceptEdits"`, which would replace the mode the
          # user picked (auto, say). `//` makes the path absolute: the file is
          # generated per checkout.
          rules.Edit.allow = [
            "/${config.devenv.root}/**"
            "/${siblingWorktrees}/**"
          ];
          rules.Edit.deny = secretRules;
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

      # Removes merged, idle worktrees and their branches
      # (packages/prune-worktrees.sh). A session can't: its sandbox denies
      # writes to a sibling worktree's `.git` and to `.git/worktrees/*`, so
      # `git worktree remove` failed partway (#73). Hooks run outside the
      # Bash sandbox. Each starts the prune detached and returns at once, so a
      # session never waits on it or sees its output, and the prune outlives
      # the session. SessionStart catches what merged since the last session,
      # Stop what merged during a long one; a run within 10 minutes of the
      # last makes either a no-op.
      claude.code.hooks.coldlogic-prune-worktrees = {
        hookType = "SessionStart";
        command = "${prune-worktrees}/bin/coldlogic-prune-worktrees --hook --background";
      };
      claude.code.hooks.coldlogic-prune-worktrees-stop = {
        hookType = "Stop";
        command = "${prune-worktrees}/bin/coldlogic-prune-worktrees --hook --background";
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
            # The secrets above (see `secrets`), in the checkout and in the
            # sibling worktrees allowWrite opens.
            denyRead = lib.concatMap (
              secret:
              lib.concatMap (path: inCheckout path ++ inSiblingWorktrees path) (
                [ secret.path ] ++ secret.readVariants or [ ]
              )
            ) secrets;
            denyWrite =
              lib.concatMap (secret: inCheckout secret.path ++ inSiblingWorktrees secret.path) (
                builtins.filter (secret: secret.denyWrite or false) secrets
              )
              ++ siblingWorktreeConfig
              ++ [
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
            # What `devenv shell` and the tools every shell has write to. A
            # profile adds its toolchain's; the lists concatenate.
            allowWrite = [
              "~/.cache/nix"
              "~/.cache/devenv"
              "~/.local/share/devenv"
              "~/.cache/prek"
              "~/.npm"
              # gpg's lock files, for signed commits (see denyWrite).
              gnupgHome
              # The project's own sibling worktrees, where subagents started
              # with `isolation: worktree` work (see mainCheckout, #45). No
              # other project's.
              siblingWorktrees
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
            # A profile adds its toolchain's registries and documentation.
            allowedDomains = [
              "github.com"
              "api.github.com"
              "codeload.github.com"
              "objects.githubusercontent.com"
              "release-assets.githubusercontent.com"
              "cache.nixos.org"
              "cachix.org"
              "*.cachix.org"
              "registry.npmjs.org"
              # Documentation and source a session reads from the shell.
              "raw.githubusercontent.com"
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

      # In a Claude Code session, devenv's two file tasks never run. Both are
      # built-in, so this is their status: a status that succeeds skips a
      # task without failing it. devenv:files replaces a link with `ln -sf`,
      # which unlinks first, and the sandbox lets the unlink through while
      # denying the create, which deleted the settings (#68). Cleanup unlinks
      # outright. A check used to decide when they were safe to run, and #94
      # showed a link could still vanish, so no check decides it now.
      #
      # The session links the files itself instead (coldlogic:session-files),
      # atomically and one at a time, so one file the sandbox refuses doesn't
      # stop the rest (#78). It never writes the settings link, which only a
      # terminal shell refreshes, in case a settings file changing under a
      # running session is what makes Claude Code remove it (#94). devenv's
      # state file is left as the last terminal shell wrote it, and the next
      # terminal shell's cleanup removes any orphans.
      #
      # devenv defines both tasks only when there are files, so each of these
      # four is guarded the same way: a module with no files gets no partial
      # task holding only a status, and no task ordered against a missing one.
      tasks."devenv:files:cleanup".status = lib.mkIf (config.files != { }) skipInSession;
      tasks."devenv:files".status = lib.mkIf (config.files != { }) skipInSession;

      # The session's own linking: every symlink-mode generated file but the
      # settings, through the atomic relink, which never unlinks a path it is
      # given. It is the only relink-mode call here. devenv:files depends on
      # it, so it never fails: a failure would skip every later task as a
      # failed dependency (#37).
      tasks."coldlogic:session-files" = lib.mkIf (config.files != { }) {
        exec = ''
          [ -n "''${CLAUDECODE:-}" ] || exit 0
          cd "$DEVENV_ROOT" || exit 0
          ${sessionRelink [ ] sessionLinks} >/dev/null 2>&1 || true
          exit 0
        '';
        after = [ "devenv:files:cleanup" ];
        before = [ "devenv:files" ];
      };

      # The one notice for the above (a task's output isn't shown). Silent
      # outside a session and whenever the links are current. Never fails.
      # It compares every generated link, the settings included, and only
      # compares (--check-only), so it writes nothing, not even beside them.
      # Each path is shell-quoted (%q), so one with a space stays one path,
      # and a line of a kind it doesn't know is still listed, as printed, so
      # a new kind can't make the notice go quiet.
      tasks."coldlogic:generated-files-stale" = lib.mkIf (generatedLinks != { }) {
        exec = ''
          [ -n "''${CLAUDECODE:-}" ] || exit 0
          cd "$DEVENV_ROOT" || exit 0
          # 0: something to report; 1: all current; anything else (2 bad
          # usage, 3 a failed command, 127 no binary) means it couldn't
          # check, which gets a notice of its own rather than silence.
          code=0
          out="$(${
            sessionRelink [
              "--check-only"
              "--print"
            ] generatedLinks
          })" || code=$?
          if [ "$code" -gt 1 ]; then
            echo "coldlogic: this Claude Code session couldn't check its generated files (the check exited $code). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell." >&2
            exit 0
          fi
          if [ "$code" = 0 ] && [ -n "$out" ]; then
            # add <list> <item>: <list> with <item> shell-quoted on the end.
            add() {
              local q
              printf -v q '%q' "$2"
              printf '%s' "''${1:+$1 }$q"
            }
            missing=""
            stale=""
            conflict=""
            other=""
            while IFS= read -r line; do
              case "$line" in
                "missing "*) missing="$(add "$missing" "''${line#missing }")" ;;
                "stale "*) stale="$(add "$stale" "''${line#stale }")" ;;
                "conflict "*) conflict="$(add "$conflict" "''${line#conflict }")" ;;
                *) other="$(add "$other" "$line")" ;;
              esac
            done <<<"$out"
            what=""
            [ -z "$missing" ] || what="missing: $missing"
            [ -z "$stale" ] || what="''${what:+$what; }out of date: $stale"
            [ -z "$conflict" ] || what="''${what:+$what; }not links, move them aside first: $conflict"
            [ -z "$other" ] || what="''${what:+$what; }other: $other"
            echo "coldlogic: this Claude Code session can't refresh these generated files ($what). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell. Then restart every Claude Code session open in this checkout, this one included, since a running session can undo the refresh. If a terminal shell doesn't fix them, its evaluation may be stale: run devenv shell --refresh-eval-cache there." >&2
          fi
          exit 0
        '';
        after = [ "devenv:files" ];
        before = [ "devenv:enterShell" ];
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
          age=$((now - 10#$at))
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

      # The same prune from a terminal shell, detached so the shell doesn't
      # wait on it. Inside a session the sandbox would deny the removals, and
      # the hooks above cover it; CI has nothing to clean. Never fails the
      # shell.
      tasks."coldlogic:prune-worktrees" = {
        exec = ''
          [ -z "''${CLAUDECODE:-}" ] || exit 0
          [ -z "''${CI:-}" ] || exit 0
          ${prune-worktrees}/bin/coldlogic-prune-worktrees --background --session-dir "$DEVENV_ROOT" || true
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
