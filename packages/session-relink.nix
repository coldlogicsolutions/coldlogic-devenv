# `coldlogic-session-relink`, the status check in session-relink.sh that
# devenv:files and devenv:files:cleanup run in a Claude Code session. Its test
# cases (session-relink-test.sh) run against the raw script at build time, as
# claude-guard's do, so a relink that fails them never reaches a shell.
{ pkgs }:
let
  tested =
    pkgs.runCommand "coldlogic-session-relink-test"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          findutils
          jq
        ];
      }
      ''
        bash ${./session-relink-test.sh} ${./session-relink.sh}
        touch $out
      '';
in
pkgs.writeShellApplication {
  name = "coldlogic-session-relink";
  runtimeInputs = with pkgs; [
    coreutils
    findutils
    jq
  ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + builtins.readFile ./session-relink.sh;
}
