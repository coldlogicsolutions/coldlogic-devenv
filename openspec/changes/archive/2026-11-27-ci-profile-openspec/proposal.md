# Proposal

## Why

The module puts `openspec` only in the `developer` profile (`devenv.nix:601`). A project's CI enters the `ci` shell, and a project's gate runs `openspec validate --all --strict`, so that step fails there with "openspec: command not found" (issue #150). coldlogic-audio-common's main has failed this way on every push. Nothing here catches it: the gate builds each fixture's `ci` shell but never looks at what is in it.

## What Changes

- `devenv.nix`: the shared module adds `openspec` to the `ci` profile as well, with a `profiles.ci.module` beside its `profiles.developer.module`. `build` and unprofiled shells still get nothing from the module.
- `scripts/check.sh`: a new check per fixture, after the fixture's builds, that enters the fixture's `ci` shell and runs `openspec --version` from that shell's own packages.
- `README.md`: the `devenv.nix` row says `openspec` is in `ci` too, and the `scripts/check.sh` row lists the new check. The header comment of `.github/workflows/check.yaml` lists it as well; the workflow's steps don't change.

Not in this change:

- `nixfmt` and `shellcheck`, which a project's gate may also want in `ci`. They get their own issue.
- Any change to what `developer` gets, to the language profiles, or to how OpenSpec's Claude Code files are generated (`openspec-files` is untouched: that task stays in `developer`).
- A check on macOS or aarch64 Linux in CI. The `check` job runs on Linux; the gate covers the platform it is run on.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `toolchain-profiles`: "Profiles layer build, ci and developer" no longer says `ci` gets none of the module's tooling. The module adds `openspec`, and only `openspec`, to `ci`.
- `gate`: a new requirement that the gate checks each fixture's `ci` shell has `openspec`.

## Impact

- `devenv.nix` (one new top-level attribute), `scripts/check.sh` (one function, one step in the fixture loop), `README.md` (two rows).
- Every adopting project's `ci` shell gains `openspec` and its closure (Node) at its next module update. The cache job already pushes each fixture's `ci` shell, so projects substitute it.
- A project that imports the module with no language profile now has a `ci` profile, holding `openspec` alone, where `devenv --profile ci` failed before.
- The gate gains two shell entries (one per fixture), locally and in the `check` job.
- Projects that worked around the gap by adding `openspec` to `ci` themselves keep working: the package is listed twice and built once.
