# Spec Delta

## MODIFIED Requirements

### Requirement: Routine commands are allowed and destructive variants ask
The module SHALL allow `scripts/check.sh`, `openspec`, git's `status`, `diff`, `log`, `add`, `commit`, `switch`, `branch`, `worktree`, `fetch` and `rev-list`, and gh-app's `pr view|checks|create|merge|list|comment` and `issue create|view|list|comment|edit`. It SHALL ask for the forcing and discarding variants of `git switch`, `git branch` and `git worktree remove`. Project rules SHALL add to these lists.

Tested by: none for the lists; `claude-guard-test.py` tests the guard's reading of them.

#### Scenario: Forced branch deletion
- **WHEN** a session runs `git branch -D feat`
- **THEN** Claude Code asks first

#### Scenario: Project adds an allow rule
- **WHEN** a project adds `git merge *` to `claude.code.permissions.rules.Bash.allow`
- **THEN** the generated settings allow both the module's rules and `git merge *`

#### Scenario: Viewing an issue as the App
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue view 36`
- **THEN** no permission prompt appears

#### Scenario: Commenting on an issue as the App
- **WHEN** a session runs `devenv shell --quiet -- gh-app issue comment 36 --body-file "$TMPDIR/body.md"`
- **THEN** no permission prompt appears
