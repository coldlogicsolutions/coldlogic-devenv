# The tools scripts/check.sh runs, from the nixpkgs revision devenv.lock pins
# (the one the shell uses), so a session, a terminal and CI get the same
# versions. Build with:
#   nix build --impure --no-link --print-out-paths -f scripts/check-tools.nix
let
  pkgs = import ./pinned-nixpkgs.nix;
in
pkgs.buildEnv {
  name = "coldlogic-check-tools";
  paths = [
    pkgs.python3
    pkgs.nixfmt
    pkgs.shellcheck
    pkgs.openspec
  ];
}
