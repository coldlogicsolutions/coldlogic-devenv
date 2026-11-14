# Tasks

Make only the edits below, at the anchors named, with Edit and Write. Don't reformat, reorder or rename anything else. Line numbers are from `0a5f90e` and may have moved; find each anchor by its text.

Three files are given whole in this change's `reference/` directory: `gh-app.sh`, `gh-app-test.sh` and `gh-app.nix`. They were built and run as they are (see design.md, "Checked by prototype"). Copy each exactly: Read the reference file, then Write the target with the same content. Don't improve them on the way. Each such task ends with a `git diff --no-index` that must print nothing. Once the copies matched, `reference/` was removed before archiving, since `packages/` holds the same files.

Never run `gh-app pr approve`, `gh-app pr review` or any `gh-app api` write to try something out. Every check here uses stand-ins or `guard.decide()`, which send nothing.

Commands:

- The wrapper's tests: `devenv shell --quiet -- bash packages/gh-app-test.sh packages/gh-app.sh`. It prints an `ok` or `FAIL` line per check and ends `N passed, M failed`.
- The guard's tests: `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed`, or a `FAIL` line per wrong case. On `0a5f90e` it prints `1977/1977 passed`.

If a count differs from the one a task gives, don't chase the number: list the `FAIL` lines and compare them with what the task says may fail. Anything else failing means this branch differs from the one the plan was checked against. Stop and report it.

## 1. `gh-app pr approve`

- [x] 1.1 Write `packages/gh-app-test.sh` with the exact content of `openspec/changes/app-approve/reference/gh-app-test.sh`. Verify: `git diff --no-index openspec/changes/app-approve/reference/gh-app-test.sh packages/gh-app-test.sh` prints nothing. Then run the wrapper's tests against today's script: it ends `50 passed, 99 failed`, and every `FAIL` line starts with a case from `(a)` to `(k)`. Every `(m)`, `(p)` and `(q)` line is `ok`: those pin how `pr merge`, other commands and a missing key behave today, and must stay `ok` after 1.2.

- [x] 1.2 Write `packages/gh-app.sh` with the exact content of `openspec/changes/app-approve/reference/gh-app.sh`. It is today's file with 181 lines added and none changed: nine header lines, a `pr review` block and a `pr approve` block, both placed before the `pr merge` block. Verify: `git diff --no-index openspec/changes/app-approve/reference/gh-app.sh packages/gh-app.sh` prints nothing; `git diff --stat packages/gh-app.sh` shows 181 insertions and no deletion; the wrapper's tests end `149 passed, 0 failed`.

  What each part protects. Don't reorder or loosen any of it:

  - **The `pr review` block.** Threat: `gh-app pr review *` is about to be an allow rule, and where the guard hook isn't running that rule alone would let `--approve` through. Invariant: no word that is `--approve...` or a short cluster holding `a` reaches `gh pr review`.
  - **`team_org`, `team`, `app_author`, `app_reviewer` are constants.** Threat: a variable set in front of the command pointing the check at another team or reviewer. Invariant: nothing in the approve block reads the environment but the token.
  - **The argument loop and the number check.** Invariant: one operand matching `^[1-9][0-9]*$`, `-R`/`--repo` only; anything else exits before the first `gh` call, so no session argument reaches `gh` as an option and no branch name or URL selects another PR than the one reviewed.
  - **The author's login is the last field of the `--jq` line.** Threat: `read` with a tab `IFS` drops an empty field and shifts the rest, so an empty login in the middle would put the head commit where `is_bot` is read. Invariant: only the last field can be empty.
  - **The URL and head patterns.** Invariant: the repository, PR number and commit that go into API paths and the request come from values of the expected shape only.
  - **`[[ "$draft" != false ]]` and `[[ "$bot" != false ]]`.** Invariant: fail closed. A missing, null or unexpected value refuses, where `== true` would approve.
  - **The login pattern, before the membership call.** Threat: a login holding `/` or `..` changing which API endpoint is read. Invariant: the login is `[A-Za-z0-9_-]+` before it is put in a path.
  - **The membership read and `!= active`.** Invariant: any failure refuses, and only the exact state `active` passes (`pending` and an empty answer refuse). The second read of the team only chooses the message; its output is discarded so nothing but the final line reaches stdout.
  - **The review loop.** Invariant: only the App's own reviews (`coldlogic-ai[bot]`), not pending, on exactly the head commit count. A change request there stands unless it was dismissed or the App's approval follows it; a later comment review (a thread reply) doesn't take it back. The last review must be a comment review, so a dismissed one refuses.
  - **`-f commit_id="$head"`.** Invariant: the approval is for the commit checked, never "whatever the head is now".
  - **The second `gh pr view` and the dismissal.** Threat: a push between the checks and the approval leaving an approval on unreviewed commits. Invariant: when the head moved, or can't be read, the approval just made is dismissed and the command fails; if the dismissal fails, the message says to do it by hand.
  - **Every path through the approve block ends in `exit`.** Invariant: `pr approve` never reaches `exec gh "$@"` at the end of the file.

- [x] 1.3 Write `packages/gh-app.nix` with the exact content of `openspec/changes/app-approve/reference/gh-app.nix`. It adds a `tested` derivation that runs the tests with only `bash`, `coreutils` and `jq`, and a `# Tested by ${tested}` line in the script's text, as `packages/prune-worktrees.nix` has. Protects: a `gh-app` that fails a case never reaches a shell. Verify: `git diff --no-index openspec/changes/app-approve/reference/gh-app.nix packages/gh-app.nix` prints nothing. The build itself is checked by the gate in group 3.

- [x] 1.4 Documentation for the wrapper, three edits. Verify each by reading the changed line back; the gate's `openspec validate` step checks the spec file.

  (a) `README.md`, the `packages/gh-app.nix` row of the table (it starts ``| `packages/gh-app.nix` | `gh-app <gh args>`: one `gh` call as``). After the sentence ending ``since GitHub then holds the merge until that approval is in.`` and before ``The key path comes from``, insert: ``` `gh-app pr approve <number> [-R owner/repo]` is the only way the App approves: it refuses unless the PR is open and not a draft, its author is a person who is an active member of the `coldlogicsolutions` `developer` team (read each time, which needs the App's organization permission Members: read), and the App has its own submitted review on the head commit with no change request of its own standing there; it pins the approval to that commit and withdraws it if the head moved meanwhile. `gh-app pr review --approve` is refused. Its cases in `gh-app-test.sh` run when it builds. ``` Keep the row on one line.

  (b) `openspec/specs/gh-app/spec.md`, the Purpose paragraph (line 4). A delta can't change a Purpose, so edit it here. Replace its last sentence, ``` `gh-app pr merge` adds checks so a session can merge only the App's own approved PRs. ```, with: ``` `gh-app pr merge` adds checks so a session can merge only the App's own approved PRs, and `gh-app pr approve` is the one way the App approves: only a developer's open PR that the App has reviewed at its head commit. ``` Change nothing else in that file; the requirements come from the delta at archive.

  (c) `scripts/check.sh`, the comment above `step "build: shell" devenv build shell`. Change `runs claude-guard's, session-relink's, prune-worktrees', claude-wrapper's,` to `runs claude-guard's, gh-app's, session-relink's, prune-worktrees', claude-wrapper's,` and re-wrap the comment at the width of the lines around it. No command changes.

## 2. The guard and the allow rules

Do 2.1 first: the rows fail until the edits after it are in, which shows they test something.

- [x] 2.1 In `packages/claude-guard-test.py`, three edits. Verify: the guard's tests end `2035/2055 passed`, with exactly 20 `FAIL` lines: one `FAIL MODULE_ALLOW differs from devenv.nix rules.Bash.allow`; 9 `FAIL Bash` lines, each a `gh pr create` or `gh pr new` command expecting `deny`; and 10 `FAIL module allow list` lines: `gh pr create --title t --body x` and `gh pr new --title t --body x` (bare and wrapped, expecting `deny`), `gh-app pr review 31 --comment` and `gh-app pr review 31` (bare and wrapped, expecting `ask`, got `allow`), and `gh-app pr review 31 --comment --body "-e is nice"` (bare and wrapped, expecting `allow`, got `ask`). Every other new row passes already: the denies for approving are not new.

  (a) In the `BASH` table, directly after the row `("gh-app pr view 12 --json mergeable,mergeStateStatus", ALLOW),` and before the comment `# From the security review.`, add:

  ```python
      # #115: a session opens PRs as the App, never with the user's
      # credentials. `new` is gh's alias for `create`.
      ("gh pr create --title x --body y", DENY),
      ("gh pr create", DENY),
      ("gh pr new --fill", DENY),
      ("gh -R o/r pr create --fill", DENY),
      ("gh pr create -R o/r --title x -b y", DENY),
      ("devenv shell --quiet -- gh pr create --fill", DENY),
      ("bash -c 'gh pr create --fill'", DENY),
      ("env GH_TOKEN=x gh pr create --fill", DENY),
      ("git status && gh pr new", DENY),
      ("gh pr view 12", NONE),
      ("gh pr comment 12 --body x", NONE),
      ("gh pr edit 12 --title x", NONE),
      ("gh issue create --title x --body y", NONE),
      ("gh repo create x", NONE),
      ("gh api repos/o/r/pulls -f title=x -f head=b -f base=main", NONE),
      ("gh-app pr create --title x --body y", NONE),
      # #115: the App approves only through `gh-app pr approve`, whose wrapper
      # checks the PR; the guard leaves it, and a review that doesn't approve,
      # to the rules.
      ("gh-app pr approve 12", NONE),
      ("gh-app pr approve 12 -R o/r", NONE),
      ("gh-app pr review 12 --comment --body x", NONE),
      ("gh-app pr review 12 --request-changes --body x", NONE),
      ("gh-app pr review 12 -ab LGTM", DENY),
      ("gh-app pr review 12 --approve=true", DENY),
      ("gh-app pr review --approve 12 -R o/r", DENY),
      ("gh-app api -X POST repos/o/r/pulls/12/reviews -f event=APPROVE -f commit_id=abc", DENY),
      ("gh-app api -X PUT repos/o/r/pulls/12/reviews/5/dismissals -f message=x", DENY),
      ("gh-app alias set approve 'pr review --approve'", DENY),
  ```

  (b) In `MODULE_ALLOW`, add one line after the line `"gh-app pr comment *", "gh-app pr create *", "gh-app pr merge *",`:

  ```python
      "gh-app pr approve *", "gh-app pr review *",
  ```

  Also change the comment above `MODULE_ALLOW` from `issues #42, #43, #61,` / `# #62, #85 and #86` to name `#115` as well: `issues #42, #43, #61, #62, #85, #86 and #115`, re-wrapped.

  (c) In the `MODULE` table, directly after the row `("gh pr merge 31 --auto --squash", DENY),` and before the comment `# #86: another repository's issues.`, add:

  ```python
      # #115: the App's approval, through the wrapper that checks the PR.
      ("gh-app pr approve 31", ALLOW),
      ("gh-app pr approve 31 -R coldlogicsolutions/claude-plugins-coldlogic", ALLOW),
      ("gh-app pr approve -R coldlogicsolutions/claude-plugins-coldlogic 31", ALLOW),
      ("gh-app pr approve 31 --repo coldlogicsolutions/claude-plugins-coldlogic", ALLOW),
      # #115: the App's reviews, with a body.
      ("gh-app pr review 31 --comment --body \"plain text\"", ALLOW),
      ("gh-app pr review 31 -c -b x", ALLOW),
      ("gh-app pr review 31 --comment --body-file \"$TMPDIR/review.md\"", ALLOW),
      ("gh-app pr review 31 -R coldlogicsolutions/claude-plugins-coldlogic --comment --body-file /private/tmp/claude-501/scratch/review.md", ALLOW),
      ("gh-app pr review 31 --request-changes --body x", ALLOW),
      ("gh-app pr review 31 --comment --body-file - <<'EOF'\nRun gh pr create, then gh pr review 31 --approve.\nEOF", ALLOW),
      ("gh-app pr review 31 --comment --body \"-e is nice\"", ALLOW),
      # With no body gh prompts or opens an editor.
      ("gh-app pr review 31 --comment", ASK),
      ("gh-app pr review 31", ASK),
      ("gh-app pr review 31 --comment --body x -e", ASK),
      ("gh-app pr review 31 --comment --body-file /etc/passwd", ASK),
      # Every approval but the wrapper's is still denied, whatever the rules.
      ("gh-app pr review 31 --approve", DENY),
      ("gh-app pr review 31 -a", DENY),
      ("gh-app pr review 31 --approve --body x", DENY),
      ("gh-app pr review --approve 31 -R o/r", DENY),
      ("gh-app pr review 31 --comment --body -a", DENY),
      ("gh-app api repos/o/r/pulls/31/reviews -f event=APPROVE", DENY),
      ("gh pr review 31 --approve", DENY),
      # #115: a session opens PRs as the App only.
      ("gh pr create --title t --body x", DENY),
      ("gh pr new --title t --body x", DENY),
      ("gh-app pr create --title t --body x", ALLOW),
      ("gh-app issue create --title t --body 'Open it with gh pr create.'", ALLOW),
  ```

- [x] 2.2 In `devenv.nix`, in `rules.Bash.allow`, directly after the line `"gh-app pr merge *"`, add the block below (same indentation as the lines around it). The order matters: the test file compares the list with `MODULE_ALLOW` element by element. Protects: the allow is safe only because of what the comment says, so the comment stays with the rules. Verify: the guard's tests end `2036/2055 passed`; the `FAIL MODULE_ALLOW differs` line is gone and the other 19 remain.

  ```nix
              # gh-app approves only an open PR by a developer team member
              # that the App has reviewed at its head commit, and refuses
              # `pr review --approve` (packages/gh-app.sh); the guard denies
              # every other way to approve.
              "gh-app pr approve *"
              "gh-app pr review *"
  ```

- [x] 2.3 In `packages/claude-guard.py`, in `forbidden_from()`, the `if head == "gh":` branch only. Replace the three comment lines that start `# The user's own credentials: merging skips the review the` and the three code lines after them (through the `gh pr merge` return) with the block below. Threat: a session opens a PR with the developer's credentials and then has the App approve it, so one session writes and approves. Invariant: `gh pr create` and its alias `gh pr new` are denied however they are wrapped (`forbidden()` already tries every word as the program, and `gh_subcommand()` skips `-R` and lowercases). Don't add `gh api` forms: out of scope by decision. Verify: the guard's tests end `2049/2055 passed`; the 6 `FAIL` lines left are the `gh-app pr review` rows named in 2.1.

  ```python
          # The user's own credentials: merging skips the review the
          # organization ruleset requires, and approving counts as that review.
          # The App's (gh-app) don't. A PR opened with them is the user's, which
          # the App may approve (`gh-app pr approve`): a session opens its PRs
          # as the App, whose PRs a developer approves. `new` is gh's alias.
          lowered = [a.lower() for a in args]
          sub = gh_subcommand(lowered)
          if sub == ("pr", "merge"):
              return "gh pr merge with your credentials skips review; the App merges approved PRs"
          if sub in (("pr", "create"), ("pr", "new")):
              return "gh pr create with your credentials opens the PR as you; open it as the App with gh-app pr create"
  ```

- [x] 2.4 In the same function, the `if head == "gh-app":` branch: comments and messages only, no decision changes. Invariant to keep: `pr review` with an approve flag, `alias`, and an `api` call that merges or reviews are still denied, before any rule; `pr approve` and `pr merge` are not mentioned in a deny. Verify: the guard's tests still end `2049/2055 passed` with the same 6 lines.

  (a) Replace the five comment lines that start `# The App may merge a PR the developer team approved, but it must not` with:

  ```python
          # The App's approval counts toward the ruleset's one required
          # approval, so it approves only through `gh-app pr approve`, and
          # merges only through `gh-app pr merge`: each wrapper checks the PR
          # first (approve: open, not a draft, a developer team member's, the
          # App's own review on its head; merge: the App's own, not a draft,
          # the ruleset, the head it was asked to merge). `pr review --approve`
          # and the API would skip that. Neither wrapper command is denied
          # here: the rules decide.
  ```

  (b) Change `return "the App approving a PR"` to `return "the App approving through gh-app pr review; approve with gh-app pr approve, which checks the PR first"`.

  (c) Change `return "the App merging or reviewing through gh-app api; merge with gh-app pr merge, which checks the PR first"` to `return "the App merging or reviewing through gh-app api; merge with gh-app pr merge and approve with gh-app pr approve, which check the PR first"`.

- [x] 2.5 In `packages/claude-guard.py`, two edits so a review is read like a comment. Protects: the new `gh-app pr review *` rule doesn't allow a call gh would prompt or open an editor for, and a body isn't taken for an option. Verify: the guard's tests end `2055/2055 passed`, with no `FAIL` line.

  (a) Replace the line `GH_TEXT_SUBCOMMANDS = {(c, s) for c in ("issue", "pr") for s in ("create", "edit", "comment")}` with:

  ```python
  GH_TEXT_SUBCOMMANDS = ({(c, s) for c in ("issue", "pr") for s in ("create", "edit", "comment")}
                         | {("pr", "review")})
  ```

  (b) In `gh_opens_editor()`, replace the docstring and the two lines after `sub = gh_subcommand(...)` so the function starts:

  ```python
  def gh_opens_editor(args):
      """Whether gh would open an editor, or prompt, for a body it isn't
      given: an issue or pull request created or commented on without one, or
      a pull request review."""
      sub = gh_subcommand([a.lower() for a in args])
      if sub not in (("issue", "create"), ("pr", "create"), ("issue", "comment"), ("pr", "comment"),
                     ("pr", "review")):
          return False
  ```

  Leave the rest of the function (`short = ...` and the `return`) as it is: a review's body options are `-b`, `--body`, `-F` and `--body-file`, which it already looks for.

- [x] 2.6 In `README.md`, the `packages/claude-guard.py` row of the table. Replace ``merges or approvals with the user's own `gh` credentials, approvals by the App and its merges through `gh-app api` (it merges through `gh-app pr merge`)`` with ``merges or approvals with the user's own `gh` credentials, `gh pr create` and `gh pr new` with them (a session opens PRs as the App, with `gh-app pr create`), and approvals by the App through `gh-app pr review --approve` and its merges and approvals through `gh-app api` (it merges through `gh-app pr merge` and approves through `gh-app pr approve`, which check the PR first)``. Keep the row on one line. Verify: the row is still one line and the new text reads back as written.

## 3. The gate

- [x] 3.1 Run `devenv shell --quiet -- openspec validate app-approve --strict` and fix anything it reports in this change's files. Verify: it reports the change valid.
- [x] 3.2 Run the gate on its own, `devenv shell --quiet -- scripts/check.sh` (to keep its output, redirect it to `"$TMPDIR/check.log"` and read that; don't pipe it). Verify: it ends `check: all passed`. `build: shell` builds `gh-app`, which runs `gh-app-test.sh` inside the build, and rebuilds the guard, which runs its tests there with no `devenv.nix` beside them (one check fewer, `2054/2054`). `shellcheck` and `nixfmt` cover the new files, the copies in `reference/` included.

## Workflow follow-up

- This change closes #115 once merged. It can merge before #119 (the App's Members: read permission) and coldlogicsolutions/infrastructure#40 (the ruleset): until both are in, `gh-app pr approve` refuses or its approval doesn't count.
- The three open questions in design.md follow their recommended option here. A different answer to the first changes the review loop in `gh-app.sh`, the `(f)` cases and one requirement in the `gh-app` delta; to the second, the block after the POST and the `(i)` cases; to the third, the `pr review` block and the `(k)` cases.
- Archive the change after review.

### Live checks (manual, tracked in an issue)

To run by hand once #119 and infrastructure#40 are in, on a throwaway PR in a repository the ruleset covers. None of them holds this change's merge.

- A developer opens a PR. `gh-app pr approve <n>` before the App has reviewed it refuses, naming the head commit.
- `gh-app pr review <n> --comment --body "..."` as the App, then `gh-app pr approve <n>`: it prints `approved`, and `gh-app pr view <n> --json reviewDecision,mergeStateStatus` shows `APPROVED` and a mergeable state. Confirm the review's `commit_id` is the head (`gh-app api repos/<owner>/<repo>/pulls/<n>/reviews`).
- Run `gh-app pr approve <n>` again: it says the PR is already approved and adds no second approval.
- Push a commit to the PR: the ruleset dismisses the approval, and `gh-app pr approve <n>` refuses until the App reviews the new head.
- `gh-app pr review <n> --request-changes --body "..."`, then reply in a review thread, then `gh-app pr approve <n>`: it refuses. Note what `commit_id` the thread reply's review carries. A developer dismisses the change request; after a new comment review, the approval goes through.
- On a PR the App opened: `gh-app pr approve <n>` refuses, and the developer's approval plus `gh-app pr merge <n> --squash` still merges it.
- On a draft, on a closed PR, and on a PR by someone outside the `developer` team (or a bot, such as a dependency update): each refuses with its own message.
- Read what `gh-app pr view <n> --json author` gives for a person and for a bot, and confirm `is_bot` and `login` are as design.md assumes.
- If it can be arranged safely: find out what GitHub does with an approval whose `commit_id` is an earlier commit than the head (design.md, Risks), and whether the App may dismiss its own review.
- In a session: `gh pr create --fill` is denied with a pointer to `gh-app pr create`; `devenv shell --quiet -- gh-app pr approve <n>` and `gh-app pr review <n> --comment --body-file "$TMPDIR/review.md"` run without a prompt; `gh-app pr review <n> --approve` is denied.
