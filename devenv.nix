# The parts every Cold Logic project shares. A project imports this plus one
# profile under `profiles/`, which supplies the language toolchain; both add
# to the same `build`, `ci` and `developer` profiles, and so can the project's
# own devenv.nix.
{ pkgs, ... }:
let
  gh-app = import ./packages/gh-app.nix { inherit pkgs; };
  claude-guard = import ./packages/claude-guard.nix { inherit pkgs; };
  session-relink = import ./packages/session-relink.nix { inherit pkgs; };
  session-shell = import ./packages/session-shell.nix { inherit pkgs; };
  memory-recall = import ./packages/memory-recall.nix { inherit pkgs; };
  memory-migrate = import ./packages/memory-migrate.nix { inherit pkgs; };
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
  # The shared memory store (README, "Shared memory"), opted into per machine
  # with COLDLOGIC_MEMORY_URL, read here as gnupgHome reads GNUPGHOME.
  # normaliseMemoryUrl returns the URL without trailing slashes when the
  # whole value is `http(s)://<host>[:<port>][/<segment>...]` (host and
  # segments from letters, digits, `.`, `_`, `~`, `-`), and "" otherwise: no
  # credentials, query, fragment or space. The URL only reaches a shell
  # through escapeShellArg, so this catches a mistake early rather than
  # stopping injection. The recall hook checks it with the same pattern.
  normaliseMemoryUrl =
    value:
    let
      matched = builtins.match "(https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*)/*" value;
    in
    if matched == null then "" else builtins.head matched;
  # Evaluated with every shell, where memoryUrl asserts them.
  normaliseMemoryUrlCases = [
    (normaliseMemoryUrl "https://m.example.ts.net" == "https://m.example.ts.net")
    (normaliseMemoryUrl "https://m.example.ts.net/" == "https://m.example.ts.net")
    (normaliseMemoryUrl "https://m.example.ts.net///" == "https://m.example.ts.net")
    (normaliseMemoryUrl "http://10.0.0.5:8000" == "http://10.0.0.5:8000")
    (normaliseMemoryUrl "https://h/base/path/" == "https://h/base/path")
    (normaliseMemoryUrl "m.example.ts.net" == "")
    (normaliseMemoryUrl "ftp://h" == "")
    (normaliseMemoryUrl "https://u:p@h" == "")
    (normaliseMemoryUrl "https://h?x=1" == "")
    (normaliseMemoryUrl "https://h#f" == "")
    (normaliseMemoryUrl "https://h/a b" == "")
    (normaliseMemoryUrl "" == "")
    # No IPv6 literal: the host has no brackets, so `[::1]` can't be set.
    (normaliseMemoryUrl "http://[::1]:8000" == "")
  ];
  # Whether a normalised memory URL's host is this machine: `localhost` or a
  # name under it (with or without the root's trailing dot), 127.0.0.0/8 in
  # dotted form, or 0.0.0.0. The sandbox's allowLocalBinding lets a session's
  # commands reach such a host past the proxy, so the store's REST API, and
  # with it the ask rules on the MCP tools, could be bypassed from the Bash
  # tool. It's warned about, not refused: a store on loopback is a reasonable
  # trial setup. Other spellings of 127.0.0.1 (an integer, hex) aren't caught.
  memoryLoopback =
    url:
    let
      hostMatch = builtins.match "https?://([^:/]+).*" url;
      host = if hostMatch == null then "" else pkgs.lib.toLower (builtins.head hostMatch);
    in
    builtins.match "(.+\\.)?localhost\\.?" host != null
    || builtins.match "127(\\.[0-9]+){0,3}\\.?" host != null
    || builtins.match "0+(\\.0+){0,3}" host != null;
  memoryLoopbackCases = [
    (memoryLoopback "http://localhost:8000")
    (memoryLoopback "http://LocalHost")
    (memoryLoopback "http://localhost.")
    (memoryLoopback "http://memory.localhost/base")
    (memoryLoopback "http://127.0.0.1:8000")
    (memoryLoopback "http://127.1.2.3")
    (memoryLoopback "http://127.1")
    (memoryLoopback "http://0.0.0.0:8000")
    (!memoryLoopback "https://m.example.ts.net")
    (!memoryLoopback "http://10.0.0.5:8000")
    (!memoryLoopback "http://127.example.com")
    (!memoryLoopback "http://localhost.example.com")
    (!memoryLoopback "http://notlocalhost")
    (!memoryLoopback "http://1270.0.0.1")
    (!memoryLoopback "")
  ];
  # "" when unset, or set but unusable, which is warned about and otherwise
  # treated as unset: nothing else fails the shell over optional settings.
  memoryUrl =
    let
      set = builtins.getEnv "COLDLOGIC_MEMORY_URL";
      url = normaliseMemoryUrl set;
    in
    assert pkgs.lib.assertMsg (pkgs.lib.all pkgs.lib.id normaliseMemoryUrlCases)
      "coldlogic: normaliseMemoryUrl misreads a memory store URL";
    assert pkgs.lib.assertMsg (pkgs.lib.all pkgs.lib.id memoryLoopbackCases)
      "coldlogic: memoryLoopback misreads a memory store URL";
    if set != "" && url == "" then
      pkgs.lib.warn "coldlogic: COLDLOGIC_MEMORY_URL isn't an http(s) URL without credentials, query or fragment, so the shared memory store is off" ""
    else if memoryLoopback url then
      pkgs.lib.warn "coldlogic: COLDLOGIC_MEMORY_URL is on this machine (loopback), and the sandbox's allowLocalBinding is on, so a session's commands may reach the store directly and bypass the ask rules on its memory tools" url
    else
      url;
  # The GitHub login for the `scope:user:<login>` tag, in lower case; "" when
  # unset, or set but unusable (warned about).
  memoryUser =
    let
      set = builtins.getEnv "COLDLOGIC_MEMORY_USER";
    in
    if builtins.match "[A-Za-z0-9][A-Za-z0-9-]*" set != null then
      pkgs.lib.toLower set
    else if set != "" then
      pkgs.lib.warn "coldlogic: COLDLOGIC_MEMORY_USER isn't a GitHub login, so no user scope is used" ""
    else
      "";
  memoryConfigured = memoryUrl != "";
  # Turns Claude Code's built-in auto memory off, independently of the URL:
  # only the exact value 1 does, and any other value leaves it alone without
  # a warning, since there is no usable-but-wrong value to catch.
  autoMemoryDisabled = builtins.getEnv "COLDLOGIC_DISABLE_AUTO_MEMORY" == "1";
in
{
  # Every shell substitutes from the cache this repository's
  # dispatch-updates workflow pushes the profiles' shells to.
  cachix.pull = [ "coldlogic" ];

  profiles.developer.module =
    {
      config,
      lib,
      options,
      ...
    }:
    let
      # The generated files devenv links (not its copy or seed modes). The
      # notice compares all of them.
      generatedLinks = lib.filterAttrs (_: file: (file.copyMode or "symlink") == "symlink") config.files;
      # The ones a session links itself: all but the settings, which a session
      # never creates, replaces or removes. Only a terminal shell refreshes it,
      # or the `claude` wrapper before a session starts.
      sessionLinks = removeAttrs generatedLinks [ config.claude.code.settingsPath ];
      # `claude`, which checks the settings path after a failed refresh, in
      # whichever checkout it starts: so relative to the checkout. The option
      # is absolute: devenv's src/modules/integrations/claude.nix (rev
      # 9655d32, as locked) defaults it to
      # "${config.devenv.root}/.claude/settings.json", and its `files` key is
      # that path. So the root comes off here; a path a project sets outside
      # its root stays absolute, which the wrapper checks as it is.
      claude-wrapper = import ./packages/claude-wrapper.nix {
        inherit pkgs;
        settingsPath = lib.removePrefix "${config.devenv.root}/" config.claude.code.settingsPath;
      };
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
      # packages/session-shell.sh: what a shell does differently in a session.
      sessionShell = "${session-shell}/bin/coldlogic-session-shell";
      # The hooks devenv:git-hooks:install installs, worked out as devenv does:
      # `expectedHooks` and `stageHookName` in devenv's
      # src/modules/integrations/git-hooks.nix, over git-hooks.nix's read-only
      # `installStages` (modules/pre-commit.nix: the enabled hooks' stages).
      # The `or` covers devenv's stub module when git-hooks isn't an input.
      expectedHooks =
        let
          stages = config.git-hooks.installStages or [ ];
          hookName =
            stage:
            if stage == "manual" then
              null
            else if
              builtins.elem stage [
                "commit"
                "merge-commit"
                "push"
              ]
            then
              "pre-${stage}"
            else
              stage;
        in
        lib.unique (
          if stages == [ ] then
            [ "pre-commit" ]
          else
            builtins.filter (hook: hook != null) (map hookName stages)
        );
      # Whether devenv installs any hook here (empty when every enabled hook
      # is manual-stage).
      hooksExpected = config.git-hooks.enable && expectedHooks != [ ];
      # notice <key> <text>: once per session (packages/session-shell.sh), and
      # printed anyway if the helper fails. forget <key>: when the condition is gone.
      noticeFunctions = ''
        notice() { ${sessionShell} notice "$1" "$2" || echo "$2" >&2; }
        forget() { ${sessionShell} clear "$1" || true; }
      '';
      # The generated files only a session started in this checkout reads. A
      # session that reads them from another checkout isn't told about these.
      sessionOnlyFiles = [
        config.claude.code.settingsPath
        ".mcp.json"
      ];
      otherLinks = removeAttrs generatedLinks sessionOnlyFiles;
      # Inside a Claude Code session: the `claude` wrapper's marker
      # (packages/claude-wrapper.sh), or Claude Code's own variable, for a
      # session the wrapper didn't start (the desktop app, an IDE extension).
      # The shell tasks' session test: no task may decide it another way, and
      # it must never be narrower than CLAUDECODE alone, or such a session
      # would run devenv's link step in its sandbox (#68). The `claude`
      # wrapper's nested check (packages/claude-wrapper.sh) differs on
      # purpose: it reads CLAUDE_CODE_CHILD_SESSION, not CLAUDECODE, since an
      # IDE extension sets CLAUDECODE in its terminals, where no session runs
      # yet and the wrapper must refresh. Its refresh clears both variables
      # so this test lets the file tasks run.
      inSession = ''{ [ -n "''${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "''${CLAUDECODE:-}" ]; }'';
      # The status of devenv's two file tasks: skip (exit 0) in a session,
      # run (exit 1) outside one.
      skipInSession = ''
        ${inSession}
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
          # of the `.env` files only `.env` itself is write-denied; the guard
          # hook keeps other `.env.*` files from being written by name.
          # `secrets/**` below is write-denied whole.
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
        {
          path = "secrets/**";
          denyWrite = true;
        }
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
      # The shared memory store's MCP tools, by name, for the rules below and
      # the self-check. Reading and storing need no prompt; everything that
      # changes or removes memories asks, by a tool. Tools in neither list
      # get no rule, so the permission mode decides, and so does a tool a
      # later version of the service adds: no glob allows the whole server.
      memoryAllowTools = [
        "memory_search"
        "memory_list"
        "memory_health"
        "memory_stats"
        "memory_store"
      ];
      memoryAskTools = [
        "memory_delete"
        "memory_update"
        "memory_cleanup"
        "memory_consolidate"
        "memory_quality"
        "memory_resolve"
        "memory_distill"
        "mistake_note_update"
        "mistake_note_delete"
        "unquarantine_memory"
      ];
      memoryTool = tool: "mcp__memory__${tool}";
      # This module's own contribution to the settings for the auto memory
      # switch, a binding of its own so the self-check can read it apart from
      # a project's own `autoMemoryEnabled`, which the merged settings mix in.
      autoMemorySetting = lib.optionalAttrs autoMemoryDisabled { autoMemoryEnabled = false; };
      autoMemoryEnv = lib.optionalAttrs autoMemoryDisabled { COLDLOGIC_DISABLE_AUTO_MEMORY = "1"; };
      # Likewise this module's contributions for the memory store, used where
      # they're generated below.
      memoryEnv = lib.optionalAttrs memoryConfigured (
        {
          COLDLOGIC_MEMORY_URL = memoryUrl;
        }
        // lib.optionalAttrs (memoryUser != "") { COLDLOGIC_MEMORY_USER = memoryUser; }
      );
      memoryServers = lib.optionalAttrs memoryConfigured {
        memory = {
          type = "http";
          url = "${memoryUrl}/mcp";
        };
      };
      # The module's whole definition of claude.code.mcpServers when the store
      # is configured: claude.nix's server, the option's default, which any
      # definition replaces, so it is added back, and the store's. A project
      # that replaces the option replaces this too; the self-check reads this
      # binding, so that is the project's choice and not a failure.
      memoryMcpServers = options.claude.code.mcpServers.default // memoryServers;
      memoryEnabledServers = lib.optional memoryConfigured "memory";
      # The store's tools, each by its full name (`""` renders the bare name),
      # never as a glob over the server (see memoryAllowTools). Ask is checked
      # before allow, so an ask on the server would prompt on every read. The
      # claude.ai connector of the same store is denied: its calls would go
      # over the public endpoint, outside these rules. A connector's tools
      # keep its display name's case (`mcp__claude_ai_Granola__*`), so both
      # names the account's connector may have, `Memory` and `memory`, are
      # denied; one named anything else isn't covered.
      memoryConnectorRules = map (name: "mcp__claude_ai_${name}__*") [
        "memory"
        "Memory"
      ];
      memoryRules = lib.optionalAttrs memoryConfigured (
        lib.genAttrs (map memoryTool memoryAllowTools) (_: {
          allow = [ "" ];
        })
        // lib.genAttrs (map memoryTool memoryAskTools) (_: {
          ask = [ "" ];
        })
        // lib.genAttrs memoryConnectorRules (_: {
          deny = [ "" ];
        })
      );
      # Prints the session's shared memories and when to save one
      # (packages/memory-recall.sh) on every source, a compaction or a clear
      # included, after which the text would otherwise be gone. It runs
      # outside the Bash sandbox, which keeps the store's host out (see
      # allowedDomains), and exits 0 within about 3 seconds whatever the store
      # does: its requests share one 3-second budget, however many scopes it
      # asks for and however slowly the store answers.
      memoryHooks = lib.optionalAttrs memoryConfigured {
        coldlogic-memory-recall = {
          hookType = "SessionStart";
          command =
            "${memory-recall}/bin/coldlogic-memory-recall --url ${lib.escapeShellArg memoryUrl}"
            + lib.optionalString (memoryUser != "") " --user ${lib.escapeShellArg memoryUser}"
            + lib.optionalString autoMemoryDisabled " --auto-memory-off";
        };
      };
      # Whether an `allowedDomains` entry lets the sandbox reach host, as the
      # sandbox matches them (sandbox-runtime's matchesDomainPattern): `*`
      # matches every host, `*.<suffix>` any host below the suffix, anything
      # else only that host, case-insensitively, and an entry may end in
      # `:<port>`. Here `*.<suffix>` also counts as covering the suffix itself,
      # which the sandbox doesn't do, to err towards failing the self-check.
      domainCovers =
        host: entry:
        let
          lower = lib.toLower entry;
          withoutPort = builtins.match "(.*):[0-9]+" lower;
          pattern = if withoutPort == null then lower else builtins.head withoutPort;
          suffix = lib.removePrefix "*." pattern;
          h = lib.toLower host;
        in
        pattern == "*"
        || h == pattern
        || (lib.hasPrefix "*." pattern && (h == suffix || lib.hasSuffix ".${suffix}" h));
      # Evaluated with every shell, by the self-check below.
      domainCoversCases = [
        (domainCovers "m.example.ts.net" "m.example.ts.net")
        (domainCovers "m.example.ts.net" "M.Example.TS.net")
        (domainCovers "m.example.ts.net" "m.example.ts.net:443")
        (domainCovers "m.example.ts.net" "*.ts.net")
        (domainCovers "m.example.ts.net" "*.example.ts.net")
        (domainCovers "m.example.ts.net" "*.example.ts.net:8443")
        (domainCovers "m.example.ts.net" "*.EXAMPLE.ts.net:443")
        (domainCovers "example.ts.net" "*.example.ts.net")
        (domainCovers "m.example.ts.net" "*")
        (!domainCovers "m.example.ts.net" "example.ts.net")
        (!domainCovers "m.example.ts.net" "*.other.ts.net")
        (!domainCovers "m.example.ts.net" "*.xample.ts.net")
        (!domainCovers "m.example.ts.net" "github.com")
        (!domainCovers "m.example.ts.net" "m.example.ts.net.evil.com")
      ];
      # A self-check of the generated settings for the memory store and the
      # auto memory switch, so a change that drops an ask rule, allows a
      # destructive tool or opens the store's host to the sandbox fails
      # evaluation. Each switch is checked on and off; the gate builds the
      # shell with both set, with neither, and with each alone
      # (scripts/check.sh). It runs in
      # every project that imports this module, so where a switch is off it
      # checks only merged keys whose names only this module uses (the
      # COLDLOGIC_ variables, the connector's rule, the recall hook), never
      # one a project may set itself (its own `autoMemoryEnabled`, or a
      # `memory` server with its rules and enabledMcpjsonServers entry, which
      # an unconditional one of this module's would pass as). It reads the
      # settings, so only
      # coldlogic:generated-files-stale, which nothing in them refers to, may
      # use it: from a hook command or claude.code.env it would recurse.
      memorySettingsCases =
        let
          settings = config.files."${config.claude.code.settingsPath}".json;
          env = settings.env or { };
          allow = settings.permissions.allow or [ ];
          ask = settings.permissions.ask or [ ];
          deny = settings.permissions.deny or [ ];
          enabled = settings.enabledMcpjsonServers or [ ];
          recallCommands = builtins.filter (lib.hasInfix "coldlogic-memory-recall") (
            lib.concatMap (entry: map (hook: hook.command or "") (entry.hooks or [ ])) (
              settings.hooks.SessionStart or [ ]
            )
          );
          host =
            let
              matched = builtins.match "https?://([^/:]+).*" memoryUrl;
            in
            if matched == null then "" else builtins.head matched;
          # The project's own allowedDomains entries that let the sandbox
          # reach the store. Deliberately a hard failure even though a
          # project chose them: the developer opted into the store, and a
          # sandbox that reaches it lets a command delete memories around the
          # ask rules. The case's name says which entries and what to do.
          covering = builtins.filter (domainCovers host) (settings.sandbox.network.allowedDomains or [ ]);
          coveringList = lib.concatMapStringsSep ", " builtins.toJSON covering;
          hostCase =
            if host == "" then
              "the store's host can be read from COLDLOGIC_MEMORY_URL"
            else if covering == [ ] then
              "the store's host kept out of the sandbox, by name or by a wildcard"
            else
              "the sandbox's allowedDomains entry ${coveringList} covers the memory store's host ${host}, so a session's commands could reach it around the ask rules: narrow that entry so it doesn't cover ${host}, or unset COLDLOGIC_MEMORY_URL";
        in
        {
          "domainCovers reads allowedDomains entries as the sandbox does" = lib.all lib.id domainCoversCases;
        }
        // (
          if autoMemoryDisabled then
            {
              "autoMemoryEnabled is false" = (settings.autoMemoryEnabled or null) == false;
              "env sets COLDLOGIC_DISABLE_AUTO_MEMORY" = (env.COLDLOGIC_DISABLE_AUTO_MEMORY or null) == "1";
            }
          else
            # The merged variable, a name only this module uses. A project may
            # set autoMemoryEnabled itself, so the merged key can't be read
            # here; the module's own binding is, which catches its condition
            # being lost, though not a generation site that bypasses it.
            {
              "env has no COLDLOGIC_DISABLE_AUTO_MEMORY" = !(env ? COLDLOGIC_DISABLE_AUTO_MEMORY);
              "the module sets no autoMemoryEnabled" = autoMemorySetting == { };
            }
        )
        // (
          if memoryConfigured then
            {
              # The module's own definition, not the merged .mcp.json, which
              # a project may replace.
              "the module keeps claude.nix's mcp.devenv.sh server" = memoryMcpServers ? "mcp.devenv.sh";
              "a SessionStart recall hook, with --auto-memory-off exactly when auto memory is off" =
                recallCommands != [ ]
                && lib.all (
                  command: lib.hasInfix " --auto-memory-off" command == autoMemoryDisabled
                ) recallCommands;
              "both MCP servers enabled" =
                builtins.elem "memory" enabled && builtins.elem "mcp.devenv.sh" enabled;
              "every read tool allowed" = lib.all (tool: builtins.elem (memoryTool tool) allow) memoryAllowTools;
              "no destructive tool allowed" =
                !(lib.any (tool: builtins.elem (memoryTool tool) allow) memoryAskTools);
              "every destructive tool asks" = lib.all (tool: builtins.elem (memoryTool tool) ask) memoryAskTools;
              # Written out, not read from memoryConnectorRules, so dropping a
              # name there fails here.
              "the connector's tools denied, as memory and as Memory" =
                builtins.elem "mcp__claude_ai_memory__*" deny && builtins.elem "mcp__claude_ai_Memory__*" deny;
              "the module's memory server URL" = (memoryMcpServers.memory.url or null) == "${memoryUrl}/mcp";
              "env sets COLDLOGIC_MEMORY_URL" = (env.COLDLOGIC_MEMORY_URL or null) == memoryUrl;
              ${hostCase} = host != "" && covering == [ ];
            }
          else
            # Only merged keys whose names no one but this module uses, so a
            # binding that loses its condition is caught where it lands. Not
            # checked: a `memory` server, its enabledMcpjsonServers entry and
            # `mcp__memory__*` rules, all names a project may use for a server
            # of its own; an unconditional one of those passes.
            {
              "no hook named coldlogic-memory-recall" = !(config.claude.code.hooks ? coldlogic-memory-recall);
              "no SessionStart hook runs coldlogic-memory-recall" = recallCommands == [ ];
              "env has no COLDLOGIC_MEMORY_URL or COLDLOGIC_MEMORY_USER" =
                !(env ? COLDLOGIC_MEMORY_URL) && !(env ? COLDLOGIC_MEMORY_USER);
              "no rule names the claude.ai memory connector" =
                !(lib.any (
                  rule: lib.hasPrefix "mcp__claude_ai_memory__" rule || lib.hasPrefix "mcp__claude_ai_Memory__" rule
                ) (allow ++ ask ++ deny));
            }
        );
      # "" once the cases hold.
      memorySettingsCheck =
        let
          failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) memorySettingsCases);
        in
        assert lib.assertMsg (failed == [ ])
          "coldlogic: the generated memory settings fail their self-check: ${lib.concatStringsSep "; " failed}";
        "";
    in
    {
      packages = with pkgs; [
        git
        openspec
        gh-app
        # For `coldlogic-prune-worktrees --dry-run`; the hooks and the task
        # below run it themselves.
        prune-worktrees
        # `claude`, ahead of the real one on PATH: refreshes the generated
        # files before it starts a session, and marks that session
        # (packages/claude-wrapper.sh).
        claude-wrapper
        # The shared memory store's recall hook, to run by hand, and the
        # one-off import of auto memory files, run from a terminal. Here
        # whether or not a store is configured, so the gate's shell build
        # always runs their tests.
        memory-recall
        memory-migrate
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
          # The checkout these settings were generated for. A session carries
          # it into every command, so a shell it enters in another checkout
          # knows the session reads its settings, `.mcp.json` and skills from
          # here (packages/session-shell.sh, own-checkout).
          COLDLOGIC_SESSION_ROOT = config.devenv.root;
        }
        # A session enters `devenv shell` for every command and evaluates this
        # file with its own environment. One started without these variables
        # (the desktop app, an IDE) would otherwise relink `.mcp.json` without
        # the store, and evaluate settings without autoMemoryEnabled, which
        # coldlogic:generated-files-stale would report as stale. The URL is no
        # secret, and the sandbox still keeps commands from it.
        // memoryEnv
        // autoMemoryEnv;
        # The shared memory store, over the tailnet, whose ACL is its access
        # control, so no headers. claude.nix's server is the option's default,
        # which any definition replaces, so it is added back here; and the
        # condition is on the whole value, since a definition holding only a
        # false `mkIf` would still replace the default and leave none.
        mcpServers = lib.mkIf (memoryServers != { }) memoryMcpServers;
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

      # The memory store's rules (memoryRules) and recall hook (memoryHooks).
      # A module of its own because the rules and hooks here are written as
      # attribute paths, which a generated set can't join.
      imports = [
        {
          claude.code.permissions.rules = memoryRules;
          claude.code.hooks = memoryHooks;
        }
      ];

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
        enabledMcpjsonServers = [ "mcp.devenv.sh" ] ++ memoryEnabledServers;
      }
      # Claude Code's built-in auto memory, off only with
      # COLDLOGIC_DISABLE_AUTO_MEMORY=1, whether or not a store is configured.
      # Absent otherwise, so the user's own setting applies.
      // autoMemorySetting
      // {

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
            # The shared memory store's host is deliberately not here: the
            # MCP connection and the recall hook don't need it, and without it
            # a session's commands can't reach the REST API, so the memory
            # tools' ask rules are the only path to a destructive call. The
            # self-check (memorySettingsCases) fails the shell if it's added.
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

      # Hooks live in the hooks directory git resolves, which worktrees share
      # (the main checkout's `.git/hooks`). Since devenv's change of 2026-10-19
      # the hook there names its configuration by a relative path, so it reads
      # the committing worktree's own; the module needs a devenv at least that
      # new, and no longer gives each worktree a hooks path (#67).
      #
      # In a session, the install is skipped where it can't write that
      # directory, which the sandbox protects. Exit 0 skips; any error exits
      # non-zero, which runs the install as devenv defines it.
      #
      # Both this and the check below exist only when some hook is expected.
      # With every enabled hook in the manual stage devenv installs none, and
      # the script, given no hooks, would look for pre-commit and report it
      # missing on every terminal shell.
      tasks."devenv:git-hooks:install".status = lib.mkIf hooksExpected ''
        ${sessionShell} skip-hooks-install ${lib.escapeShellArgs expectedHooks}
      '';

      # A status prints nothing, so this says when commits here will run no
      # hook: the install was skipped, or didn't add one. Silent when every
      # expected hook is in place. Never fails.
      tasks."coldlogic:hooks-check" = lib.mkIf hooksExpected {
        exec = ''
          ${sessionShell} hooks-check ${lib.escapeShellArgs expectedHooks} || true
          exit 0
        '';
        after = [ "devenv:git-hooks:install" ];
        before = [ "devenv:enterShell" ];
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
      # terminal shell or the `claude` wrapper, before a session starts,
      # refreshes, in case a settings file changing under a
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
          ${inSession} || exit 0
          cd "$DEVENV_ROOT" || exit 0
          ${sessionRelink [ ] sessionLinks} >/dev/null 2>&1 || true
          exit 0
        '';
        after = [ "devenv:files:cleanup" ];
        before = [ "devenv:files" ];
      };

      # The one notice for the above (a task's output isn't shown). Silent
      # outside a session and whenever the links are current, and printed
      # once per session (packages/session-shell.sh). Never fails. It
      # compares every generated link, the settings included, except where
      # the session reads its settings and `.mcp.json` from another checkout
      # (own-checkout), which leaves those two out. It only compares
      # (--check-only), so it writes nothing, not even beside them.
      # Each path is shell-quoted (%q), so one with a space stays one path,
      # and a line of a kind it doesn't know is still listed, as printed, so
      # a new kind can't make the notice go quiet.
      tasks."coldlogic:generated-files-stale" = lib.mkIf (generatedLinks != { }) {
        # memorySettingsCheck is "", and fails evaluation if the memory
        # settings are wrong: here, the one place that reads every generated
        # file and feeds none of them.
        exec = ''
          ${memorySettingsCheck}${inSession} || exit 0
          cd "$DEVENV_ROOT" || exit 0
          ${noticeFunctions}
          # 10: the session reads its own files from another checkout. Any
          # other code (a crashed or missing helper included) compares
          # everything, so a doubt still reports.
          own=0
          ${sessionShell} own-checkout || own=$?
          # 0: something to report; 1: all current; anything else (2 bad
          # usage, 3 a failed command, 127 no binary) means it couldn't
          # check, which gets a notice of its own rather than silence.
          code=0
          if [ "$own" = 10 ]; then
            out="$(${
              sessionRelink [
                "--check-only"
                "--print"
              ] otherLinks
            })" || code=$?
          else
            out="$(${
              sessionRelink [
                "--check-only"
                "--print"
              ] generatedLinks
            })" || code=$?
          fi
          if [ "$code" -gt 1 ]; then
            text="coldlogic: this Claude Code session couldn't check its generated files (the check exited $code). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell."
            notice generated-files-check "$text"
            exit 0
          fi
          forget generated-files-check
          if [ "$code" = 1 ] || [ -z "$out" ]; then
            forget generated-files
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
            text="coldlogic: this Claude Code session can't refresh these generated files ($what). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell. Then restart every Claude Code session open in this checkout, this one included, before any of them runs another command, since a running session can undo the refresh at its next tool call. If a terminal shell doesn't fix them, its evaluation may be stale: run devenv shell --refresh-eval-cache there."
            notice generated-files "$text"
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
          ${noticeFunctions}
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
            notice freshness "coldlogic-devenv is behind (locked ''${locked:0:7}, latest ''${latest:0:7}); run: devenv update coldlogic-devenv"
          elif [ -n "$latest" ]; then
            forget freshness
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
          if ${inSession}; then exit 0; fi
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
      # warns instead, once per session (packages/session-shell.sh). A
      # session that reads its skills from another checkout (own-checkout)
      # generates nothing here and says nothing. Never fails the shell.
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
          ${noticeFunctions}
          # Only 10, which only a session gets, skips: a terminal shell, the
          # session's own checkout and a helper that fails any other way
          # run as before.
          own=0
          ${sessionShell} own-checkout || own=$?
          [ "$own" != 10 ] || exit 0
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
            forget openspec-files
            exit 0
          fi
          if out=$(DO_NOT_TRACK=1 OPENSPEC_TELEMETRY=0 openspec init --tools claude --no-animation </dev/null 2>&1); then
            mkdir -p "$(dirname "$stamp")" 2>/dev/null && echo "$want" >"$stamp" 2>/dev/null || true
            forget openspec-files
          elif [ -n "$present" ]; then
            notice openspec-files "coldlogic: OpenSpec's Claude Code skills may be out of date; enter the shell from a terminal, outside a Claude Code session, to regenerate them"
          else
            detail=$(printf '%s\n' "$out" | grep -m1 '^Failed' || true)
            notice openspec-files "coldlogic: couldn't generate OpenSpec's Claude Code skills; enter the shell from a terminal, outside a Claude Code session''${detail:+$'\n'$detail}"
          fi
          exit 0
        '';
        before = [ "devenv:enterShell" ];
      };
    };
}
