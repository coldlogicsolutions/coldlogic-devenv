# Spec Delta

## MODIFIED Requirements

### Requirement: The gate checks sources, scripts and specs
The gate SHALL run the guard's test cases, check every tracked `.nix` file's formatting with the formatter the nixfmt hook uses, run shellcheck over `packages/*.sh` and `scripts/*.sh`, and run `openspec validate --all --strict`. It SHALL also run the adoption script in a fresh git repository and check, with the same formatter, every `.nix` file the script creates there.

Tested by: the gate itself, and for the adoption check the deliberate-failure run in the change's tasks.

#### Scenario: A shellcheck finding
- **WHEN** a script under `scripts/` has a shellcheck finding
- **THEN** the shellcheck check fails and the gate exits non-zero

#### Scenario: An invalid spec
- **WHEN** a change's delta spec has a requirement without a scenario
- **THEN** the OpenSpec check fails

#### Scenario: The adoption script writes a misformatted Nix file
- **WHEN** a change makes `scripts/adopt.sh` create a `devenv.nix` that nixfmt would rewrite
- **THEN** the `adopt: nixfmt` check fails and the gate exits non-zero

#### Scenario: The adoption script stops creating devenv.nix
- **WHEN** a change makes `scripts/adopt.sh` create no `devenv.nix` in a fresh repository, or fail there
- **THEN** the `adopt: nixfmt` check fails rather than passing with nothing to check
