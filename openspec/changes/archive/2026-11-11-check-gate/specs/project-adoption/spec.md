# Spec Delta

## ADDED Requirements

### Requirement: A missing gate is listed for the developer
When the project has no `scripts/check.sh`, the script SHALL list adding one among the steps left for the developer, saying it must run the project's checks and exit non-zero on any failure. It SHALL NOT create the file, and SHALL say nothing about it when the file exists.

Tested by: none.

#### Scenario: Project without a gate
- **WHEN** a developer runs `scripts/adopt.sh` in a project with no `scripts/check.sh`
- **THEN** "Needs you" lists adding `scripts/check.sh`, and the script creates no such file

#### Scenario: Project with a gate
- **WHEN** the project has `scripts/check.sh`
- **THEN** the script's output doesn't mention it
