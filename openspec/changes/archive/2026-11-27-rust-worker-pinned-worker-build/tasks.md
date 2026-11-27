# Tasks

Run every command through `devenv shell --quiet -- <cmd>`, one per Bash call, unpiped. Edit files with the Edit and Write tools only. See design.md for the reasons behind each choice.

## 1. The worker-build package

- [x] 1.1 Create `packages/worker-build.nix`. It takes `{ pkgs }` and returns an attribute set with one entry per minor line, for now only `"0.9"`. Build each entry with `pkgs.rustPlatform.buildRustPackage (finalAttrs: { ... })` from a small table such as `lines = { "0.9" = { version = "0.9.0"; hash = pkgs.lib.fakeHash; cargoHash = pkgs.lib.fakeHash; }; };`, mapped with `builtins.mapAttrs`. Each derivation has:
  - `pname = "worker-build"`, `version` from the table;
  - `src = pkgs.fetchFromGitHub { owner = "cloudflare"; repo = "workers-rs"; tag = "v${finalAttrs.version}"; hash = ...; fetchSubmodules = true; }`;
  - `cargoHash` from the table, `buildAndTestSubdir = "worker-build"`;
  - `buildInputs = [ pkgs.openssl pkgs.zstd ]`, `nativeBuildInputs = [ pkgs.pkg-config ]`;
  - `preConfigure` exporting `HOME="$(mktemp -d)"`, with the same comment as `packages/topcoat-cli.nix` (#127);
  - `doCheck = false` with a one-line comment (only the binary is needed);
  - `nativeInstallCheckInputs = [ pkgs.versionCheckHook ]` and `doInstallCheck = true`, with topcoat-cli's comment;
  - `meta = { description = "Custom build command for Cloudflare Workers written with workers-rs"; homepage = "https://github.com/cloudflare/workers-rs"; license = with pkgs.lib.licenses; [ asl20 mit ]; mainProgram = "worker-build"; }` (`mainProgram` matters: the package also installs `worker-codegen`, and versionCheckHook runs `mainProgram`).

  Start the file with a comment header in the style of topcoat-cli's: worker-build only builds a `worker` crate on its own minor line, so the module pins each line it carries rather than taking nixpkgs' (#129); a project picks one with `coldlogic.workerBuild.line` and gets the newest by default; to bump a line, change its `version` and set both hashes to `pkgs.lib.fakeHash`, build, and paste the hash each failure reports; to add a line, add an entry the same way; it builds with nixpkgs' `rustPlatform` because 0.9.0's `rust-version` (1.91) is below nixpkgs' rustc, and a line that needs a newer Rust than nixpkgs has can build with the project's Rust as `packages/topcoat-cli.nix` does. Verify with `devenv shell --quiet -- nixfmt --check packages/worker-build.nix`.

## 2. The option and the profile

- [x] 2.1 In `profiles/rust-worker/devenv.nix`, change the arguments to `{ pkgs, lib, ... }:`, add `workerBuilds = import ../../packages/worker-build.nix { inherit pkgs; };` to the `let`, and restructure the body as `{ imports = [ ../rust-lib/devenv.nix ]; options.coldlogic.workerBuild.line = ...; config.profiles = { ... }; }` (a module that declares `options` must put its settings under `config`). Move the existing `profiles` attribute set under `config` unchanged except for 2.2. Verify `devenv shell --quiet -- nixfmt --check profiles/rust-worker/devenv.nix` passes.
- [x] 2.2 Declare the option with `lib.mkOption { type = lib.types.enum (builtins.attrNames workerBuilds); default = <newest>; description = ...; }`, where `<newest>` is `lib.last (lib.sort lib.versionOlder (builtins.attrNames workerBuilds))`. The description says: the worker-build minor line, which must match the project's `worker` crate's minor version; the default is the newest line the module carries. Add a comment above it saying why it is under `coldlogic` (the module's namespace, clear of devenv's options) and why it's `line` (the patch is the module's choice).
- [x] 2.3 Replace `build.module.packages = with pkgs; [ worker-build wasm-pack ];` with a function module `build.module = { config, ... }: { packages = [ workerBuilds.${config.coldlogic.workerBuild.line} pkgs.wasm-pack ]; };`, with a comment that it reads the profile's own `config` so a line the project sets is seen. Verify `devenv shell --quiet -- nixfmt --check profiles/rust-worker/devenv.nix` passes.

## 3. Hashes and the build

- [x] 3.1 Run the gate, `devenv shell --quiet -- scripts/check.sh`. With the fake hashes, the `build: rust-worker (ci)` step fails with a hash mismatch for the source: copy the `got:` hash into the `"0.9"` entry's `hash` in `packages/worker-build.nix`. Run the gate again and copy the next `got:` hash into `cargoHash`. Verify `grep -n fakeHash packages/worker-build.nix` finds nothing but the header comment.
- [x] 3.2 Run the gate again and verify every step passes, the `build: rust-worker (ci)` and `build: rust-worker (developer)` steps included (they run versionCheckHook, which checks the binary reports 0.9.0). If the build itself fails (not a hash mismatch), stop and report the error: don't change the Rust platform or the inputs to get past it.
- [x] 3.3 Check that an unknown line fails: add `coldlogic.workerBuild.line = "0.8";` to the body of `tests/fixtures/rust-worker/devenv.nix` (`{ ... }: { coldlogic.workerBuild.line = "0.8"; }`), run the gate, and verify the `build: rust-worker` steps fail with an error naming `coldlogic.workerBuild.line` and listing `"0.9"`. Then restore the file exactly (`{ ... }:` / `{ }` with its comment) and verify `git diff --exit-code tests/fixtures/rust-worker/devenv.nix` reports no change.

## 4. Docs

- [x] 4.1 In `README.md`, the `profiles/rust-worker` row of the "What's here" table: replace `worker-build` with `worker-build` pinned by the module at the line `coldlogic.workerBuild.line` selects (the newest it carries by default, 0.9; it must match the project's `worker` crate's minor version). Add a row after `packages/topcoat-cli.nix`: `packages/worker-build.nix` | worker-build, one pinned patch per minor line the module carries (0.9.0 for 0.9), built with nixpkgs' Rust; bump a line or add one there. Verify by reading both rows back.

## 5. Gate

- [x] 5.1 Run `devenv shell --quiet -- openspec validate rust-worker-pinned-worker-build --strict` and verify it reports the change valid.
- [x] 5.2 Run `devenv shell --quiet -- scripts/check.sh` and verify the summary shows every check passed.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges.
- The Worker build check in the gate or cache job is a separate follow-up issue.
