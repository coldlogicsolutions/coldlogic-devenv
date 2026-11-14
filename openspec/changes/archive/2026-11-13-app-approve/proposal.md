# Proposal

## Why

A developer's own PR can't be merged without an admin bypass (#115). The organization ruleset asks for an approval from the `developer` team, the author can't approve their own PR, and the App is forbidden to approve anything. The ruleset is changing to one required approval from any account with write access other than the author (coldlogicsolutions/infrastructure#40). A test on PR #116 showed the App's approval then counts. So the App needs one way to approve, narrow enough that it only ever approves a developer's PR it has reviewed.

## What Changes

- **New `gh-app pr approve <number> [-R owner/repo]`**, the only way the App approves. It is not a `gh` command and nothing of it reaches `gh pr`. It refuses unless all of these hold:
  - the PR is open and not a draft;
  - its author is a person, not a bot and not the App;
  - the author is an active member of the `coldlogicsolutions` `developer` team, read from GitHub when the command runs. Any failure to read it refuses, and the message names the App's missing organization permission (Members: read, #119) when the team itself can't be read;
  - the App has its own submitted review on the PR's head commit, and no change request of its own stands there.

  It then approves with the review pinned to that head commit. If the App already approved that commit, it succeeds and sends nothing. If the head moved while it approved, it withdraws the approval and fails.
- **`gh-app pr review --approve` is refused by the wrapper itself**, in every spelling, with a pointer to `gh-app pr approve`. Today only the guard refuses it.
- **`gh-app pr approve` and `gh-app pr review` run without a prompt**: both are added to the module's allow rules. The guard still denies `gh-app pr review --approve`, an approval through `gh-app api`, `gh-app alias`, and every approval with the user's own `gh`.
- **A review with no body asks**, as a comment with no body does: gh would prompt or open an editor for it.
- **New guard deny: `gh pr create` and `gh pr new` with the user's credentials**, bare or wrapped. A session opens PRs as the App only. Otherwise it could open a PR as the developer and have the App approve it.
- **`gh-app` gets build-time tests**, its first. They cover every refusal of `pr approve`, its success, and that `pr merge` behaves as before. A `gh-app` that fails them doesn't build.

Not in this change:

- The ruleset itself (infrastructure#40) and the App's organization permission (#119). Until #119 lands, `gh-app pr approve` refuses every PR with the permission message. Until infrastructure#40 lands, an App approval doesn't satisfy the ruleset. So this change can merge first and changes nothing that merges.
- Opening a PR through the API with the user's credentials (`gh api` POST to `/pulls`, GraphQL `createPullRequest`). Only the `gh pr create` command is denied.
- `gh-app pr merge`. It still merges only the App's own PRs, approved by the developer named in `GH_APP_APPROVER`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `gh-app`: adds the approval command and its checks, the refusal of `pr review --approve`, and the build-time tests. The merge requirements are unchanged.
- `claude-guard`: the requirement that the App never approves becomes "approves only through `gh-app pr approve`"; `gh pr create` and `gh pr new` with the user's credentials are denied; a review with no body asks; the module's allow list scenarios gain the approval and the review.
- `session-permissions`: the list of commands allowed without a prompt gains gh-app's `pr approve` and `pr review`.

## Impact

- `packages/gh-app.sh`: a `pr approve` block and a `pr review` check, before the `pr merge` block; the header comment.
- `packages/gh-app-test.sh`: new.
- `packages/gh-app.nix`: runs the tests when the package builds.
- `packages/claude-guard.py`: one deny in the `gh` branch, two small additions so a bodiless review asks, comments and messages.
- `packages/claude-guard-test.py`: new rows, and the copy of the allow list.
- `devenv.nix`: two allow rules and their comment.
- `README.md`, `scripts/check.sh` (a comment), `openspec/specs/gh-app/spec.md` (the Purpose line, which a delta can't change).
- Every project that imports the module gets all of this on its next lock update. A session there can then have the App approve a developer's PR without a prompt, once #119 and infrastructure#40 are in. Sessions that ran `gh pr create` with the developer's credentials are denied and pointed to `gh-app pr create`.
