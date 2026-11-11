# Tasks

## 1. Initialise OpenSpec

- [x] 1.1 Run `openspec init --tools none` and verify `openspec/config.yaml` names the `spec-driven` schema
- [x] 1.2 Add `/.claude/skills/openspec-*/` and `/.claude/commands/opsx/` to `.gitignore` and verify `git check-ignore` matches `.claude/skills/openspec-explore/SKILL.md` and `.claude/commands/opsx/explore.md`

## 2. Baseline specs

- [x] 2.1 Write a spec delta for each capability in the proposal and verify `openspec validate backfill-baseline-specs --strict` passes
- [x] 2.2 Check each requirement against the code and README, and name the test that covers it or say none does; verify by review

## Workflow follow-up

- Archive the change on the feature branch before the PR merges, and verify `openspec validate --specs --strict` passes on the archived specs.
