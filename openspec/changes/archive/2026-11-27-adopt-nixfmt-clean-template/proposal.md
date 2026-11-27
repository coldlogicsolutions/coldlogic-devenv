# Proposal

## Why

The `devenv.nix` that `scripts/adopt.sh` creates fails the module's own nixfmt pre-commit hook: nixfmt rewrites its `{ }` to `{` and `}` on separate lines. So the first commit in every newly adopted project fails until the developer reformats a file they never wrote (issue #133). Nothing catches this, because the adoption script has no tests.

## What Changes

- `scripts/adopt.sh`: the `devenv.nix` template loses the blank line between `{ pkgs, ... }:` and `{ }`, which is what makes nixfmt break the braces apart. The file's content is otherwise the same.
- New `scripts/adopt-test.nix`: a build that runs `adopt.sh --no-update` in a fresh git repository and runs `nixfmt --check` on every `.nix` file it leaves there, with nixfmt from the nixpkgs revision `devenv.lock` pins.
- `scripts/check.sh`: a new named check, `adopt: nixfmt`, that builds that test.
- `README.md`: the `scripts/check.sh` row lists the new check, and "What's here" gets a row for `scripts/adopt-test.nix`.

Not in this change: tests for the rest of the adoption script (idempotence, untracking, profile choice). Every other project-adoption requirement stays "Tested by: none".

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `project-adoption`: adds a requirement that the Nix files the script creates are already formatted as the module's nixfmt hook formats them, with a test.
- `gate`: "The gate checks sources, scripts and specs" also runs the adoption script in a fresh repository and checks the formatting of the Nix files it creates.

## Impact

- `scripts/adopt.sh` (the `devenv.nix` heredoc, lines 162-168), new `scripts/adopt-test.nix`, `scripts/check.sh`, `README.md`.
- The gate gains one small build, locally and in the `check` CI job. Its inputs (bash, coreutils, findutils, grep, sed, git, yq-go, nixfmt) come from the pinned nixpkgs and substitute from the public cache.
- Projects already adopted are not touched: the script never rewrites an existing `devenv.nix`, and a project that hit the bug has already reformatted its file.
