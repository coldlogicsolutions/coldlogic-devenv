# Spec Delta

## MODIFIED Requirements

### Requirement: Profiles layer build, ci and developer
Each profile SHALL define `build`, plus `ci` and `developer`, which both extend `build`. A project's own `devenv.nix` SHALL be able to add to any of the three. The module SHALL add its tooling and Claude Code settings to `developer` only, except `openspec`, which it SHALL also add to `ci` for a project's gate. `build` shells get none.

Tested by: the `cache` job in `dispatch-updates.yaml`; the gate, with `ci openspec`, on its platform. Nothing checks `build` lacks it.

#### Scenario: Fixture shells build
- **WHEN** a commit lands on main
- **THEN** the `ci` and `developer` shells of `tests/fixtures/rust-lib` and `tests/fixtures/rust-worker` build on all three platforms, or the dispatch to projects is held back

#### Scenario: openspec in the ci shell
- **WHEN** a project's CI enters the `ci` shell
- **THEN** `openspec` is on its PATH

#### Scenario: No openspec in the build shell
- **WHEN** a project enters its `build` shell
- **THEN** the module has added no `openspec` to it
