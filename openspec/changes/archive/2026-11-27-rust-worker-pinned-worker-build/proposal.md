# Proposal

## Why

The rust-worker profile takes `worker-build` from nixpkgs (`profiles/rust-worker/devenv.nix`, the `build` profile's packages), so whichever version the project's nixpkgs has is the one it gets. worker-build only builds a `worker` crate on its own minor line, with no way around it, so a nixpkgs bump to 0.9.0 failed coldlogic.dev's Worker build on `worker` 0.8.7 (#129). The version has to be one the module chooses, and one a project can name.

## What Changes

- New `packages/worker-build.nix`: worker-build built from `cloudflare/workers-rs` with nixpkgs' `rustPlatform`, one entry per minor line, each pinned to that line's latest patch with its source and cargo hashes. It carries one line for now, `"0.9"` (0.9.0). Adding a line later means adding an entry with its hashes.
- New option `coldlogic.workerBuild.line`, declared by the rust-worker profile: an enum of the lines `packages/worker-build.nix` carries, defaulting to the newest. It is the module's first `mkOption`.
- The rust-worker `build` profile installs the selected line's package in place of `pkgs.worker-build`. A nixpkgs bump no longer changes which worker-build a project gets.
- **BREAKING** for projects still on `worker` 0.8.x: the module's pinned nixpkgs (`ac6b2166`) has worker-build 0.8.5, so today those projects build. After this change they get 0.9.0, which refuses `worker` 0.8.x, and no line is offered that accepts it. Projects need `worker` 0.9 before taking this update (coldlogic.dev waits on coldlogicsolutions/topcoat-workers#77).
- `README.md`'s `profiles/rust-worker` row names the pinned worker-build and the option, and a new `packages/worker-build.nix` row says how to bump or add a line.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `toolchain-profiles`: the requirement "rust-worker extends rust-lib for Cloudflare Workers" says `worker-build` is the module's pinned build of the line the project selects, not nixpkgs'.

## Impact

- `profiles/rust-worker/devenv.nix`: becomes an `options`/`config` module; the `build` profile's packages change.
- `packages/worker-build.nix`: new.
- `README.md`: the `profiles/rust-worker` row, plus a `packages/worker-build.nix` row.
- `tests/fixtures/rust-worker` builds its `ci` and `developer` shells with the default line, so the gate builds worker-build 0.9.0 and the cache job pushes it to the `coldlogic` cache. Each project builds the one derivation for its own nixpkgs (aligned with the module's lock by the update workflow, so it is a cache hit).
- Out of scope: building a real Worker in the gate or the cache job, so a worker/worker-build mismatch fails before update PRs go out. That has its own follow-up issue.
