# Spec Delta

## MODIFIED Requirements

### Requirement: The shell warns when the pin is behind
On each `developer` shell, the module SHALL compare the project's locked `coldlogic-devenv` revision with the remote's HEAD. When they differ it SHALL print `coldlogic-devenv is behind (locked <rev>, latest <rev>); run: devenv update coldlogic-devenv`. It SHALL stay silent for a local `path:` input, with no lock, or when offline, and SHALL never fail the shell. In a session it SHALL print it once per session (session-notices).

Tested by: `packages/session-shell-test.sh`, the once rule only.

#### Scenario: Behind the remote
- **WHEN** the lock pins an older revision than the remote's HEAD
- **THEN** the shell prints the behind warning with both short revisions

#### Scenario: Developing the module locally
- **WHEN** the project points `coldlogic-devenv` at a `path:` input
- **THEN** the shell prints nothing about freshness

#### Scenario: A session's later shells
- **WHEN** a session's shell printed the behind warning, and the same session enters the shell again with the same two revisions
- **THEN** the second shell prints nothing about freshness

#### Scenario: A terminal's later shells
- **WHEN** a developer enters the shell from a terminal twice while the lock is behind
- **THEN** both shells print the warning
