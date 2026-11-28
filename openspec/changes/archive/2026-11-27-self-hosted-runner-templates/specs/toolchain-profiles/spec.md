# Spec Delta

## MODIFIED Requirements

### Requirement: Profiles layer build, ci and developer
Each profile SHALL define `build`, plus `ci` and `developer`, which both extend `build`. A project's own `devenv.nix` SHALL be able to add to any of the three. The module SHALL add its tooling and Claude Code settings to `developer` only, so `build` and `ci` shells get none of them.

Tested by: the `cache` job in `dispatch-updates.yaml` (each fixture's shells on x86_64 Linux, aarch64 Linux and macOS); the gate, on its own platform.

#### Scenario: Fixture shells build
- **WHEN** a commit lands on main
- **THEN** the `ci` and `developer` shells of `tests/fixtures/rust-lib` and `tests/fixtures/rust-worker` build on all three platforms, or the dispatch to projects is held back
