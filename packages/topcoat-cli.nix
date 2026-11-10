# The Topcoat CLI, for `topcoat fmt`, which formats inside Topcoat's macros
# (`view!`, `#[page]`, `href!`...) where rustfmt doesn't reach. nixpkgs lags
# behind, and the formatter has to read the macro syntax of the Topcoat
# version the projects pin, so the version is set here and moves with that
# pin: bump `version`, then both hashes (build once with `lib.fakeHash` to get
# each). A release that needs a newer Rust than the rust-lib profile's
# `languages.rust.version` moves that too.
#
# It builds with the project's Rust (`languages.rust.channel` and `.version`)
# rather than nixpkgs' rustc, which is whatever the project's nixpkgs has and
# can be older than Topcoat's `rust-version` (#31). The minimal profile of
# that release, so the ci and developer shells, whose components differ,
# share one build.
{ pkgs, config }:
let
  rust = config.languages.rust;

  rust-overlay = config.lib.getInput {
    name = "rust-overlay";
    url = "github:oxalica/rust-overlay";
    attribute = "the topcoat-cli package";
    follows = [ "nixpkgs" ];
  };
  toolchain =
    (rust-overlay.lib.mkRustBin { } pkgs.buildPackages).${rust.channel}.${rust.version}.minimal;
  # A project that chose nixpkgs' Rust builds with it.
  rustPlatform =
    if rust.channel == "nixpkgs" then
      pkgs.rustPlatform
    else
      pkgs.makeRustPlatform {
        cargo = toolchain;
        rustc = toolchain;
      };
in
rustPlatform.buildRustPackage (finalAttrs: {
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
  # Checks the binary it installed reports this version.
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "CLI for Topcoat, a Rust web framework for server-rendered apps";
    homepage = "https://github.com/tokio-rs/topcoat";
    license = pkgs.lib.licenses.mit;
    mainProgram = "topcoat";
  };
})
