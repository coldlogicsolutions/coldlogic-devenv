# `gh-app` (and the `gh-app-token` it calls), replacing the identical
# `scripts/gh-app` and `scripts/gh-app-token.sh` copies the projects carried.
# The key path comes from GH_APP_KEY, default ~/.config/github/coldlogic-ai.pem.
{ pkgs }:
let
  gh-app-token = pkgs.writeShellApplication {
    name = "gh-app-token";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      openssl
    ];
    # The script reads its own defaults; shellcheck runs at build time.
    text = builtins.readFile ./gh-app-token.sh;
  };
in
pkgs.writeShellApplication {
  name = "gh-app";
  runtimeInputs = [
    gh-app-token
    pkgs.gh
  ];
  text = builtins.readFile ./gh-app.sh;
}
