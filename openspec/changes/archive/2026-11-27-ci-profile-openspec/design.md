# Design

## Context

See proposal.md for the motivation (issue #150).

Checked in the code:

- The shared module's only top-level attributes are `cachix.pull` and `profiles.developer.module` (`devenv.nix:146-148`). `openspec` is in that module's `packages` (`devenv.nix:599-601`). The module defines no `ci` and no `build`, and sets no `extends`.
- `profiles/rust-lib/devenv.nix` defines `build`, `ci` (`extends = [ "build" ]`, lines 32-61) and `developer` (`extends = [ "build" ]`, lines 63-118). `profiles/rust-worker/devenv.nix` imports it and adds its own `ci.module` and `developer.module`. So one profile already has its module defined in two or three files (`developer` in all three, `ci` in two), with `extends` set in only one of them.
- `scripts/check.sh`: `fixture_builds` (lines 109-112) copies `devenv.lock` into the fixture and runs `devenv --profile <p> build shell` there in a subshell. The fixture loop (lines 139-144) calls it for `ci` and `developer`. The gate puts `scripts/check-tools.nix`'s `bin` first on `PATH` (line 59), and that has `openspec`. Run the documented way, `devenv shell --quiet -- scripts/check.sh`, it also inherits the developer shell's `PATH`, which has `openspec` too.
- `.gitignore` already ignores `devenv.lock`, `.devenv*`, `.claude/`, `.mcp.json` and `.pre-commit-config.yaml` under `tests/fixtures/*/`.
- The cache job enters each fixture's shells with `devenv --profile "$profile" shell -- true` (`dispatch-updates.yaml:83`), so entering a fixture's `ci` shell is already done on all three platforms.
- `scripts/adopt.sh` offers `--profile none` (README.md:14), so projects with the shared module and no language profile exist by design.

Checked by running (devenv 2.4.0, aarch64-darwin, in a scratch project outside the repository: one file standing in for the shared module with `profiles.ci.module = { pkgs, ... }: { packages = [ pkgs.openspec ]; };` and no `extends`, one standing in for a language profile with `build` and a `ci` that extends it):

- The definitions merge. The `ci` shell had `openspec` (from the first file), the second file's `ci` package, and `build`'s package through `extends`.
- With only the first file imported, `devenv --profile ci shell` works and has `openspec` and nothing from `build`. A profile nothing defines fails: `Profile 'nosuch' not found. Available profiles: ...`.
- A command run in the shell inherits the caller's `PATH`. `jq`, which no profile of the scratch project had, resolved to the caller's. Entered from inside this repository's developer shell, the scratch `ci` shell still found the developer shell's `git`.
- Inside the shell, `DEVENV_PROFILE` is that shell's own package set, also when entered from inside another devenv shell. `"$DEVENV_PROFILE/bin/openspec" --version` printed the version and exited 0. The same for a tool the shell didn't have (`jq`) exited 127, although `jq` was on the inherited `PATH`.
- `devenv --profile ci shell --quiet --clean -- openspec --version` also works, and with `--clean` the inherited tools are gone.
- devenv declares `profiles.<name>.module` as `types.deferredModule` and `extends` as `listOf str` with default `[ ]` (devenv's `src/modules/profiles.nix`, read on its main branch, not at the locked revision).
- `openspec validate --strict` accepts a requirement description of 500 characters and rejects 511, counted from the line after the `### Requirement:` header to the end of the `Tested by` line. The modified toolchain-profiles description is 495 by that count.
- The gate's shellcheck (from `scripts/check-tools.nix`) reports SC2016 on the step's single-quoted `bash -c` argument and exits 1, and passes the same line with `# shellcheck disable=SC2016` above it, trailing comment included. Run on a scratch copy of the function in decision 3.
- `openspec`'s closure is 203.9 MB on aarch64-darwin, and it references only bash and Node 24.

Assumed, not run (the tasks settle each):

- The same merge holds in the real module and fixtures. Only the scratch stand-ins were run, because planning doesn't edit `devenv.nix`. Task 1.2.
- Entering a fixture's `ci` shell works inside a sandboxed session. The scratch project was entered from this planning session, but not a fixture, and the fixtures' `ci` shells run the Rust module's shell setup. Tasks 2.3 and 3.2.
- The step behaves the same on Linux in the `check` job. The PR's run shows it.
- `openspec`'s Node is the `pkgs.nodejs` that `rust-lib`'s `build` already has, so the `ci` closure grows by little. Not compared.

## Goals / Non-Goals

**Goals:**

- A project's `ci` shell has `openspec` with no change in the project.
- The gate fails if `openspec` ever leaves the `ci` profile, and cannot be satisfied by an `openspec` that came from anywhere but the fixture's `ci` shell.

**Non-Goals:**

- Other tools a project's gate may want in `ci` (`nixfmt`, `shellcheck`): a separate issue.
- Checking what `ci` leaves out. "The ci profile stays slim" keeps its "nothing checks what is left out".
- Running anything OpenSpec generates in `ci`. The `coldlogic:openspec-files` task stays in `developer`.

## Decisions

### 1. `profiles.ci.module` in the shared module

Next to `profiles.developer.module` in `devenv.nix`, with its own comment:

```nix
  # A project's gate runs `openspec validate` in CI, so `ci` gets openspec
  # too, and nothing else of the module's.
  profiles.ci.module =
    { pkgs, ... }:
    {
      packages = [ pkgs.openspec ];
    };
```

This is the form the scratch project ran, laid out as nixfmt lays it out (task 1.1 checks). No `extends` here: the language profile sets it, as it does for `developer`.

Placed before `profiles.developer.module`, which runs to the end of the file (over 1,100 lines), so it is seen.

Alternatives rejected:

- Top-level `packages = [ pkgs.openspec ]`. It reaches `build` and the unprofiled shell, which the spec says get none of the module's tooling, and a build image would carry Node for a tool it never runs.
- `rust-lib`'s `ci.module`. The need comes from the shared module (it is what brings OpenSpec to a project), not from Rust. Every later language profile would have to repeat it, and a project with no language profile would still be broken.
- A `build` profile in the shared module that `ci` and `developer` extend. A bigger change to how profiles layer, for one package.
- Have each project add `openspec` to its own `ci`. That is the workaround the issue exists to remove.
- Have the project's gate fetch `openspec` itself (`nix shell`, or a pinned tools file as this repository's gate has). Each project would pin its own version, apart from the one that generated its skills.

### 2. `openspec` only

`nixfmt` and `shellcheck` are also only in `developer`, and a project's gate may want them. They are left for their own issue: each needs its own decision (the nixfmt hook's package, whether shellcheck belongs in the module at all), and this change unblocks a failing main today.

### 3. The gate enters the `ci` shell and runs `openspec` from the shell's own package set

A new function beside `fixture_builds`, and one step per fixture after the fixture's two builds:

```bash
# Runs openspec from a fixture's ci shell, which is where a project's gate
# runs `openspec validate`. From the shell's own packages ($DEVENV_PROFILE),
# not PATH: the shell inherits the gate's PATH, which has openspec whatever
# the profile holds.
fixture_ci_has_openspec() {
  local fixture=$1
  # shellcheck disable=SC2016  # expanded by the shell devenv starts
  cp devenv.lock "$fixture" && (cd "$fixture" && devenv --profile ci shell --quiet -- bash -c '"$DEVENV_PROFILE/bin/openspec" --version')
}
```

```bash
for fixture in tests/fixtures/*/; do
  fixture=${fixture%/}
  for profile in ci developer; do
    step "build: ${fixture##*/} ($profile)" fixture_builds "$fixture" "$profile"
  done
  step "ci openspec: ${fixture##*/}" fixture_ci_has_openspec "$fixture"
done
```

Why each part:

- `"$DEVENV_PROFILE/bin/openspec"`, not `openspec`. This departs from the form the task was given (`... shell --quiet -- openspec --version`), because that form cannot fail where the gate runs: the gate's `PATH` always has the check tools' `openspec`, and the shell passes `PATH` through (run, see Context). `DEVENV_PROFILE/bin` is what devenv builds from the shell's `packages`, so the check is exactly "the `ci` profile's packages include `openspec`". If `DEVENV_PROFILE` were ever unset, the path is `/bin/openspec` and the check fails, rather than passing.
- `--version`: the fixtures have no `openspec/` directory, so `validate` has nothing to read. `--version` proves the binary is there and starts.
- `step`, not `with_tools`: it uses none of the gate's tools, so it still runs when they fail to build.
- The lock is copied as `fixture_builds` copies it, so the step stands alone and doesn't depend on a build step having run first. The copy is gitignored.
- After the builds, so the shell is already built when it is entered. If the `ci` build failed, this step fails too, which is right: the gate runs every check and reports each.
- The step name follows `build: rust-lib (ci)`: a kind, then the fixture.
- bash 3.2 compatible: nothing new.

Alternatives rejected:

- `devenv --profile ci shell --quiet -- openspec --version`. Vacuous, as above.
- `--clean`, which drops the inherited environment so plain `openspec` is a true test of `PATH`. It works in the scratch project. But it also drops `HOME`, `TMPDIR` and the session's `XDG_RUNTIME_DIR` from the shell's commands, and the fixtures' `ci` shells have only ever been entered with a normal environment. A failure would then be about the clean environment, not about `openspec`. It stays the fallback: if task 2.2 finds the `DEVENV_PROFILE` form doesn't work in a real fixture, use `devenv --profile ci shell --quiet --clean -- openspec --version` and drop the shellcheck directive.
- Strip the gate's `PATH` for this one call. The gate would have to work out which entries hold `devenv` and `nix` and keep those.
- Build an attribute and look inside it (`devenv --profile ci build <attr>`), with no shell entry. It leans on an internal attribute name rather than on what a project's CI does, which is enter the shell.
- Give a fixture an `openspec/` directory and run `openspec validate` there. It tests the fixture's specs as well as the profile, and adds files that need keeping valid.
- Leave it to the cache job. That runs after merge, on main; the gap would reach projects' update PRs before anyone saw it.

### 4. Specs

- `toolchain-profiles`, "Profiles layer build, ci and developer": the sentence that said `ci` gets none of the module's tooling now carves out `openspec`. The existing scenario is kept, one is added for `openspec` on the `ci` shell's `PATH`, and one for `build` having none from the module, which is what decision 1 rules out and nothing else in the spec states. The `Tested by` line is reworded to fit the 500-character limit (495) and names the new check. The `build` scenario has no test; the line doesn't claim one.
- `gate`: a new requirement rather than an edit to "The gate builds the module and every profile". That one is about builds and is already long; this is a different kind of check with its own failure.
- `openspec-files`: unchanged. It covers the generated Claude Code files, all in `developer`.

## Risks / Trade-offs

- [The check passes without testing anything, because `openspec` is on the inherited `PATH`.] → It runs the binary from `$DEVENV_PROFILE/bin`, not `PATH`. Task 2.3 removes `openspec` from `ci` and requires both steps to fail, run from inside the developer shell, where the leak is.
- [The real module doesn't merge as the scratch stand-ins did.] → Same option type and the same pattern `developer` uses today. Task 1.2 builds and enters both fixtures' `ci` shells before the gate step is written.
- [Entering a shell in a fixture needs something a sandboxed session can't write, unlike `devenv build shell`.] → The module's generated files, git hooks and tasks are all in `developer`, so `ci` has none of them. Entering still runs devenv's own `devenv:files:cleanup` and `devenv:enterShell` tasks (seen in the scratch project), which write under the fixture's gitignored `.devenv`. Tasks 2.3 and 3.2 run the gate from a session. If it fails there and not in a terminal, stop and report: the gate spec requires both to agree.
- [devenv renames `DEVENV_PROFILE` or stops building it from `packages`.] → The step fails loudly (no such file), on the devenv update's own PR, since the gate runs there.
- [Every project's `ci` closure grows.] → `openspec` references only bash and Node; `rust-lib`'s `build` already has Node. The cache job pushes the fixtures' `ci` shells, so projects download it. Not measured against the current `ci` closure.
- [A project with no language profile gets a `ci` profile holding `openspec` alone, with no `build` under it.] → Before, `devenv --profile ci` failed there with "Profile 'ci' not found", so nothing that worked changes. Such a project's CI that enters `ci` now gets `openspec` and whatever the project adds to `ci` itself. Its `build` profile still doesn't exist unless the project defines one. The README row says so.
- [A project already adds `openspec` to its own `ci`.] → Two definitions of the same package in a list merge; the shell has it once. A project that added a different `openspec` (another nixpkgs) would have two on `PATH`, in an order this change doesn't control. None is known; the open question below covers it.
- [Two more shell entries in the gate.] → The shells are built by the steps just before, so each entry is seconds.
- [The `Tested by` line of the toolchain requirement is 5 characters under the limit.] → Measured against `openspec validate --strict`'s own count. Anyone adding to it later must shorten something; the tasks say so.

## Migration Plan

Merging is the rollout. The cache job builds and pushes the fixtures' new `ci` shells, then dispatches the update; each project's update PR picks up the module and its CI gets `openspec`. coldlogic-audio-common's main goes green when its update PR merges, with no change of its own. Rollback is a revert.

## Open Questions

- Has any project already added `openspec` to its own `ci` to get its gate through? If so it can drop that after the update. Nothing breaks if it doesn't.
