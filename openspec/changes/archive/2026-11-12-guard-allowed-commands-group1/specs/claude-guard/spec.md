# Spec Delta

## ADDED Requirements

### Requirement: A devenv version or help query only reads
The guard SHALL approve a devenv version or help query, spelled exactly as the scenarios show, as a command that only reads, with no allow rule, bare or behind `devenv shell --`; devenv prints the text and exits before anything runs. Ask and deny rules SHALL still apply to it. Any other `devenv` command line SHALL be judged as before.

Tested by: `claude-guard-test.py`, the "Module allow list" block.

#### Scenario: The version query
- **WHEN** a session runs `devenv --version`, `devenv -V` or `devenv version`, or `devenv shell --quiet -- devenv --version`, and no rule names any of them
- **THEN** the guard allows it

#### Scenario: The help query
- **WHEN** a session runs `devenv --help`, `devenv -h`, `devenv help`, `devenv shell --help`, `devenv tasks -h` or `devenv help shell`, bare or wrapped, and no rule names any of them
- **THEN** the guard allows it

#### Scenario: Help with anything more, or for no subcommand
- **WHEN** a session runs `devenv --help shell`, `devenv shell --help extra`, `devenv shell --help -- rm -rf x`, `devenv -q shell --help` or `devenv --hel`
- **THEN** the guard asks; `devenv bogus --help`, `devenv help bogus` and `devenv help shell extra` get no allow

#### Scenario: In a chain or a pipeline
- **WHEN** an allow rule covers `git status *` and a session runs `devenv --version && git status` or `devenv --version | head -1`
- **THEN** the guard allows it

#### Scenario: An ask or deny rule
- **WHEN** the ask rules list `devenv *`, or the deny rules do, and a session runs `devenv --version`
- **THEN** the guard asks, or denies it

#### Scenario: Anything after the option
- **WHEN** a session runs `devenv --version shell -- rm -rf x`, `devenv --version extra` or `devenv --quiet --version`
- **THEN** the guard asks, as it does for any devenv option it doesn't know

#### Scenario: A forbidden command after the option
- **WHEN** a session runs `devenv -V shell -- git push --force`
- **THEN** the guard denies it

#### Scenario: Another spelling of the program or the option
- **WHEN** a session runs `/nix/store/x/bin/devenv --version` or `devenv --versio`
- **THEN** the guard asks

#### Scenario: Other subcommands
- **WHEN** a session runs `devenv update`, `devenv up`, `devenv version extra` or `devenv shell --quiet -- rm -rf build`
- **THEN** the guard returns no allow

#### Scenario: With another command or a redirect
- **WHEN** a session runs `devenv --version; rm -rf build` or `devenv --version > out.txt`
- **THEN** the guard returns no allow for the first and denies the second as a write to a project file

### Requirement: The module's allowed commands are allowed bare and wrapped
Against the allow list the module ships, the guard SHALL allow the routine forms of each command reported in issues #42, #43, #61, #62, #85 and #86, run bare and run behind `devenv shell --quiet --` alike. Its tests SHALL hold a copy of that list and fail when the copy differs from `devenv.nix` in a run from the checkout, the gate's; the package build has no `devenv.nix` to compare.

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

#### Scenario: A comment on another repository's issue
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue comment 49 -R coldlogicsolutions/coldlogic-devenv --body-file` and an absolute scratch path, or the same with a plain `--body`
- **THEN** the guard allows it

#### Scenario: A cd before the command
- **WHEN** a session runs `cd /Users/x/Projects/infrastructure && devenv shell --quiet -- gh-app issue comment 78 -R coldlogicsolutions/coldlogic-devenv --body x`
- **THEN** the guard returns no allow

#### Scenario: A gh function, bare and behind the wrapper
- **WHEN** a session runs `gh() { devenv shell --quiet -- gh-app "$@"; }` and then `gh pr merge 55 --auto --squash`
- **THEN** the guard asks; with `devenv shell --quiet -- ` before the definition, which wraps only its first line, the guard can't read the call, and its rough reading denies it for `gh pr merge`
