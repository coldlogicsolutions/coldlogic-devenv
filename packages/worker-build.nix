# worker-build, which builds a Cloudflare Worker written with workers-rs. It
# only builds a `worker` crate on its own minor line, so the module pins each
# line it carries rather than taking nixpkgs' (#129). A project picks one with
# `coldlogic.workerBuild.line` and gets the newest by default.
#
# To bump a line, change its `version` and set both hashes to
# `pkgs.lib.fakeHash`, build, and paste the hash each failure reports. To add
# a line, add an entry the same way.
#
# It builds with nixpkgs' `rustPlatform`, because 0.9.0's `rust-version`
# (1.91) is below nixpkgs' rustc. A line that needs a newer Rust than nixpkgs
# has can build with the project's Rust, as packages/topcoat-cli.nix does.
{ pkgs }:
let
  lines = {
    "0.9" = {
      version = "0.9.0";
      hash = "sha256-zmeQp7db2rwfECp9p5NthKvzsZFnQPFO+eueIhFsIwE=";
      cargoHash = "sha256-EbRwSrxRys2EcDfB88apmH5Rm0NUWLKtmGPS77fAhpI=";
    };
  };
in
builtins.mapAttrs (
  _line: pin:
  pkgs.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "worker-build";
    inherit (pin) version cargoHash;

    src = pkgs.fetchFromGitHub {
      owner = "cloudflare";
      repo = "workers-rs";
      tag = "v${finalAttrs.version}";
      inherit (pin) hash;
      fetchSubmodules = true;
    };

    buildAndTestSubdir = "worker-build";
    buildInputs = [
      pkgs.openssl
      pkgs.zstd
    ];
    nativeBuildInputs = [ pkgs.pkg-config ];

    # The build writes under $HOME. Nix points it at /homeless-shelter, which a
    # sandboxed build can't create; an unsandboxed one as root (the CI images'
    # single-user Nix) does, and Nix then refuses every later build in that
    # store while the directory exists.
    preConfigure = ''
      export HOME="$(mktemp -d)"
    '';
    # Only the binary is needed.
    doCheck = false;
    # Checks the binary it installed reports this version.
    nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
    doInstallCheck = true;

    meta = {
      description = "Custom build command for Cloudflare Workers written with workers-rs";
      homepage = "https://github.com/cloudflare/workers-rs";
      license = with pkgs.lib.licenses; [
        asl20
        mit
      ];
      mainProgram = "worker-build";
    };
  })
) lines
