# `gh-app` (and the `gh-app-token` it calls), replacing the identical
# `scripts/gh-app` and `scripts/gh-app-token.sh` copies the projects carried.
# The key path comes from GH_APP_KEY, default ~/.config/github/coldlogic-ai.pem.
# gh-app's test cases (gh-app-test.sh) run against the raw script at build
# time, as prune-worktrees' do, so a `gh-app` that fails them, one that would
# approve or merge a PR it should refuse, never reaches a shell.
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
  tested =
    pkgs.runCommand "coldlogic-gh-app-test"
      {
        # No gh or gh-app-token: the test puts stand-ins for them on PATH,
        # and needs no key, network or credentials. jq runs the script's
        # own `--jq` filters for the gh stand-in.
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          jq
        ];
      }
      ''
        bash ${./gh-app-test.sh} ${./gh-app.sh}
        touch $out
      '';
in
pkgs.writeShellApplication {
  name = "gh-app";
  runtimeInputs = [
    gh-app-token
    pkgs.gh
  ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + builtins.readFile ./gh-app.sh;
}
