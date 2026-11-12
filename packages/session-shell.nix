# `coldlogic-session-shell` (session-shell.sh): what a `devenv shell` does
# differently inside a Claude Code session. devenv.nix runs it from the
# status of devenv:git-hooks:install and the coldlogic:hooks-check task
# (whether the hook install is skipped, and the missing-hook notice), and
# from coldlogic:generated-files-stale, coldlogic:openspec-files and
# coldlogic:setup-freshness (whether this checkout is the one the session
# reads its Claude Code files from, and each notice once per session). Its
# test cases (session-shell-test.sh) run against the raw script at build
# time, so a script that fails them never reaches a shell.
{ pkgs }:
let
  tested =
    pkgs.runCommand "coldlogic-session-shell-test"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          findutils
          git
        ];
      }
      ''
        bash ${./session-shell-test.sh} ${./session-shell.sh}
        touch $out
      '';
in
pkgs.writeShellApplication {
  name = "coldlogic-session-shell";
  runtimeInputs = with pkgs; [
    coreutils
    git
  ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + builtins.readFile ./session-shell.sh;
}
