# Design

## Context

See proposal.md, Why. What was checked:

- `profiles/rust-worker/devenv.nix` has `profiles.build.module.packages = with pkgs; [ worker-build wasm-pack ];` and declares no options. Nothing else in the module (`devenv.nix`, `profiles/`, `packages/`) calls `mkOption`.
- At the module's pinned nixpkgs (`ac6b2166e7a9375683b8e98f860f273222337b16`, `devenv.lock`), `pkgs/by-name/wo/worker-build/package.nix` is 0.8.5, built with `rustPlatform`, `fetchSubmodules = true`, `buildAndTestSubdir = "worker-build"`, `openssl` and `pkg-config`. On nixpkgs-unstable it is 0.9.0 and adds `zstd` to `buildInputs`.
- workers-rs v0.9.0's workspace sets `rust-version = "1.91"`. The pinned nixpkgs ships rustc 1.97 (`pkgs/development/compilers/rust/1_97.nix`), so nixpkgs' `rustPlatform` is new enough.
- worker-build 0.9.0's crate also builds a second binary, `worker-codegen`, and its `main` prints the bare version for `--version` (first argument only).
- devenv merges profile modules into the top-level configuration, and a profile module written as a function `{ config, ... }:` sees the merged result, the project's settings included (devenv docs, Profiles). `packages/topcoat-cli.nix` already relies on this.

## Goals / Non-Goals

**Goals:**
- One place, `packages/worker-build.nix`, that lists the lines and their pins; the option's values are derived from it, so the two can't disagree.
- One derivation per line for a given nixpkgs, shared by the `build`, `ci` and `developer` shells.

**Non-Goals:**
- Pinning `wasm-pack`. It stays nixpkgs'.
- A Worker build in the gate or cache job (follow-up issue).
- An escape hatch to nixpkgs' `worker-build`. A project that wants another version can still add its own package in its `devenv.nix`.

## Decisions

### The option is `coldlogic.workerBuild.line`

- `coldlogic` is the module's own namespace: its commands are `coldlogic-*`, its tasks `coldlogic:*`, its environment variables `COLDLOGIC_*`. Putting options under it keeps them clear of devenv's (`languages.*`, `packages`) and of anything a later devenv adds, and tells a reader of a project's `devenv.nix` where the option comes from.
- `workerBuild` is the tool, in devenv's camelCase (`clangLinker`, `settingsPath`), so a later option about the same tool sits beside it.
- `line` rather than `version`: the value is a minor line (`"0.9"`), and the patch is the module's choice. `version = "0.9"` would read as an exact version.
- Not `coldlogic.rustWorker.*`: only the rust-worker profile declares it, so the option exists only in projects that import that profile, and the extra level adds nothing.
- Alternatives: `languages.rust.workerBuild` (rejected: it's inside devenv's namespace and could clash with an upstream option); a string with a version check (rejected: an enum fails at evaluation and lists the lines carried).

### `packages/worker-build.nix` returns one package per line

It takes `{ pkgs }` and returns an attribute set keyed by line, `{ "0.9" = <derivation>; }`, each entry built from that line's `version`, `hash` and `cargoHash`. The profile imports it once, declares the enum as `lib.types.enum (builtins.attrNames workerBuilds)`, and the default as the newest name (sorted with `lib.versionOlder`; with one line, `"0.9"`). Listing the names doesn't build anything, so only the selected line builds. Adding a line is adding one entry; the enum and the default follow.

Alternative: a function `{ pkgs, line }` plus a separate list of names in the profile (rejected: two lists to keep in step).

### Built with nixpkgs' `rustPlatform`, not the project's Rust

worker-build is a host tool, not something compiled against the project's crate, and its MSRV (1.91) is below the pinned nixpkgs' rustc (1.97). Using `pkgs.rustPlatform` gives one derivation that depends only on nixpkgs, which the update workflow aligns with the module's lock, so the cache job's build is every project's. topcoat-cli builds with the project's Rust only because nixpkgs' rustc was once older than Topcoat's `rust-version` (#31); if a later worker-build line needs a newer Rust than nixpkgs has, its entry can switch to the same `makeRustPlatform` approach. The comment header says so.

### Conventions copied from `packages/topcoat-cli.nix`

- A comment header: why it's pinned (#129), how to bump a line (change `version`, set both hashes to `lib.fakeHash`, build, paste each reported hash), and how to add one.
- `preConfigure` setting `HOME` to a temporary directory (#127). Whether worker-build's build writes `$HOME` wasn't checked; the fix costs nothing and keeps an unsandboxed root build from creating `/homeless-shelter`, which would break every later build in that store.
- `doCheck = false`: the tests aren't needed for the binary, and skipping them avoids compiling the dev-dependencies, `wasm-bindgen-cli-support` among them.
- `versionCheckHook` with `doInstallCheck = true`, and `meta.mainProgram = "worker-build"` (required: the package installs `worker-codegen` too). This is what makes "the binary reports its pinned version" a check that runs in every fixture build.

Kept from nixpkgs' 0.9.0 package: `fetchSubmodules = true`, `buildAndTestSubdir = "worker-build"`, `buildInputs = [ openssl zstd ]`, `nativeBuildInputs = [ pkg-config ]`, `meta.license` Apache-2.0 or MIT. Not kept: `__structuredAttrs = true` (not needed for this build).

### `profiles/rust-worker/devenv.nix` becomes an `options`/`config` module

A module that declares `options` must put its settings under `config`. So the file becomes `{ pkgs, lib, ... }: { imports = [ ../rust-lib/devenv.nix ]; options.coldlogic.workerBuild.line = ...; config.profiles = { ... }; }`. The `build` profile module becomes a function `{ config, ... }:` that reads `config.coldlogic.workerBuild.line`, like the `ci` and `developer` modules already do for topcoat, so a line a project sets anywhere is seen.

## Risks / Trade-offs

- [Projects on `worker` 0.8.x break on their next module update, since 0.9 is the only line] → Called out as BREAKING in proposal.md. Adding a `"0.8"` entry (0.8.x's latest patch and its hashes) is the remedy if one is needed before those projects move.
- [The module's pinned nixpkgs drops or changes something the build needs, such as `zstd`] → The fixture builds in the gate and cache job fail first, before the dispatch goes out.
- [A later line needs a Rust newer than nixpkgs'] → Switch that entry to `makeRustPlatform`, as topcoat-cli does; noted in the header.
- [Own builds cost CI time where nixpkgs' were substituted from cache.nixos.org] → One build per nixpkgs revision, pushed to the `coldlogic` cache by the cache job.

## Migration Plan

Projects need nothing set: the default is the newest line. A project that wants to stay on a line when a newer one is added sets `coldlogic.workerBuild.line` in its `devenv.nix`. Rollback is reverting the change, which returns to nixpkgs' `worker-build`.
