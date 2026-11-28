# Spec Delta

## ADDED Requirements

### Requirement: The gate checks each fixture's ci shell has openspec
For every fixture under `tests/fixtures`, the gate SHALL enter the fixture's `ci` shell, with the module's `devenv.lock`, and run `openspec --version` from that shell's own packages, so that an `openspec` already on the gate's `PATH` cannot pass the check.

Tested by: the gate itself, and the deliberate-failure run in the change's tasks.

#### Scenario: openspec leaves the ci profile
- **WHEN** a change removes `openspec` from what the module adds to `ci`
- **THEN** the `ci openspec` check fails for each fixture and the gate exits non-zero

#### Scenario: openspec only on the gate's own PATH
- **WHEN** the gate runs from the developer shell, whose `PATH` has `openspec`, and a fixture's `ci` shell has none of its own
- **THEN** the `ci openspec` check for that fixture still fails

#### Scenario: openspec is there
- **WHEN** every fixture's `ci` shell has `openspec`
- **THEN** each `ci openspec` check prints the version and passes
