# toolchain-profiles Specification

## Purpose
The language profiles a project imports next to the module. Each supplies a toolchain in three devenv profiles: `build` for building, a slim `ci` for the gate, and a full `developer` for people and sessions.

## Requirements

### Requirement: Profiles layer build, ci and developer
Each profile SHALL define `build`, plus `ci` and `developer`, which both extend `build`. A project's own `devenv.nix` SHALL be able to add to any of the three. The module SHALL add its tooling and Claude Code settings to `developer` only, so `build` and `ci` shells get none of them.

Tested by: the `cache` job in `dispatch-updates.yaml` (each fixture's shells on x86_64 Linux, aarch64 Linux and macOS); the gate, on its own platform.

#### Scenario: Fixture shells build
- **WHEN** a commit lands on main
- **THEN** the `ci` and `developer` shells of `tests/fixtures/rust-lib` and `tests/fixtures/rust-worker` build on all three platforms, or the dispatch to projects is held back

### Requirement: rust-lib provides a pinned Rust for host and wasm32
The `rust-lib` `build` profile SHALL provide stable Rust at the module's supported version (1.99.1, which a project can override) with the `wasm32-unknown-unknown` target, plus Node.

Tested by: the fixture builds above.

#### Scenario: Project overrides the version
- **WHEN** a project sets `languages.rust.version`
- **THEN** its shells use that version instead of the module's

### Requirement: The ci profile stays slim
The `rust-lib` `ci` profile SHALL add only `clippy` and `rustfmt` to the build components. It SHALL leave out rust-analyzer, the clang linker and devenv's C toolchain, and provide `gcc` for `cc`.

Tested by: the fixture builds above (they build, but nothing checks what is left out).

#### Scenario: No editor tooling in CI
- **WHEN** a CI job enters the `ci` shell of a rust-lib project
- **THEN** `rust-analyzer` isn't on its PATH

### Requirement: The developer profile adds editor tooling, hooks and rules
The `rust-lib` `developer` profile SHALL add rust-analyzer, the Rust docs and source, and check-only `rustfmt` and `clippy` pre-commit hooks. It SHALL allow `cargo check`, `build`, `test`, `clippy`, `fmt`, `tree` and `metadata`, which run build scripts and tests and, for `fmt`, rewrite sources. It SHALL add cargo's caches, crates.io, static.rust-lang.org and the Rust documentation hosts to the sandbox.

Tested by: none beyond the fixture builds.

#### Scenario: rustfmt hook doesn't rewrite
- **WHEN** a developer commits Rust that `rustfmt` would change
- **THEN** the hook fails the commit without changing the files

#### Scenario: cargo test behind the wrapper
- **WHEN** a session runs `devenv shell --quiet -- cargo test --workspace`
- **THEN** the guard allows it with no prompt

### Requirement: rust-worker extends rust-lib for Cloudflare Workers
The `rust-worker` profile SHALL import `rust-lib`. It SHALL add the module's pinned `worker-build`, at the line the project selects, and `wasm-pack` to `build`, and `topcoat` (built with the profile's Rust) to `ci` and `developer`. In `developer` it SHALL enable the `cloudflare` plugin, allow `wrangler dev`, and add wrangler's and the build tools' state directories and the Cloudflare hosts to the sandbox.

Tested by: the `rust-worker` fixture build.

#### Scenario: topcoat fmt in the gate
- **WHEN** a rust-worker project's CI enters the `ci` shell
- **THEN** `topcoat` is on its PATH

#### Scenario: Deploy is still denied
- **WHEN** a session in a rust-worker project runs `wrangler deploy`
- **THEN** the guard denies it, although `wrangler dev` is allowed

#### Scenario: worker-build in the build shell
- **WHEN** a rust-worker project that sets nothing enters its `build`, `ci` or `developer` shell
- **THEN** `worker-build --version` prints the pinned patch of the newest line the module carries (0.9.0)

### Requirement: A project selects the worker-build line
The `rust-worker` profile SHALL offer the option `coldlogic.workerBuild.line`, whose values are the worker-build minor lines the module carries (`"0.9"` for now) and whose default is the newest. Each line SHALL be pinned in the module to one patch release, so that a project's nixpkgs, whatever its revision, does not change the `worker-build` it gets.

Tested by: the `rust-worker` fixture build, which builds the default line and checks that the binary reports its pinned version.

#### Scenario: Project names a line
- **WHEN** a rust-worker project sets `coldlogic.workerBuild.line = "0.9";`
- **THEN** its shells have worker-build 0.9.0

#### Scenario: Line the module doesn't carry
- **WHEN** a rust-worker project sets `coldlogic.workerBuild.line` to a value the module doesn't carry, such as `"0.8"`
- **THEN** its shell fails to evaluate, with an error that lists the lines it does carry

#### Scenario: nixpkgs moves on
- **WHEN** a rust-worker project's nixpkgs is updated to a revision whose `worker-build` is a different version
- **THEN** its shells keep the module's pinned worker-build for the selected line
