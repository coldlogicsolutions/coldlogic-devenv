# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: The App merges only through gh-app pr merge and never approves`
- TO: `### Requirement: The App merges and approves only through its wrapper commands`

## MODIFIED Requirements

### Requirement: The App merges and approves only through its wrapper commands
The guard SHALL deny `gh-app pr review --approve`, its words read as gh's flag parser reads them so that an option's value doesn't approve, `gh-app alias`, and `gh-app api` calls that merge, enable auto-merge, approve or create a review. It SHALL leave `gh-app pr merge` and `gh-app pr approve` to the rules, since each wrapper checks the PR first.

Tested by: `claude-guard-test.py`, `gh-app` cases.

#### Scenario: Merge through the API
- **WHEN** a session runs `gh-app api -X PUT repos/o/r/pulls/1/merge`
- **THEN** the guard denies it

#### Scenario: Merge through the wrapper
- **WHEN** a session runs `gh-app pr merge --auto --squash 12`
- **THEN** the guard doesn't deny it

#### Scenario: Approval through the wrapper
- **WHEN** a session runs `gh-app pr approve 12` or `gh-app pr approve 12 -R o/r`
- **THEN** the guard doesn't deny it

#### Scenario: Approval through pr review
- **WHEN** a session runs `gh-app pr review 12 --approve`, `gh-app pr review 12 -ab LGTM`, `gh-app pr review 12 -ab"looks good"`, `gh-app pr review 12 -a=true`, `gh-app pr review 12 --approve=true`, `gh-app pr review 12 --body=x -a`, `gh-app pr review --approve 12 -R o/r` or `gh-app pr -R o/r review 12 --approve`, with or without an allow rule for `gh-app pr review *`
- **THEN** the guard denies it and names `gh-app pr approve`

#### Scenario: A value that looks like an approval
- **WHEN** a session runs `gh-app pr review 12 --comment` with `--body "-all good"`, `--body "--approve-ish"`, `--body -a`, `-ba`, `-Fa` or `--body x -- --approve`
- **THEN** the guard doesn't deny it

#### Scenario: Approval or dismissal through the API
- **WHEN** a session runs `gh-app api -X POST repos/o/r/pulls/12/reviews -f event=APPROVE -f commit_id=abc` or `gh-app api -X PUT repos/o/r/pulls/12/reviews/5/dismissals -f message=x`
- **THEN** the guard denies it

#### Scenario: A review that doesn't approve
- **WHEN** a session runs `gh-app pr review 12 --comment --body x` or `gh-app pr review 12 --request-changes --body x`
- **THEN** the guard doesn't deny it

### Requirement: The module's allowed commands are allowed bare and wrapped
Against the allow list the module ships, the guard SHALL allow the routine forms of each command reported in issues #42, #43, #61, #62, #85, #86 and #115, run bare and run behind `devenv shell --quiet --` alike. Its tests SHALL hold a copy of that list and fail when the copy differs from `devenv.nix` in a run from the checkout, the gate's; the package build has no `devenv.nix` to compare.

Tested by: `claude-guard-test.py`, the "Module allow list" table.

#### Scenario: Read-only git
- **WHEN** a session runs `git log`, `git log --oneline -5`, `git log --oneline | head -5`, `git log -p -1`, `git -C . log --oneline -5`, `git status` or `git diff origin/main...HEAD`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: -C naming the checkout the session is in
- **WHEN** a session at the top of the project runs `git -C <that directory> log --oneline -5` or `git -C <that directory> status`
- **THEN** the guard allows it

#### Scenario: -C naming another directory
- **WHEN** a session runs `git -C /elsewhere log`
- **THEN** the guard returns no allow

#### Scenario: A git command no rule names
- **WHEN** a session runs `git show HEAD`, `git blame README.md` or `git rev-parse HEAD`
- **THEN** the guard returns no allow

#### Scenario: Issues and pull requests as the App
- **WHEN** a session runs `gh-app issue view 42 --json title,body,comments`, `gh-app issue list --state open --search guard`, `gh-app pr list`, or `gh-app issue create --title t` with a single-quoted multi-line `--body`, a plain double-quoted one, `--body-file "$TMPDIR/body.md"` or `--body-file` and an absolute scratch path, bare or wrapped
- **THEN** the guard allows it

#### Scenario: A body the shell would expand
- **WHEN** a session runs `gh-app issue create --title t --body` with a double-quoted body holding a backtick-quoted `git status` or `$HOME`, or a body written as `"$(cat <<'EOF' ... EOF)"`
- **THEN** the guard returns no allow; with `gh pr merge 5` between the backticks it denies the call, since the shell would run it

#### Scenario: A body on stdin that quotes forbidden commands
- **WHEN** a session runs `gh-app issue create --title t --body-file - <<'EOF'` with a body `Run gh pr merge 55 --auto --squash, then git push --force.`, alone or with `2>&1 | grep 'https://'` after the opener
- **THEN** the guard allows it

#### Scenario: Auto-merge as the App
- **WHEN** a session runs `gh-app pr merge 31 --auto --squash`, `gh-app pr merge 31 -R coldlogicsolutions/claude-plugins-coldlogic --auto --squash` or `gh-app pr merge --auto --squash 31`, bare or wrapped
- **THEN** the guard allows it, and still denies `gh pr merge 31 --auto --squash`

#### Scenario: Approval as the App
- **WHEN** a session runs `gh-app pr approve 31`, `gh-app pr approve 31 -R coldlogicsolutions/claude-plugins-coldlogic`, `gh-app pr approve -R coldlogicsolutions/claude-plugins-coldlogic 31` or `gh-app pr approve 31 --repo coldlogicsolutions/claude-plugins-coldlogic`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: A review as the App
- **WHEN** a session runs `gh-app pr review 31 --comment` or `--request-changes` with a plain `--body`, `--body-file "$TMPDIR/review.md"`, `--body-file` and an absolute scratch path, or `--body-file - <<'EOF'` with a body that quotes `gh pr create` and `gh pr review 31 --approve`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: An approving review as the App
- **WHEN** a session runs `gh-app pr review 31 --approve`, `gh-app pr review 31 -a`, `gh-app pr review 31 --approve --body x` or `gh-app pr review --approve 31 -R o/r`, bare or wrapped
- **THEN** the guard denies it, though `gh-app pr review *` is allowed

#### Scenario: A comment whose body looks like an approval
- **WHEN** a session runs `gh-app pr review 31 --comment --body -a` or `gh-app pr review 31 --comment --body "-all good"`
- **THEN** the guard allows it

#### Scenario: A pull request opened as the App or as the user
- **WHEN** a session runs `gh-app pr create --title t --body x`, and then `gh pr create --title t --body x` or `gh pr new --title t --body x`, bare or wrapped
- **THEN** the guard allows the first and denies the other two

#### Scenario: A comment on another repository's issue
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue comment 49 -R coldlogicsolutions/coldlogic-devenv --body-file` and an absolute scratch path, or the same with a plain `--body`
- **THEN** the guard allows it

#### Scenario: A cd before the command
- **WHEN** a session runs `cd /Users/x/Projects/infrastructure && devenv shell --quiet -- gh-app issue comment 78 -R coldlogicsolutions/coldlogic-devenv --body x`
- **THEN** the guard returns no allow

#### Scenario: A gh function, bare and behind the wrapper
- **WHEN** a session runs `gh() { devenv shell --quiet -- gh-app "$@"; }` and then `gh pr merge 55 --auto --squash`
- **THEN** the guard asks; with `devenv shell --quiet -- ` before the definition, which wraps only its first line, the guard can't read the call, and its rough reading denies it for `gh pr merge`

## ADDED Requirements

### Requirement: The user's gh credentials can't open a pull request
The guard SHALL deny `gh pr create` and its alias `gh pr new`, bare, behind a wrapper or in a shell's `-c`, with a reason that points to `gh-app pr create`, but not their help: `-h` or `--help` alone, gh's global options aside. A PR opened as the user is one the App may approve, so sessions open PRs as the App only. Other `gh pr` and `gh issue` commands, `gh-app pr create`, and a `gh api` call that creates a PR SHALL be judged as before.

Tested by: `claude-guard-test.py`, `gh` cases.

#### Scenario: Opening a PR as the user
- **WHEN** a session runs `gh pr create --title x --body y`, `gh pr create`, `gh pr new --fill` or `gh pr create -R o/r --title x -b y`
- **THEN** the guard denies it and names `gh-app pr create`

#### Scenario: Wrapped
- **WHEN** a session runs `devenv shell --quiet -- gh pr create --fill`, `bash -c 'gh pr create --fill'`, `env GH_TOKEN=x gh pr create --fill`, `xargs gh pr create` or `git status && gh pr new`
- **THEN** the guard denies it

#### Scenario: Named in prose or a search
- **WHEN** a session runs `echo gh pr create`, `grep -rn gh pr create README.md`, `git log --grep gh pr create` or `gh-app issue comment 5 --body gh pr create is denied`
- **THEN** the guard doesn't deny it, since gh doesn't run; `echo gh pr merge 5` is still denied

#### Scenario: Help
- **WHEN** a session runs `gh pr create --help`, `gh pr create -h`, `gh pr new --help`, `gh -R o/r pr create --help`, `gh pr create -R o/r -h`, `gh pr create -Ro/r --help` or `gh --hostname h pr create --help`
- **THEN** the guard doesn't deny it, and allows all but the `-Ro/r` form with no rule

#### Scenario: Not help
- **WHEN** a session runs `gh pr create --fill --help`, `gh pr create --title x -h`, `gh pr create -H feat --fill`, `gh pr create --title -h --body x` or `gh pr create --fill -- -h`
- **THEN** the guard denies it

#### Scenario: Opening a PR as the App
- **WHEN** a session runs `gh-app pr create --title x --body y`
- **THEN** the guard doesn't deny it

#### Scenario: Other gh commands
- **WHEN** a session runs `gh pr view 12`, `gh pr comment 12 --body x`, `gh pr edit 12 --title x`, `gh issue create --title x --body y` or `gh repo create x`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Through the API
- **WHEN** a session runs `gh api repos/o/r/pulls -f title=x -f head=b -f base=main`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Quoted in a body
- **WHEN** a session runs `gh-app issue create --title t --body 'Open it with gh pr create.'` under the module's allow list
- **THEN** the guard allows it

### Requirement: A pull request review with no body gets no allow
The guard SHALL give no allow to a `gh pr review` or `gh-app pr review` call with no `--body`, `-b`, `--body-file` or `-F`, since gh then prompts or opens an editor for a user who isn't there: it SHALL ask. The word after `--body` or `-b` SHALL be read as text, as it is for a comment, so a body that starts with a dash is not taken for an option.

Tested by: `claude-guard-test.py`, the "Module allow list" table.

#### Scenario: No body
- **WHEN** a session runs `gh-app pr review 31 --comment` or `gh-app pr review 31` and `gh-app pr review *` is allowed
- **THEN** the guard asks

#### Scenario: A body that starts with a dash
- **WHEN** a session runs `gh-app pr review 31 --comment --body "-e is nice"` and `gh-app pr review *` is allowed
- **THEN** the guard allows it

#### Scenario: An editor option
- **WHEN** a session runs `gh-app pr review 31 --comment --body x -e`
- **THEN** the guard asks

#### Scenario: A body letter inside an option's value
- **WHEN** a session runs `gh-app pr review 31 --comment -Rbob/repo`, where `-R` takes the rest of the cluster as its repository
- **THEN** the guard asks, and it allows `gh-app pr review 31 --comment -cb x`

#### Scenario: A body file outside the project and scratch
- **WHEN** a session runs `gh-app pr review 31 --comment --body-file /etc/passwd`
- **THEN** the guard asks

### Requirement: A pull request subcommand's help needs no rule
The guard SHALL allow, with no rule, bare or wrapped, `gh` or `gh-app` `pr review`, `pr approve`, `pr create` and `pr new` when `-h` or `--help` is the only other word, apart from gh's global options and, for review and approve, a PR number: help waits for nobody. A help word that is an option's value, or comes with a body or a mode, SHALL keep its decision.

Tested by: `claude-guard-test.py`, `gh` cases and the "Module allow list" table.

#### Scenario: Help for a review or an approval
- **WHEN** a session runs `gh-app pr review --help`, `gh-app pr review -h`, `gh-app pr review 12 --help`, `gh-app pr review --help 12`, `gh-app pr review -R o/r 12 -h`, `gh-app pr approve --help` or `gh-app pr approve -R o/r 12 -h`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: Help for opening a PR
- **WHEN** a session runs `gh pr create --help`, `gh pr create -h` or `gh pr new --help`, bare or wrapped
- **THEN** the guard allows it, though no rule names `gh pr create`

#### Scenario: Help with a body or a mode
- **WHEN** a session runs `gh-app pr review 12 --body -h`, `gh-app pr review 12 --help --body x`, `gh-app pr review 12 --comment --help` or `gh-app pr review -r --help`
- **THEN** the guard judges it as a review: it allows the first two, which have a body, and asks for the others, which have none

#### Scenario: Not help
- **WHEN** a session runs `gh-app pr review 12 13 --help`, `gh-app pr review x --help`, `gh-app pr review 12 --help --approve`, `gh pr create --title x --help` or `gh pr create 12 --help`
- **THEN** the guard asks for the first two and denies the rest

#### Scenario: An attached repository
- **WHEN** a session runs `gh-app pr review 12 -Ro/r --help`
- **THEN** the guard asks, since `/r` in `-Ro/r` reads as a path outside the project, as it does for any command
