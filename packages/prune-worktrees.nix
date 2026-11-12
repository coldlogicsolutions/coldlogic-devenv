# `coldlogic-prune-worktrees`, prune-worktrees.sh: removes a repository's
# merged, idle worktrees and branches, from the developer profile's
# SessionStart and Stop hooks and its terminal shell task (#73). Its test
# cases (prune-worktrees-test.sh) run against the raw script at build time,
# as session-relink's do, so a prune that fails them never reaches a shell.
# `gh-app` is the module's own, which the script uses to find squash merges.
{ pkgs, gh-app }:
let
  # macOS has lsof in /usr/sbin, which the script appends to PATH; nixpkgs'
  # is for Linux.
  # Likewise ps, for the lock owner's start time: /bin/ps on macOS.
  linuxTools = pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.lsof
    pkgs.procps
  ];
  tested =
    pkgs.runCommand "coldlogic-prune-worktrees-test"
      {
        # No gh-app, lsof or ps: the test puts stubs of them on PATH.
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          findutils
          git
          gnugrep
          jq
        ];
      }
      ''
        bash ${./prune-worktrees-test.sh} ${./prune-worktrees.sh}
        touch $out
      '';
in
pkgs.writeShellApplication {
  name = "coldlogic-prune-worktrees";
  runtimeInputs =
    (with pkgs; [
      coreutils
      findutils
      git
      jq
    ])
    ++ linuxTools
    ++ [ gh-app ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + builtins.readFile ./prune-worktrees.sh;
}
