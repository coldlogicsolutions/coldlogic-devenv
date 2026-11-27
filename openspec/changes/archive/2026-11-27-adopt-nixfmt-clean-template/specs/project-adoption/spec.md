# Spec Delta

## ADDED Requirements

### Requirement: Nix files the script creates are already formatted
Every `.nix` file the script creates SHALL pass `nixfmt --check` with the nixfmt the module's `devenv.lock` pins, so the nixfmt hook doesn't stop the project's first commit. The project's hook uses its own nixpkgs' nixfmt, which can differ.

Tested by: `scripts/adopt-test.nix` (gate step `adopt: nixfmt`), "New project" only. "Existing devenv.nix": none.

#### Scenario: New project
- **WHEN** a developer runs `scripts/adopt.sh --no-update` in a git repository with no `devenv.nix`
- **THEN** `nixfmt --check` passes on the `devenv.nix` the script created

#### Scenario: Existing devenv.nix
- **WHEN** the project already has a `devenv.nix`
- **THEN** the script leaves the file's formatting as it was
