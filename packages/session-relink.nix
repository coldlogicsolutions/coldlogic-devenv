# `coldlogic-session-relink` (session-relink.sh), run in a Claude Code
# session by the coldlogic:session-files task, which links the generated
# files, and by the stale notice, which compares them. Its test cases
# (session-relink-test.sh) run against the raw script at build time, as
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
  ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + builtins.readFile ./session-relink.sh;
}
