# `coldlogic-memory-recall` (memory-recall.sh): the SessionStart hook that
# prints a session's shared memories and the save text into its context.
# devenv.nix runs it when COLDLOGIC_MEMORY_URL is set, and puts it on PATH
# either way, so it can be run by hand and its tests always build. Its test
# cases (memory-recall-test.sh) run against the raw script at build time,
# with a stub for curl, so a script that fails them never reaches a shell.
{ pkgs }:
let
  caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  # Claude Code may start the hook with no CA bundle in its environment, and
  # Nix's curl then can't verify an https store (a tailnet's `*.ts.net`
  # certificate, say) and the hook reports it unreachable. A bundle the
  # environment already names (unset or empty counts as none) is kept, so a
  # private CA keeps working.
  caDefault = ''
    : "''${SSL_CERT_FILE:=${caBundle}}"
    export SSL_CERT_FILE
  '';
  tested =
    pkgs.runCommand "coldlogic-memory-recall-test"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          git
          jq
        ];
      }
      ''
        bash ${./memory-recall-test.sh} ${./memory-recall.sh}
        # The CA default: set when unset or empty, kept when set, and the
        # bundle it names exists. The builder sets SSL_CERT_FILE itself, so
        # each case sets or unsets it explicitly.
        cat > ca.sh <<'EOF'
        ${caDefault}
        printf '%s\n' "$SSL_CERT_FILE"
        EOF
        got=$(env -u SSL_CERT_FILE bash -u ca.sh)
        [ "$got" = ${lib.escapeShellArg caBundle} ] || { echo "CA default unset: got '$got'" >&2; exit 1; }
        got=$(SSL_CERT_FILE= bash -u ca.sh)
        [ "$got" = ${lib.escapeShellArg caBundle} ] || { echo "CA default empty: got '$got'" >&2; exit 1; }
        got=$(SSL_CERT_FILE=/etc/private-ca.pem bash -u ca.sh)
        [ "$got" = /etc/private-ca.pem ] || { echo "CA default overrode a set value: got '$got'" >&2; exit 1; }
        [ -s ${caBundle} ] || { echo "no CA bundle at ${caBundle}" >&2; exit 1; }
        echo "CA default: 4 passed"
        touch $out
      '';
  inherit (pkgs) lib;
in
pkgs.writeShellApplication {
  name = "coldlogic-memory-recall";
  runtimeInputs = with pkgs; [
    coreutils
    curl
    git
    jq
  ];
  # The reference makes the build depend on the tests passing.
  text = ''
    # Tested by ${tested}
  ''
  + caDefault
  + builtins.readFile ./memory-recall.sh;
}
