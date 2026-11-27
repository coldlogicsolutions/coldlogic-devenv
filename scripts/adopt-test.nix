# Runs scripts/adopt.sh in a fresh git repository and checks that every .nix
# file it creates passes `nixfmt --check` (the module's git hook runs nixfmt).
# Build it with
#
#   nix build --impure --no-link -L -f scripts/adopt-test.nix
#
# scripts/check.sh does. Its tools come from the nixpkgs revision devenv.lock
# pins, the same as scripts/check-tools.nix.
let
  pkgs = import ./pinned-nixpkgs.nix;
in
pkgs.runCommand "coldlogic-adopt-test"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      git
      yq-go
      nixfmt
    ];
  }
  ''
    export HOME=$TMPDIR/home
    mkdir -p "$HOME" src/scripts src/templates project
    cp ${./adopt.sh} src/scripts/adopt.sh
    cp ${../templates/update-coldlogic-devenv.yaml} src/templates/update-coldlogic-devenv.yaml
    cd project
    git init -q
    bash ../src/scripts/adopt.sh --no-update
    test -f devenv.nix
    find . -name .git -prune -o -name '*.nix' -exec nixfmt --check {} +
    touch $out
  ''
