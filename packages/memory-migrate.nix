# `coldlogic-memory-migrate` (memory-migrate.py): the one-off import of
# Claude Code's auto memory files into the shared memory store, run from a
# terminal. Its test cases (memory-migrate-test.py, with fakes for HTTP) run
# at build time, so a script that fails them never reaches a shell.
{ pkgs }:
pkgs.runCommand "coldlogic-memory-migrate" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cp ${./memory-migrate.py} memory-migrate.py
  cp ${./memory-migrate-test.py} memory-migrate-test.py
  python3 -I memory-migrate-test.py
  mkdir -p $out/bin
  { echo "#!${pkgs.python3}/bin/python3 -I"; cat memory-migrate.py; } > $out/bin/coldlogic-memory-migrate
  chmod +x $out/bin/coldlogic-memory-migrate
''
