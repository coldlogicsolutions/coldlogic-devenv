# `claude` (claude-wrapper.sh), which the developer shell puts on PATH ahead
# of the real Claude Code: it refreshes the checkout's generated files before
# a session starts, then starts the real one with the session's marker. Its
# test cases (claude-wrapper-test.sh) run against the raw script at build
# time, as session-relink's do, so a wrapper that fails them never reaches a
# shell.
#
# No runtimeInputs: writeShellApplication exports them onto PATH, and every
# session the wrapper starts would inherit that PATH. git, mktemp and rm are
# named by their store paths instead. No nix devenv either: the refresh must use the
# developer's own, the one that made the shell, with its evaluation cache.
#
# settingsPath: the module's `claude.code.settingsPath`, relative to the
# checkout, which the wrapper checks after a failed refresh.
{
  pkgs,
  settingsPath ? ".claude/settings.json",
}:
let
  tested =
    pkgs.runCommand "coldlogic-claude-wrapper-test"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
        ];
      }
      ''
        bash ${./claude-wrapper-test.sh} ${./claude-wrapper.sh}
        touch $out
      '';
  app = pkgs.writeShellApplication {
    name = "coldlogic-claude-wrapper";
    runtimeInputs = [ ];
    # The reference makes the build depend on the tests passing.
    text = ''
      # Tested by ${tested}
      git_bin=${pkgs.git}/bin/git
      mktemp_bin=${pkgs.coreutils}/bin/mktemp
      rm_bin=${pkgs.coreutils}/bin/rm
      settings_path=${pkgs.lib.escapeShellArg settingsPath}
    ''
    + builtins.readFile ./claude-wrapper.sh;
  };
in
# One name on PATH: `claude`.
pkgs.runCommand "coldlogic-claude" { } ''
  mkdir -p $out/bin
  ln -s ${app}/bin/coldlogic-claude-wrapper $out/bin/claude
''
