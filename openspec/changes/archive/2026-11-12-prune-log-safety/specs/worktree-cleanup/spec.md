# Spec Delta

## MODIFIED Requirements

### Requirement: Removals are logged for good
Each run SHALL append to a log in the git common dir what it removed, with the commit and the command that restores it, and why a candidate was kept when that changed. Names and paths in a log line SHALL be shell-quoted, git errors and lock owners cleaned, so no line has a live `$( )` or backquote. A removal SHALL be logged before it is made, so a run whose log can't be used removes nothing. Trimming the log SHALL keep every removal.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A log that can't be used
- **WHEN** the log is a link, a hard link, a FIFO, a directory or a dangling link, and a run, or a `--background` run, would remove a worktree
- **THEN** nothing is removed, no detached run starts, one line is printed on stderr, the exit is 0, and a dry run still lists what would go

#### Scenario: The log unusable just before a removal
- **WHEN** the log becomes unusable after a run's checks, before it removes a worktree
- **THEN** the "removing ... to restore" line can't be written, the worktree and its branch stay for the next run, and exit is 0; a removal that then fails still gets its failure line after the logged intent

#### Scenario: The log replaced during a run
- **WHEN** another run's trim replaces the log with a new file while a run is working
- **THEN** the run's removal line is in the log at its path

#### Scenario: Free text in a kept reason
- **WHEN** a lock's owner or a git error has spaces, a newline, a `$( )` or backquotes
- **THEN** the log line shows it on one line with its spaces unescaped, and no line has a live `$( )` or backquote

#### Scenario: The same reason twice
- **WHEN** two runs keep the same branch for the same reason
- **THEN** the log has that reason once

#### Scenario: Kept twice in one run
- **WHEN** a run keeps a branch after removing its worktree, and again in its sweep of branches no worktree has
- **THEN** the log has that reason once

#### Scenario: Shell characters in a restore command
- **WHEN** a removed worktree's path has a space and its branch's name a `$( )`
- **THEN** the logged restore commands, pasted into a shell, restore both and run nothing else

#### Scenario: Shell characters in a kept reason
- **WHEN** a kept worktree's path and branch, and a kept branch with no worktree, have a `$( )` or a backquote in their names
- **THEN** their log lines name them shell-quoted, and no log line has an unquoted `$( )` or backquote

#### Scenario: A long log
- **WHEN** the log has an old removal line and more than 1000 other lines
- **THEN** after a run, the removal line is still there and only the last 1000 other lines are

## ADDED Requirements

### Requirement: The prune never writes through a link
Outside the sandbox, the command SHALL NOT write, read back or touch through a link any file in the git common dir, nor write into one that isn't a regular file of the user's with a single name: it SHALL skip that write and exit 0 (an unusable log: see "Removals are logged for good"). It SHALL make a new file only where nothing, not even a dangling link, is, and SHALL rewrite a file only through a new, unpredictably named file renamed into place.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: The log a link to another file
- **WHEN** the log is a link to a file with more than 1000 lines, and a run, then a `--background` run, would each remove a worktree
- **THEN** both remove nothing and print one line on stderr, the linked file is unchanged, and the log is still the link

#### Scenario: Dangling links
- **WHEN** the stamp and the kept file are links to paths where nothing is
- **THEN** the run prunes, nothing is made at those paths, and the kept file is replaced with a file of the run's own
- **AND WHEN** the log is such a link, **THEN** the run removes nothing, makes nothing at its path and prints one line on stderr

#### Scenario: A hard link, a FIFO or a directory as the log
- **WHEN** the log is a second name for another file, a FIFO or a directory
- **THEN** the run removes nothing, exits 0 without blocking, prints one line, and the other file is unchanged

#### Scenario: The kept file a link to an unreadable file
- **WHEN** the kept file is a link to a file the sandbox can't read, and a run is skipped for a lock over an hour old
- **THEN** the linked file is unchanged, and none of its content reaches the kept file or the log

#### Scenario: The lock's owner a link
- **WHEN** the lock's pid file is a link to a file whose first line names a live process
- **THEN** the lock counts as naming no owner, and none of the linked file's content reaches the log

#### Scenario: Hard links for the stamp and the kept file
- **WHEN** the stamp and the kept file are second names for another file
- **THEN** the run prunes, the other file's content and time are unchanged, and the stamp and kept file are replaced with files of the run's own

#### Scenario: The stamp a link
- **WHEN** the stamp is a link (or another user's file) and a `--background` run starts
- **THEN** it counts as no stamp: the run isn't skipped, and the stamp is replaced with a file of its own

#### Scenario: A rewrite that can't be made
- **WHEN** no temporary file can be made beside the log, and the log is long enough to trim
- **THEN** the run prunes, logs, leaves the log untrimmed, prints nothing and exits 0
