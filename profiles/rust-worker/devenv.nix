# A Rust Cloudflare Worker built with workers-rs (topcoat-workers,
# derekjw.com, coldlogic).
{ pkgs, ... }:
let
  # `topcoat fmt`, for the gate: at the Topcoat version the projects pin
  # (packages/topcoat-cli.nix), not nixpkgs'.
  topcoat-cli = import ../../packages/topcoat-cli.nix { inherit pkgs; };
in
{
  imports = [ ../rust-lib/devenv.nix ];

  profiles = {
    build.module.packages = with pkgs; [
      worker-build
      wasm-pack
    ];

    # The gate's, not the build's.
    ci.module.packages = [ topcoat-cli ];

    developer.module =
      { config, ... }:
      {
        packages = [ topcoat-cli ];

        files."${config.claude.code.settingsPath}".json = {
          extraKnownMarketplaces.cloudflare.source = {
            source = "github";
            repo = "cloudflare/skills";
          };
          enabledPlugins."cloudflare@cloudflare" = true;
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
