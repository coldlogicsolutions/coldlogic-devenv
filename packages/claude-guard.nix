# `coldlogic-claude-guard`, the PreToolUse hook in claude-guard.py. Its test
# cases run at build time, so a guard that fails them never reaches a shell.
{ pkgs }:
pkgs.runCommand "coldlogic-claude-guard" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cp ${./claude-guard.py} claude-guard.py
  cp ${./claude-guard-test.py} claude-guard-test.py
  python3 -I claude-guard-test.py
  mkdir -p $out/bin
  { echo "#!${pkgs.python3}/bin/python3 -I"; cat claude-guard.py; } > $out/bin/coldlogic-claude-guard
  chmod +x $out/bin/coldlogic-claude-guard
''
