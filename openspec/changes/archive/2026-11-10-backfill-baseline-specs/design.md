# Design

## Context

The module already runs OpenSpec's own init for its consumers. The `coldlogic:openspec-files` task runs `openspec init --tools claude` wherever `openspec/config.yaml` exists and git ignores the generated skills. This repository had neither of those, so the task never ran here.

## Goals / Non-Goals

**Goals:**
- Give the repository the same OpenSpec layout every consuming project gets.
- Record current behaviour, one capability per cohesive area of the module, with each requirement naming its test or saying it has none.

**Non-Goals:**
- Changing module behaviour or adding tests. Gaps the specs expose are follow-ups.
- Initialising OpenSpec in consuming projects by default. That's a module change, proposed separately.

## Decisions

- **Baseline through an archived change, not hand-written main specs.** The specs reach `openspec/specs/` through `openspec archive`, the command that creates them, and the archive keeps a record of the backfill. The alternative, writing `openspec/specs/*/spec.md` directly, has no command behind it and leaves no record of why the specs appeared.
- **`openspec init --tools none`, and the skills from the shell.** The tracked tree gets only `openspec/`. The Claude Code skills and commands come from the module's task, like any project's, once `.gitignore` names them. Committing them would bring back the tracked copies that #32 removed.
- **Capabilities follow the module's parts, not its files.** The guard, `gh-app`, permissions and sandbox, generated files, plugins, git hooks, profiles, updates, OpenSpec files and adoption each change for their own reasons, so each gets its own spec. Permissions and sandbox share one spec because they're generated together and change together.

## Risks / Trade-offs

- [Specs drift from the code because nothing enforces them] → The commit gate in #52 (Phase 4) requires an OpenSpec change for non-trivial work. Requirements marked "Tested by: none" show where tests would help most.
- [A requirement misstates current behaviour] → Each one was written from the code and the README. Review corrects it, and a later change fixes the spec, not the code, when the code is right.
