# A Rust Cloudflare Worker built with workers-rs (topcoat-workers,
# derekjw.com, coldlogic).
{ pkgs, lib, ... }:
let
  # worker-build, one pinned patch per minor line (packages/worker-build.nix).
  workerBuilds = import ../../packages/worker-build.nix { inherit pkgs; };

  # `topcoat fmt`, for the gate: at the Topcoat version the projects pin
  # (packages/topcoat-cli.nix), not nixpkgs'. Built from the profile's own
  # `config`: the file's is the evaluation without the profiles, so it never
  # sees their `languages.rust`.
  topcoat-cli = config: import ../../packages/topcoat-cli.nix { inherit pkgs config; };
in
{
  imports = [ ../rust-lib/devenv.nix ];

  # Under `coldlogic`, the module's namespace, which keeps it clear of devenv's
  # own options. It's a `line` because the patch is the module's choice.
  options.coldlogic.workerBuild.line = lib.mkOption {
    type = lib.types.enum (builtins.attrNames workerBuilds);
    default = lib.last (lib.sort lib.versionOlder (builtins.attrNames workerBuilds));
    description = ''
      The worker-build minor line, which must match the minor version of the
      project's `worker` crate. The default is the newest line the module
      carries.
    '';
  };

  config.profiles = {
    # Reads the profile's own `config`, so a line the project sets is seen.
    build.module =
      { config, ... }:
      {
        packages = [
          workerBuilds.${config.coldlogic.workerBuild.line}
          pkgs.wasm-pack
        ];
      };

    # The gate's, not the build's.
    ci.module =
      { config, ... }:
      {
        packages = [ (topcoat-cli config) ];
      };

    developer.module =
      { config, ... }:
      {
        packages = [ (topcoat-cli config) ];

        files."${config.claude.code.settingsPath}".json = {
          extraKnownMarketplaces.cloudflare.source = {
            source = "github";
            repo = "cloudflare/skills";
          };
          enabledPlugins."cloudflare@cloudflare" = true;

          # Added to rust-lib's and the shared module's sandbox lists.
          sandbox = {
            # wrangler's state and the Worker build tools' downloads, on
            # macOS and Linux.
            filesystem.allowWrite = [
              "~/Library/Preferences/.wrangler"
              "~/.config/.wrangler"
              "~/Library/Caches/worker-build"
              "~/.cache/worker-build"
              "~/Library/Caches/.wasm-pack"
              "~/.cache/.wasm-pack"
            ];
            network.allowedDomains = [
              "workers.cloudflare.com"
              "developers.cloudflare.com"
            ];
          };
        };

        # The guard hook allows no package runner, so `npx wrangler dev` is
        # matched by Claude Code's own rules, and only when run directly:
        # behind the devenv wrapper it prompts.
        claude.code.permissions.rules.Bash.allow = [
          "wrangler dev *"
          "npx wrangler dev *"
        ];
      };
  };
}
