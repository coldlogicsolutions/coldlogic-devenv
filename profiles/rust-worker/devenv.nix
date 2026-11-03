# A Rust Cloudflare Worker built with workers-rs (topcoat-workers,
# derekjw.com, coldlogic).
{ pkgs, ... }:
{
  imports = [ ../rust-lib/devenv.nix ];

  profiles = {
    build.module.packages = with pkgs; [
      worker-build
      wasm-pack
    ];

    developer.module =
      { config, ... }:
      {
        files."${config.claude.code.settingsPath}".json = {
          extraKnownMarketplaces.cloudflare.source = {
            source = "github";
            repo = "cloudflare/skills";
          };
          enabledPlugins."cloudflare@cloudflare" = true;
        };

        # The guard hook allows no package runner, so `npx wrangler dev` is
        # matched by Claude Code's own rules.
        claude.code.permissions.rules.Bash.allow = [
          "wrangler dev *"
          "npx wrangler dev *"
        ];
      };
  };
}
