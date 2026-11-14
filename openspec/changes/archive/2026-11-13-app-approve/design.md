# Design

## Context

See proposal.md for the motivation. What follows is what was checked on this branch (`0a5f90e`) and what is assumed.

**Checked in the code:**

- `packages/gh-app.sh` mints the token, exports `GH_TOKEN`, handles `pr merge` in one `if` block (lines 40-120) and ends `exec gh "$@"` for everything else. So `gh-app pr review 5 --approve` reaches `gh` today; only the guard stops it.
- `gh-app.sh` has no `set` line. `writeShellApplication` gives the built script `errexit`, `nounset` and `pipefail`.
- `packages/gh-app.nix` builds the script with no tests. `prune-worktrees.nix`, `session-relink.nix` and `claude-wrapper.nix` each run a test script in a `runCommand` and reference it from the script's text (`# Tested by ${tested}`), so a failing case fails the build.
- `forbidden_from()` in `packages/claude-guard.py`: the `gh` branch denies `pr merge`, `pr review` with an approve flag, `alias`, and an `api` call that merges or reviews. The `gh-app` branch denies `alias`, `pr review` with an approve flag, and the same `api` calls. Neither names `pr create` or `pr approve`.
- `decide()` runs `forbidden()` before any rule, so an allow rule can't undo a deny.
- `rules.Bash.allow` in `devenv.nix` and `MODULE_ALLOW` in `claude-guard-test.py` must be equal; the test file compares them when `devenv.nix` is beside it.
- `scripts/check.sh` lints every `*.sh` with `shellcheck --shell=bash` and every `*.nix` with `nixfmt --check`, and `devenv build shell` builds every module package.
- The guard's tests print `1977/1977 passed` on this branch.

**Checked by running it:**

- `gh-app api orgs/coldlogicsolutions/teams/developer/memberships/derekjw` and `gh-app api orgs/coldlogicsolutions/teams/developer` both answer **404** today, not 403. So a 404 on the membership alone can't tell "not a member" from "the App may not read teams".
- With `gh-app pr approve *` and `gh-app pr review *` added to the module's allow list and the guard unchanged, `decide()` allows `gh-app pr approve 12` (with `-R` in any position) and `gh-app pr review 12 --comment --body x`, still denies every `--approve` spelling, and **allows `gh-app pr review 12 --comment` and `gh-app pr review 12` with no body**. `gh-app pr review 12 --comment --body "-e is nice"` asks, since the body is read as an editor option.
- `gh pr create`, in every spelling tried, gets no decision today.

**Checked by prototype.** Everything in tasks.md was built and run in a scratch copy before it was written down:

- The files in `reference/` are the prototype, byte for byte. `reference/gh-app.sh` differs from today's `packages/gh-app.sh` by 181 added lines and no removed or changed line. `reference/gh-app-test.sh` passes against it, `149 passed, 0 failed`. Both pass `shellcheck --shell=bash`, and `reference/gh-app.nix` passes `nixfmt --check`.
- A `nix build` of `reference/gh-app.nix` with the pinned nixpkgs succeeded: the tests pass in the build sandbox, and `writeShellApplication`'s own shellcheck accepts the script.
- The guard edits and test rows in tasks.md, applied to a copy: the existing cases all still pass, and the 78 new checks pass. Against the unedited guard, 19 of the new checks fail, each one a row this change moves.

**Assumed, not checked** (no approval was submitted for this plan):

- `gh pr view --json author` gives `author.login` as `app/<slug>` and `author.is_bot` as `true` for an App, and `is_bot: false` for a person. The existing merge check already relies on the first.
- The REST review list is oldest first and names the App `coldlogic-ai[bot]`. The existing merge check relies on the order. Issue #115's test on PR #116 showed the App's review as `coldlogic-ai`'s.
- "Create a review" takes `commit_id` with `event=APPROVE`. GitHub's documentation lists the parameter.
- A dismissed review reads back with the state `DISMISSED`.
- The App may dismiss its own review (`PUT .../reviews/<id>/dismissals`).
- `gh pr new` is an alias of `gh pr create`.

Constraints: guardrails here stop mistakes, not attackers (the team's standing policy), so nothing below chases exotic bypasses. Derek's decisions in #115, and those given with the task, are taken as settled: the command and its four checks, allowing it and `gh-app pr review` without a prompt, the `gh pr create` deny for the command only, and tests at build time.

## Goals / Non-Goals

**Goals:**

- One path by which the App approves, which can't approve the App's own work, a bot's, an outsider's, or a commit the App hasn't reviewed.
- Every check fails closed: anything unread or unexpected refuses.
- The approval can't land on a commit other than the one checked.
- No approve path that exists today gets weaker.
- A broken `gh-app` doesn't build.

**Non-Goals:**

- The ruleset (infrastructure#40) and the App's permission (#119).
- Judging the quality of the App's review. The wrapper checks that one exists on the head commit, not what it says.
- Opening a PR through `gh api` with the user's credentials.
- Stopping a session from pushing to a developer's PR branch and then approving. Derek accepted this in #115: the developer's merge click, or auto-merge they turn on, is still needed, since `gh-app pr merge` refuses a PR the App didn't open.
- Changing `gh-app pr merge`.

## Decisions

### 1. A wrapper command, not `gh pr review --approve` with checks around it

`gh-app pr approve` is handled wholly inside `gh-app.sh`, in its own `if` block placed before the merge block, and every path through it ends in `exit`. It builds its own API call. `gh` has no `pr approve`, so if the block were ever skipped the command would fail in `gh`, not approve.

Alternatives rejected:

- **Check, then `exec gh pr review --approve`.** The session's other arguments would reach `gh` (a `--body`, another PR selector), and `gh pr review` can't pin a commit.
- **Let the guard allow `gh-app pr review --approve` in some cases.** The guard reads text and can't see the PR's author or head.
- **A separate program (`gh-app-approve`).** One more name on PATH and in the allow rules, for the same token handling.

### 2. Arguments: one number and `-R`, nothing else

The selector must match `^[1-9][0-9]*$`. `-R`, `--repo` and `--repo=` are taken; any other word starting `-`, a second operand, or a missing number refuses before `gh` runs.

A branch name or a URL is refused: a session reviews a numbered PR, and a branch can name another PR than the one reviewed. No body: an approval's reasoning belongs in the review that must already exist.

Alternative rejected: **pass unknown options through**, as `pr merge` does. Nothing here is passed to `gh pr`, so an unknown option has no meaning.

### 3. What the PR read must look like

One `gh pr view --json url,state,isDraft,headRefOid,author` gives six tab-separated fields, the author's login last, since it alone can be empty and an empty field would shift the ones after it. Then, in this order:

1. The URL must be `https://github.com/<owner>/<repo>/pull/<number>`; the repository and number for the API come from it.
2. The head must be 40 or 64 lowercase hex digits.
3. The state must be `OPEN`.
4. `isDraft` must be exactly `false`.
5. The author must not be `app/coldlogic-ai`.
6. `is_bot` must be exactly `false`.
7. The login must match `^[A-Za-z0-9_-]+$`.

Checks 4 and 6 compare with `false`, so a missing or null value refuses. Check 7 runs before the login goes into an API path, so a login holding `/` or `..` can't change which endpoint is read. Check 5 comes before 6 only for its message.

Closed and merged PRs are refused (the default given with the task): an approval there does nothing useful.

### 4. Team membership: read each time, and a second read to explain a 404

`gh api orgs/coldlogicsolutions/teams/developer/memberships/<login> --jq .state` must succeed and print `active`. A failure refuses.

On failure the wrapper reads the team itself (`orgs/coldlogicsolutions/teams/developer`). If that succeeds, the author isn't on the team and the message says so. If it fails too, the message says the App can't read the team and names the organization permission Members: read, which is the case today (#119), and adds that GitHub may be unreachable. gh's own error line from the first read stays on stderr.

The organization and team are constants in the script. No environment variable overrides them.

Alternatives rejected:

- **One generic message for any failure.** Until #119 lands every call fails this way, and "not a member" would send people looking in the wrong place.
- **Read the permission from the 403/404 body.** Both reads answer a plain 404 today.
- **`GH_APP_APPROVE_TEAM`, like `GH_APP_APPROVER`.** A variable a session can set in front of the command is a way to point the check at a team the author is on. The guard gives no allow to a command with a variable in front, but a constant needs no such argument.
- **Require the repository's owner to be `coldlogicsolutions`.** The App's token comes from that organization's installation, so a PR elsewhere fails at GitHub when the approval is sent.
- **Cache the membership.** It must be true when the approval is made.

### 5. The App's review on the head: stricter than "the last one"

The wrapper lists the App's own reviews on the head commit that aren't pending, oldest first. It refuses when there is none. It refuses when the last one that is an approval or a change request is a change request. It succeeds without sending anything when that one is an approval. Otherwise the last review of all must be a comment review.

The decision given with the task was: the App's last submitted review on the head is a comment review or an approval. This rule passes nothing that one refuses, and refuses one more case: **a change request followed by a comment review**. A reply in a review thread is submitted as a comment review, so under "the last one" the App could request changes, answer a thread, and approve without reviewing again. A change request now stands until it is dismissed (its state becomes `DISMISSED`) or new commits move the head. This goes past the decision as given; it is the first question at the end.

A dismissed review as the last one refuses: the App reviews the commit again first.

Alternatives rejected:

- **The last review, as given.** The thread-reply case above.
- **Any review on the head.** A change request would pass.
- **Require a review newer than the head's push time.** `commit_id` equal to the head already says the review was of this commit.
- **Have the wrapper submit the review itself.** The review is the session's work; the wrapper only checks that it happened.

### 6. Pin the commit, then check the head again

The approval is sent as `POST repos/<owner>/<repo>/pulls/<n>/reviews` with `event=APPROVE` and `commit_id=<head>`. The wrapper then reads the head again. If it differs, or can't be read, it dismisses the review it just created (by the id the POST returned), says whether that worked, and exits non-zero.

What GitHub does with an approval whose `commit_id` is no longer the head is not known (see Risks). The second read makes the answer matter less: either way the approval doesn't stay.

Alternatives rejected:

- **Report the move and leave the approval.** If GitHub counts it, the PR is approved at a commit nobody reviewed.
- **No second read.** Leaves the question open, and the read costs one call.
- **Approve without `commit_id`.** GitHub then uses the current head, which may not be the commit checked.

### 7. The wrapper refuses `pr review --approve` itself

`gh-app pr review *` becomes an allow rule. If the guard hook isn't running, that rule alone would allow `gh-app pr review 5 --approve`, which today prompts. So `gh-app.sh` refuses `pr review` with any word that is `--approve...` or a short cluster holding `a`, before `gh` runs.

A body that is exactly a word like `-a` is refused too. `--body-file` avoids it.

Alternatives rejected:

- **Deny rules in `devenv.nix`** (`gh-app pr review * --approve*`). Rules match text and miss `-ab`, `-a` first, and the wrapper prefix.
- **Rely on the guard.** It is a backstop that may not be running; the allow rule is new.

### 8. The guard: one deny, and a review treated like a comment

- In the `gh` branch of `forbidden_from()`: `pr create` and `pr new` are denied, with a reason that names `gh-app pr create`. `gh_subcommand()` already skips `-R` and lowercases.
- `("pr", "review")` joins the commands `gh_opens_editor()` checks for a body, and `GH_TEXT_SUBCOMMANDS`, whose `--body` value is read as text. Without the first, a bodiless review would be allowed and then fail or wait in gh. Without the second, a body starting `-e` asks.
- The `gh-app` branch's comment and its two messages name `gh-app pr approve`. No decision there changes: `pr approve` was never denied, and still isn't.

`forbidden()` tries every word as the program, so `echo gh pr create` is denied, as `echo gh pr merge` is. A body holding the words inside one quoted argument is not.

Alternatives rejected:

- **Deny `gh api` calls that create a PR too.** Out of scope by decision.
- **A deny rule in `devenv.nix` for `gh pr create`.** Misses wrappers; the guard is where the other `gh` denies live.
- **Have the guard check `pr approve`'s arguments.** The wrapper refuses bad ones itself, before `gh` runs, and is tested for it.

### 9. Tests for `gh-app`, at build time

`packages/gh-app-test.sh` runs the raw script with `bash -o errexit -o nounset -o pipefail`, the options the built one gets, and puts stand-ins for `gh` and `gh-app-token` first on PATH. The `gh` stand-in logs each call and answers from JSON files in the case's directory, running the caller's own `--jq` filter over them with `jq`, so the script's filters are tested, not copied. Each refusal is checked for its exit code, its message, an empty stdout, and that no POST, PUT or merge was sent.

`gh-app.nix` gains the `tested` derivation and the `# Tested by` line, as `prune-worktrees.nix` has.

Alternatives rejected:

- **Test the built package.** `writeShellApplication` puts the real `gh` and `gh-app-token` ahead of PATH, so stand-ins wouldn't be reached.
- **Stand-ins that print canned filter output.** A wrong filter in the script would pass.
- **A step in `scripts/check.sh`.** The build already runs in the gate, and a build-time test also stops a broken package reaching a project.

## Risks / Trade-offs

- [GitHub may accept an approval for a commit that is no longer the head and count it] → The wrapper reads the head again and dismisses its approval when it moved. If the dismissal fails it says so and exits non-zero. Not checked live; the last task group does.
- [The App may not be allowed to dismiss its own review] → Then the message says to dismiss it by hand. The window is the moment between two API calls.
- [Until #119 lands, every `gh-app pr approve` refuses] → Intended. The message names the permission. Nothing else depends on the command yet.
- [Until infrastructure#40 lands, an App approval doesn't satisfy the ruleset] → The approval is recorded and harmless. Where a repository's rules already count any approval, the wrapper's checks are what stand between a session and an approved PR; they are the same checks either way.
- [A session pushes to a developer's branch, reviews, and has the App approve] → Accepted in #115. The developer's merge is still needed.
- [A session opens a PR as the developer through `gh api`, then has the App approve it] → Out of scope by decision. `gh api` with a field isn't allowed by any module rule, so it prompts.
- [The App's review on the head may be an empty or careless comment] → The wrapper can't judge it. The review is visible on the PR, to the developer who merges.
- [A thread reply's review may carry another `commit_id` than the head] → Then it isn't counted at all, which only makes the check stricter.
- [The stricter review rule leaves a wrong change request with no way out but a dismissal or a push] → A developer dismisses it, and the App reviews again. See the first open question.
- [`gh pr view`'s `author.is_bot` is absent in some gh version] → The check fails closed: every PR is refused as a bot's, and the tests pin that reading.
- [`gh pr create` denied where a developer really wants a PR in their own name from a session] → They run it in a terminal. The reason names `gh-app pr create`.
- [`echo gh pr create` and similar are denied] → As for `gh pr merge` today. Quote it as one argument.
- [`gh-app pr review --request-changes` now runs without a prompt] → It blocks a merge at worst, and a later approval or a dismissal clears it.
- [The first test suite for `gh-app` makes its build slower and can fail for reasons in the test] → It needs only bash, coreutils and jq, and ran in the build sandbox in the prototype.
- [`gh-app.sh` still relies on `tail` from the ambient PATH in the merge block] → Unchanged here; the new block uses only `gh` and bash.

## Migration Plan

None. Projects get the change on their next `devenv update`. It can merge before #119 and infrastructure#40. Rolling back is reverting the commit.

The live checks in the last task group need #119 and infrastructure#40 and a throwaway PR. They are tracked in an issue and don't hold the merge.

## Open Questions

Each stands alone. The plan follows the first option.

1. When the App requested changes on the head commit and then left a comment review there (a thread reply does this), should `gh-app pr approve` approve?
   - Refuse until the change request is dismissed or new commits are pushed (Recommended; this is what the plan does)
   - Approve, since the App's last review is a comment review (the decision as first given)

2. When the PR's head moves while the approval is being submitted, what should `gh-app pr approve` do with the approval it just made?
   - Dismiss it and exit non-zero (Recommended; this is what the plan does)
   - Leave it, report the move, and exit non-zero

3. Should `gh-app` itself refuse `gh-app pr review --approve`, besides the guard's deny?
   - Yes, since `gh-app pr review *` is now allowed and the guard may not be running (Recommended; this is what the plan does)
   - No, leave it to the guard
