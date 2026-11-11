# gh-app Specification

## Purpose
`gh-app` runs one GitHub CLI command as the coldlogic-ai App rather than the owner's account, so sessions open PRs and issues and comment as `coldlogic-ai[bot]`. `gh-app pr merge` adds checks so a session can merge only the App's own approved PRs.

## Requirements

### Requirement: Commands run as the App
`gh-app <args>` SHALL mint an installation token for the coldlogic-ai App, export it as `GH_TOKEN` (never passing it in argv), and run `gh <args>`. Every developer shell SHALL provide `gh-app`.

Tested by: none; `writeShellApplication` runs shellcheck on both scripts at build time.

#### Scenario: Opening an issue
- **WHEN** a session runs `gh-app issue create --title foo`
- **THEN** the issue is created by `coldlogic-ai[bot]`

### Requirement: A missing key fails clearly
`gh-app` SHALL read the App's private key from `GH_APP_KEY`, defaulting to `~/.config/github/coldlogic-ai.pem`. When the file is missing it SHALL print an error naming the path on stderr, print nothing on stdout, and exit non-zero.

Tested by: none.

#### Scenario: No key
- **WHEN** `~/.config/github/coldlogic-ai.pem` doesn't exist and `GH_APP_KEY` is unset
- **THEN** `gh-app pr view 1` exits non-zero with `gh-app: private key not found at ...` on stderr

### Requirement: Installation tokens are minted from a short-lived JWT
`gh-app-token` SHALL sign an RS256 JWT for the App's client ID (`GH_APP_CLIENT_ID`, with a built-in default) that is valid for about ten minutes. It SHALL look up the `coldlogicsolutions` installation and print a fresh installation access token. A failed mint SHALL exit non-zero. When GitHub lists no matching installation or rejects the token request, it SHALL show GitHub's response; a rejected installation lookup (bad JWT, client ID or key) currently exits with only a jq error.

Tested by: none.

#### Scenario: Successful mint
- **WHEN** the key is present and the App is installed on `coldlogicsolutions`
- **THEN** `gh-app-token` prints one token on stdout and exits 0

#### Scenario: App not installed
- **WHEN** the App has no installation on `coldlogicsolutions`
- **THEN** `gh-app-token` exits non-zero and prints GitHub's response on stderr

### Requirement: The installation id is cached safely
`gh-app-token` SHALL cache the installation id in `${GH_APP_CONFIG_DIR:-${XDG_CACHE_HOME:-~/.cache}/coldlogic-ai}/installation`, never in the key's directory. It SHALL ignore a cached value that is a symlink or isn't a number. A cache it can't write SHALL only produce a warning.

Tested by: none.

#### Scenario: Tampered cache
- **WHEN** the cache file holds `1/../../x`
- **THEN** `gh-app-token` ignores it and looks the installation up again

#### Scenario: Read-only cache directory
- **WHEN** the cache directory can't be written
- **THEN** `gh-app-token` warns on stderr and still prints a token

### Requirement: Merges are limited to the App's own approved PRs
`gh-app pr merge` without `--auto` SHALL refuse `--admin`, a PR the App didn't open, a draft, and a PR whose head commit the approver (`GH_APP_APPROVER`, default `derekjw`) didn't approve in their last deciding review. It SHALL merge only that head commit, passing `--match-head-commit`.

Tested by: none.

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

### Requirement: Auto-merge needs a ruleset that requires approval
`gh-app pr merge --auto` SHALL skip the approval check. It SHALL still apply the author, draft and head-commit checks, and SHALL refuse unless the base branch's rules require at least one approval and dismiss stale approvals on push. It SHALL fail closed when the rules can't be read. `--disable-auto` alone SHALL pass straight to `gh`.

Tested by: none.

#### Scenario: Auto-merge on a protected branch
- **WHEN** a session runs `gh-app pr merge --auto --squash 12` on the App's PR against a `main` whose ruleset requires an approval that a push dismisses
- **THEN** auto-merge is turned on, pinned to the current head

#### Scenario: Branch without the approval rule
- **WHEN** the base branch's rules don't require an approval that a push dismisses
- **THEN** it refuses and says to turn on auto-merge by hand
