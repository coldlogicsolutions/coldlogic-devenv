# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
