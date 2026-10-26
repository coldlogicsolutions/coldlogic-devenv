# A Rust crate built for the host and wasm32 (neonjazz-topcoat). rust-worker
# builds on it. Node is for scripts/check-package.sh, which builds a consumer
# of the packaged crate.
{ pkgs, ... }:
{
  profiles = {
    build.module = {
      packages = [ pkgs.nodejs ];

      languages.rust = {
        enable = true;
        channel = "stable";
        components = [
          "rustc"
          "cargo"
          "rust-std"
        ];
        targets = [ "wasm32-unknown-unknown" ];
      };
    };

    # What scripts/check.sh needs on top of `build`, and nothing else. A CI
    # image ships this closure and every job pulls it, so an editor server, a
    # copy of the Rust docs and a pre-commit framework are paid for on every
    # run. `developer` keeps all of that for humans.
    ci = {
      extends = [ "build" ];
      module = {
        languages.rust = {
          components = [
            "rustc"
            "cargo"
            "rust-std"
            "clippy"
            "rustfmt"
          ];

          # Clang plus LLVM's bintools is ~1.3 GB of the closure, and it is
          # only the linker driver for the host target — wasm32 links with
          # rustc's own rust-lld. Without it rustc falls back to `cc`.
          clangLinker.enable = false;

          # rust-analyzer, which no job starts.
          lsp.enable = false;
        };

        # devenv's Rust module turns this on to get `cc`. The rest of what it
        # brings — clang-tools, ccls, gdb, valgrind and their Python and Perl —
        # is another gigabyte that nothing in scripts/check.sh runs. Until a
        # crate in the graph compiles C, gcc's `cc` for the host test binary
        # is the whole requirement. A project that compiles C overrides this.
        languages.c.enable = false;
        packages = [ pkgs.gcc ];
      };
    };

    developer = {
      extends = [ "build" ];
      module = {
        languages.rust.components = [
          "rustc"
          "cargo"
          "rust-std"
          "clippy"
          "rustfmt"
          "rust-analyzer"
          "rust-docs"
          "rust-src"
        ];

        git-hooks.hooks = {
          rustfmt = {
            enable = true;
            # Check-only: a hook that rewrites files sweeps unrelated fmt
            # drift into whatever is being committed. `cargo fmt` stays
            # available to run by hand.
            settings.check = true;
          };
          clippy.enable = true;
        };
      };
    };
  };
}
