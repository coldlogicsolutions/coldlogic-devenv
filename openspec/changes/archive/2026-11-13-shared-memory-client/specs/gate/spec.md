# Spec Delta

## MODIFIED Requirements

### Requirement: The gate builds the module and every profile
The gate SHALL build this repository's own shell, which builds the module's packages and so runs their build-time tests, and the `ci` and `developer` shells of every fixture under `tests/fixtures`, each with the module's `devenv.lock`, all with the memory variables unset. It SHALL also build its own shell with a placeholder memory store and with auto memory off, together and each alone, so every combination is evaluated.

Tested by: the gate itself.

#### Scenario: A guard test fails
- **WHEN** a change makes a case in `claude-guard-test.py` fail
- **THEN** the shell build fails and the gate exits non-zero

#### Scenario: A profile breaks
- **WHEN** a change makes a fixture's `ci` shell fail to evaluate or build
- **THEN** the gate fails for that fixture and profile

#### Scenario: The configured build
- **WHEN** the gate runs
- **THEN** one build of this repository's shell has `COLDLOGIC_MEMORY_URL` set to a placeholder host it never contacts, `COLDLOGIC_MEMORY_USER` set and `COLDLOGIC_DISABLE_AUTO_MEMORY=1`

#### Scenario: The mixed builds
- **WHEN** the gate runs
- **THEN** one build has only `COLDLOGIC_MEMORY_URL` and `COLDLOGIC_MEMORY_USER` set (`build: shell (memory store, auto memory on)`), and one only `COLDLOGIC_DISABLE_AUTO_MEMORY=1` (`build: shell (auto memory off)`)

#### Scenario: The memory settings break
- **WHEN** a change makes the settings generated with the memory store configured, or with only one of the store and the switch, fail to evaluate, and the shell without either still builds
- **THEN** the build for that combination fails and the gate exits non-zero

#### Scenario: The developer's own variable
- **WHEN** the gate runs on a machine, or in a session, where `COLDLOGIC_MEMORY_URL` or `COLDLOGIC_DISABLE_AUTO_MEMORY` is set
- **THEN** its ordinary shell and fixture builds still evaluate with neither, and its configured build uses the placeholder
