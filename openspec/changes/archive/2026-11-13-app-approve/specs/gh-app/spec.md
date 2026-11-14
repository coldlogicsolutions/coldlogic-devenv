# Spec Delta

## ADDED Requirements

### Requirement: The App approves only through gh-app pr approve
`gh-app pr approve <number> [-R owner/repo]` SHALL be the only way `gh-app` approves a PR. It SHALL take one PR number and a repository only, print its usage for `-h` or `--help`, refuse any other argument before running `gh`, and never pass the command to `gh`. `gh-app pr review` with `--approve` or `-a`, in any spelling gh reads, SHALL be refused before `gh` runs, pointing to `gh-app pr approve`; an option's value isn't one.

Tested by: `gh-app-test.sh`, cases (a), (a2), (b), (b2) and (k).

#### Scenario: An approval
- **WHEN** a session runs `gh-app pr approve 12` on a PR that passes every check below
- **THEN** the App's approving review is submitted on PR 12, and the command prints the PR's URL and head commit and exits 0

#### Scenario: Another repository
- **WHEN** a session runs `gh-app pr approve 12 -R coldlogicsolutions/r`, `gh-app pr approve -R coldlogicsolutions/r 12`, `gh-app pr approve 12 -Rcoldlogicsolutions/r` or `gh-app pr approve --repo=coldlogicsolutions/r 12`
- **THEN** PR 12 of `coldlogicsolutions/r` is checked and approved

#### Scenario: An argument it doesn't take
- **WHEN** a session runs `gh-app pr approve` with no number, `abc`, `0`, a URL, two numbers, `12 --body x`, `12 --admin`, or `12 -R` with no repository
- **THEN** it exits non-zero with a message on stderr, and `gh` is never run

#### Scenario: Help for pr approve
- **WHEN** a session runs `gh-app pr approve --help`, `gh-app pr approve 12 -h` or `gh-app pr approve abc --help`
- **THEN** it prints its usage on stdout and exits 0, with no key read, no token minted, and `gh` never run

#### Scenario: Help as the repository
- **WHEN** a session runs `gh-app pr approve 12 -R -h` or `gh-app pr approve 12 --repo=`
- **THEN** it refuses, saying `-R` needs a repository, prints no usage, and `gh` is never run

#### Scenario: Approval through pr review
- **WHEN** a session runs `gh-app pr review 12 --approve`, `-a`, `-ab LGTM`, `-ab"looks good"`, `-a=true`, `--approve=true` or `--body=x -a`
- **THEN** it refuses, names `gh-app pr approve`, and `gh` is never run

#### Scenario: A value that looks like an approval
- **WHEN** a session runs `gh-app pr review 12 --comment` with `--body "-all good"`, `--body -a`, `-ba`, `-F -a` or `--body x -- --approve`
- **THEN** `gh` gets the arguments as given

#### Scenario: A review that doesn't approve
- **WHEN** a session runs `gh-app pr review 12 --comment --body x` or `gh-app pr review 12 --request-changes --body x`
- **THEN** `gh` gets the arguments as given

### Requirement: A review names its kind
`gh-app pr review` SHALL refuse before running `gh` unless it names a review that doesn't approve: `--comment` or `--request-changes`, spelled `-c` or `-r`, in a cluster, or with a value pflag reads as true (`=1`, `=t`, `=true`), read as gh reads options. Without one gh asks which review to give, and offers to approve. `-h` or `--help` that isn't a value SHALL pass, unless it approves.

Tested by: `gh-app-test.sh`, case (k).

#### Scenario: No kind named
- **WHEN** a session runs `gh-app pr review 12`, `gh-app pr review 12 --body x`, `-c=false --body x`, `--comment=0 --body x`, `--comment --comment=false --body x`, where the last occurrence wins as in gh's parser, or `-b -c`
- **THEN** it refuses, says to give `--comment` or `--request-changes`, and `gh` is never run

#### Scenario: A kind in a cluster
- **WHEN** a session runs `gh-app pr review 12 -cb x` or `gh-app pr review 12 -r -b x`
- **THEN** `gh` gets the arguments as given

#### Scenario: Help for pr review
- **WHEN** a session runs `gh-app pr review --help`, `gh-app pr review -h` or `gh-app pr review 12 --body x --help`
- **THEN** `gh` gets the arguments as given, with no key read and no token minted

#### Scenario: Help as a value
- **WHEN** a session runs `gh-app pr review 12 --body -h`
- **THEN** it refuses as naming no kind, and `gh` is never run

### Requirement: Only the organization's PRs are approved
`gh-app pr approve` SHALL refuse a PR whose repository's owner isn't the `coldlogicsolutions` organization, compared without regard to case, before it reads any team or review: the team check means nothing for another owner's PR.

Tested by: `gh-app-test.sh`, case (o).

#### Scenario: Another owner's PR
- **WHEN** PR 12's URL is `https://github.com/o/r/pull/12`
- **THEN** `gh-app pr approve 12` refuses, naming the owner, and reads no team or review

#### Scenario: The organization's name in another case
- **WHEN** PR 12 is in `ColdLogicSolutions/r` and passes every other check
- **THEN** it is approved

### Requirement: Only an open PR by a person is approved
`gh-app pr approve` SHALL refuse a PR that is closed or merged, a draft, one the App opened, and one any other bot opened. It SHALL treat an author it can't read, or one GitHub doesn't mark as not a bot, as a bot. Each refusal SHALL name the reason on stderr, exit non-zero, and submit nothing.

Tested by: `gh-app-test.sh`, cases (c), (d) and (j).

#### Scenario: A merged PR
- **WHEN** PR 12 is merged or closed
- **THEN** `gh-app pr approve 12` refuses and says it isn't open

#### Scenario: A draft
- **WHEN** PR 12 is a draft
- **THEN** it refuses and says so

#### Scenario: The App's own PR
- **WHEN** PR 12 was opened by `coldlogic-ai[bot]`
- **THEN** it refuses, says the App doesn't approve its own PRs, and reads no team

#### Scenario: Another bot's PR
- **WHEN** PR 12 was opened by another App or bot account
- **THEN** it refuses, naming the author as a bot

#### Scenario: An author that can't be read
- **WHEN** the PR's author has no login, or a login that isn't a GitHub user name
- **THEN** it refuses, and the login is never put in an API request

### Requirement: The author must be an active developer team member
`gh-app pr approve` SHALL refuse unless the PR's author is an active member of the `coldlogicsolutions` organization's `developer` team, read from GitHub each time it runs. The organization and team SHALL be fixed, not read from the environment. Any failure to read the membership SHALL refuse. When the team itself can't be read, the message SHALL name the App's organization permission Members: read as the likely cause.

Tested by: `gh-app-test.sh`, case (e).

#### Scenario: A member
- **WHEN** the author's membership of the team has the state `active`
- **THEN** the check passes

#### Scenario: Not on the team
- **WHEN** GitHub has no membership for the author and the team can be read
- **THEN** it refuses and says the author isn't a member of `coldlogicsolutions/developer`

#### Scenario: Invited, not yet a member
- **WHEN** the author's membership has the state `pending`
- **THEN** it refuses and says the membership isn't active

#### Scenario: The App may not read teams
- **WHEN** GitHub answers 404 for the membership and for the team
- **THEN** it refuses and says the App needs the organization permission Members: read

### Requirement: The App must have reviewed the head commit
`gh-app pr approve` SHALL refuse unless the App has a submitted review of its own on the PR's head commit, and the last of them is a comment review or an approval. It SHALL also refuse while a change request of the App's there isn't followed by its approval. A dismissed review, a review by anyone else, a pending review, and a review of an earlier commit SHALL NOT count. A failure to read the reviews SHALL refuse.

Tested by: `gh-app-test.sh`, case (f).

#### Scenario: Reviewed at the head
- **WHEN** the App's only review on the head commit is a comment review
- **THEN** the check passes

#### Scenario: No review
- **WHEN** the App has no submitted review on the head commit, only one on an earlier commit, or only a pending one
- **THEN** it refuses, names the head commit, and says to review first

#### Scenario: Someone else's review
- **WHEN** only a developer has reviewed the head commit
- **THEN** it refuses

#### Scenario: The App requested changes
- **WHEN** the App's review on the head commit requests changes
- **THEN** it refuses

#### Scenario: A reply after a change request
- **WHEN** the App requested changes on the head commit and a comment review of its own follows, as a reply in a review thread creates
- **THEN** it still refuses

#### Scenario: A change request on an earlier commit
- **WHEN** the App requested changes on an earlier commit and has a comment review on the head commit
- **THEN** the check passes

#### Scenario: A dismissed review
- **WHEN** the App's only review on the head commit was dismissed
- **THEN** it refuses, as for no review, and says to review first

#### Scenario: A dismissed change request
- **WHEN** the App left a comment review on the head commit, then requested changes there, and that change request was dismissed
- **THEN** the check passes

### Requirement: The approval is pinned to the head commit checked
`gh-app pr approve` SHALL submit its approval for the head commit it checked, and no other. When the App's approval already stands on that commit it SHALL exit 0 and submit nothing. After approving it SHALL read the PR again; when the head has moved, the PR is closed or a draft, or it can't be read, it SHALL dismiss the approval it just made, say whether that worked and what to do next, and exit non-zero.

Tested by: `gh-app-test.sh`, cases (a), (g), (h) and (i).

#### Scenario: Pinned
- **WHEN** the checks pass on head commit `1111111`
- **THEN** the approval is submitted with that commit's full id

#### Scenario: Already approved
- **WHEN** the App's approval stands on the head commit
- **THEN** it says so, exits 0, and submits nothing

#### Scenario: A push while approving
- **WHEN** the PR's head is another commit after the approval is submitted
- **THEN** the approval is dismissed, and the command exits non-zero saying it was withdrawn and to review the new head before approving again

#### Scenario: Closed or made a draft while approving
- **WHEN** the PR is closed, is a draft, or can't be read after the approval is submitted
- **THEN** the approval is dismissed, and the command exits non-zero saying it was withdrawn and to approve again once the PR is open, or ready for review

#### Scenario: Approving again after a withdrawal
- **WHEN** the App's approval was withdrawn while its comment review on the same head commit stands
- **THEN** `gh-app pr approve` approves again without a new review

#### Scenario: The withdrawal fails
- **WHEN** the head moved and GitHub refuses the dismissal
- **THEN** the command exits non-zero and says to dismiss the App's review by hand

#### Scenario: GitHub refuses the approval
- **WHEN** GitHub rejects the approving review
- **THEN** the command exits non-zero and prints nothing on stdout

### Requirement: Options go after the subcommand
`gh-app` SHALL refuse an option before its command, or before the subcommand of `pr` (`gh-app pr -R o/r review 12 --approve`), where it would hide the subcommand from the checks; `-h`, `--help` and `--version` SHALL pass. These refusals, and those of `pr review` and `pr approve` by their arguments, SHALL come before the key is read or a token minted.

Tested by: `gh-app-test.sh`, cases (r) and (s).

#### Scenario: A repository before the subcommand
- **WHEN** a session runs `gh-app pr -R o/r review 12 --approve`, `gh-app pr --repo=o/r approve 12` or `gh-app -R o/r pr review 12 --approve`
- **THEN** it refuses, says to put options after the subcommand, and `gh` is never run

#### Scenario: Help
- **WHEN** a session runs `gh-app pr --help` or `gh-app --version`
- **THEN** `gh` gets the arguments as given

#### Scenario: Refused without the key
- **WHEN** the App's key is missing, or no token can be minted, and a session runs `gh-app pr review 12 --approve` or `gh-app pr approve abc`
- **THEN** it refuses by the arguments, not for the key or token, and `gh` is never run

### Requirement: gh-app's tests gate its build
The `gh-app` package SHALL run its test cases against the script when it builds, with stand-ins for `gh` and `gh-app-token` and no key, network or credentials, and SHALL fail to build when a case fails. The cases SHALL cover every refusal of `pr approve`, its success, and `pr merge`.

Tested by: `packages/gh-app.nix`.

#### Scenario: A failing case
- **WHEN** a change makes `gh-app pr approve` approve a draft
- **THEN** the developer shell doesn't build

## MODIFIED Requirements

### Requirement: Commands run as the App
`gh-app <args>` SHALL mint an installation token for the coldlogic-ai App, export it as `GH_TOKEN` (never passing it in argv), and run `gh <args>`. Every developer shell SHALL provide `gh-app`.

Tested by: `gh-app-test.sh`, case (p), with a stand-in for the token; `writeShellApplication` runs shellcheck on both scripts at build time.

#### Scenario: Opening an issue
- **WHEN** a session runs `gh-app issue create --title foo`
- **THEN** the issue is created by `coldlogic-ai[bot]`

### Requirement: A missing key fails clearly
`gh-app` SHALL read the App's private key from `GH_APP_KEY`, defaulting to `~/.config/github/coldlogic-ai.pem`. When the file is missing it SHALL print an error naming the path on stderr, print nothing on stdout, and exit non-zero.

Tested by: `gh-app-test.sh`, case (q).

#### Scenario: No key
- **WHEN** `~/.config/github/coldlogic-ai.pem` doesn't exist and `GH_APP_KEY` is unset
- **THEN** `gh-app pr view 1` exits non-zero with `gh-app: private key not found at ...` on stderr

### Requirement: Merges are limited to the App's own approved PRs
`gh-app pr merge` without `--auto` SHALL refuse `--admin`, a PR the App didn't open, a draft, and a PR whose head commit the approver (`GH_APP_APPROVER`, default `derekjw`) didn't approve in their last deciding review. It SHALL merge only that head commit, passing `--match-head-commit`.

Tested by: `gh-app-test.sh`, case (m).

#### Scenario: Someone else's PR
- **WHEN** a session runs `gh-app pr merge 12 --squash` on a PR opened by a person
- **THEN** it refuses, naming the author

#### Scenario: Approved before the last push
- **WHEN** the approver's last approval is on an earlier commit than the head
- **THEN** it refuses, naming the head commit

#### Scenario: Admin override
- **WHEN** a session passes `--admin`
- **THEN** it refuses before running `gh` (it has already minted its token)

#### Scenario: Head moved since the check
- **WHEN** `--match-head-commit` names a commit other than the PR's head
- **THEN** it refuses

#### Scenario: The App's own approval
- **WHEN** only the App has approved the App's PR at its head commit
- **THEN** it refuses: the App's approval is not the approver's

### Requirement: Auto-merge needs a ruleset that requires approval
`gh-app pr merge --auto` SHALL skip the approval check. It SHALL still apply the author, draft and head-commit checks, and SHALL refuse unless the base branch's rules require at least one approval and dismiss stale approvals on push. It SHALL fail closed when the rules can't be read. `--disable-auto` alone SHALL pass straight to `gh`.

Tested by: `gh-app-test.sh`, case (m).

#### Scenario: Auto-merge on a protected branch
- **WHEN** a session runs `gh-app pr merge --auto --squash 12` on the App's PR against a `main` whose ruleset requires an approval that a push dismisses
- **THEN** auto-merge is turned on, pinned to the current head

#### Scenario: Branch without the approval rule
- **WHEN** the base branch's rules don't require an approval that a push dismisses
- **THEN** it refuses and says to turn on auto-merge by hand
