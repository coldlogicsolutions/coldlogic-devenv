# The Topcoat CLI, for `topcoat fmt`, which formats inside Topcoat's macros
# (`view!`, `#[page]`, `href!`...) where rustfmt doesn't reach. nixpkgs lags
# behind, and the formatter has to read the macro syntax of the Topcoat
# version the projects pin, so the version is set here and moves with that
# pin: bump `version`, then both hashes (build once with `lib.fakeHash` to get
# each).
{ pkgs }:
pkgs.rustPlatform.buildRustPackage (finalAttrs: {
  pname = "topcoat-cli";
  version = "0.12.0";

  src = pkgs.fetchFromGitHub {
    owner = "tokio-rs";
    repo = "topcoat";
    tag = "v${finalAttrs.version}";
    hash = "sha256-1hdoCBRelS6FZV5qv/zYV64MpovCeAK1G/XezVFFfqs=";
  };

  cargoHash = "sha256-Dew2dgqeAOmnf0TkwRMMrdWuSS8o2KU05bb9O07C45E=";

  cargoBuildFlags = [
    "-p"
    "topcoat-cli"
  ];
  # Its tests run Topcoat projects end to end; what's needed here is the
  # binary.
  doCheck = false;

  meta = {
    description = "CLI for Topcoat, a Rust web framework for server-rendered apps";
    homepage = "https://github.com/tokio-rs/topcoat";
    license = pkgs.lib.licenses.mit;
    mainProgram = "topcoat";
  };
})
