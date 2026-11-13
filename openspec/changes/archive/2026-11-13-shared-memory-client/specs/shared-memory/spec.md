# Spec Delta

## Purpose

Connects a project's local Claude Code sessions to the shared, self-hosted memory store, in place of Claude Code's per-machine auto memory: the server entry, what a session is shown from the store when it starts, the scope tags memories carry, and the import of existing auto memory files.

## ADDED Requirements

### Requirement: The memory store is opt-in by its URL
The module SHALL add the memory store's settings only when `COLDLOGIC_MEMORY_URL` holds a usable base URL where the shell is evaluated: `http` or `https`, a host, an optional port and path, and nothing else. Otherwise the generated files SHALL hold nothing for the store, and an unusable value SHALL produce a warning naming the variable.

Tested by: the URL and loopback cases and the settings self-check in `devenv.nix`; the gate's shell builds with each combination of the store and the switch.

#### Scenario: The variable is unset
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL` unset
- **THEN** the module adds no `memory` server to `.mcp.json`, and no memory hook, `mcp__memory__` rule, memory variable or `memory` entry in `enabledMcpjsonServers` to the settings; any of these a project sets itself is left alone

#### Scenario: Neither variable is set
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL` and `COLDLOGIC_DISABLE_AUTO_MEMORY` both unset
- **THEN** the generated settings and `.mcp.json` are the same as before this capability existed

#### Scenario: The variable is set
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL=https://memory.example.ts.net/`
- **THEN** the generated files hold the store's settings, built from `https://memory.example.ts.net`

#### Scenario: An unusable value
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL=memory.example.ts.net` or `https://user:pw@memory.example.ts.net`
- **THEN** the shell still starts, prints a warning naming `COLDLOGIC_MEMORY_URL`, and generates nothing for the store

#### Scenario: A store on this machine
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL` at `localhost`, a name under it, an address in 127.0.0.0/8 or 0.0.0.0, such as `http://127.0.0.1:8000`
- **THEN** the store is configured as for any other host, and evaluation warns that, with `allowLocalBinding` on, a session's commands may reach the store directly and bypass the ask rules on its tools

### Requirement: Sessions get the memory MCP server
When the store is configured, the generated `.mcp.json` SHALL define a server named `memory` of type `http` at `<base URL>/mcp` with no headers, and the generated settings SHALL list `memory` in `enabledMcpjsonServers` beside the servers already enabled.

Tested by: the gate's configured build; the generated files read in the change's tasks.

#### Scenario: The server entry
- **WHEN** the shell is entered with `COLDLOGIC_MEMORY_URL=https://memory.example.ts.net`
- **THEN** `.mcp.json` holds `mcpServers.memory` with `type` `http` and `url` `https://memory.example.ts.net/mcp`, and no `headers`

#### Scenario: Enabled without a prompt
- **WHEN** a session starts in that checkout
- **THEN** the `memory` server is enabled without an approval dialog, and `mcp.devenv.sh` is still enabled

### Requirement: Auto memory is turned off by its own switch
The generated settings SHALL set `autoMemoryEnabled` to `false` when `COLDLOGIC_DISABLE_AUTO_MEMORY` is exactly `1` where the shell is evaluated, whether or not the store is configured. With any other value, or unset, the module SHALL NOT set the key, so the project keeps Claude Code's built-in memory, also where the store is configured.

Tested by: the self-check in `devenv.nix`; the gate's four shell builds: `shell`, `shell (memory store)`, `(memory store, auto memory on)`, `(auto memory off)`.

#### Scenario: The switch is on
- **WHEN** a session starts in a checkout whose settings were generated with `COLDLOGIC_DISABLE_AUTO_MEMORY=1`
- **THEN** it loads no `MEMORY.md` and has no instructions to write memory files under `~/.claude`

#### Scenario: The store without the switch
- **WHEN** the settings are generated with `COLDLOGIC_MEMORY_URL` set and `COLDLOGIC_DISABLE_AUTO_MEMORY` unset
- **THEN** they hold the store's settings and no `autoMemoryEnabled` key, and a session has both the store and built-in memory

#### Scenario: The switch without the store
- **WHEN** the settings are generated with `COLDLOGIC_DISABLE_AUTO_MEMORY=1` and `COLDLOGIC_MEMORY_URL` unset
- **THEN** they hold `autoMemoryEnabled: false` and nothing for the store

#### Scenario: Another value
- **WHEN** the shell is entered with `COLDLOGIC_DISABLE_AUTO_MEMORY=0` or `true`
- **THEN** the settings hold no `autoMemoryEnabled` key

### Requirement: Sessions carry the memory configuration
The generated settings SHALL set in `env` `COLDLOGIC_MEMORY_URL` and, when the login is usable, `COLDLOGIC_MEMORY_USER` while the store is configured, and `COLDLOGIC_DISABLE_AUTO_MEMORY` while the switch is on, and none of them otherwise, so a shell a session enters evaluates the same settings as the shell that generated them.

Tested by: the self-check in `devenv.nix`; the gate's four shell builds: `shell`, `shell (memory store)`, `(memory store, auto memory on)`, `(auto memory off)`.

#### Scenario: A session started without the variable in its environment
- **WHEN** a session started from the desktop app, with no `COLDLOGIC_MEMORY_URL` of its own, runs `devenv shell` in a checkout whose settings were generated with the store configured
- **THEN** that shell generates the same `.mcp.json`, with the `memory` server

#### Scenario: The switch in a session's shell
- **WHEN** a session whose settings were generated with `COLDLOGIC_DISABLE_AUTO_MEMORY=1` runs `devenv shell`
- **THEN** that shell's evaluation of the settings matches the settings link, and no notice reports it out of date

#### Scenario: Nothing set
- **WHEN** the settings are generated with none of the three variables set
- **THEN** `env` holds none of them

#### Scenario: A login without a store
- **WHEN** the settings are generated with `COLDLOGIC_MEMORY_USER` set and `COLDLOGIC_MEMORY_URL` unset or unusable
- **THEN** `env` holds no `COLDLOGIC_MEMORY_USER`, since nothing reads it without the store

### Requirement: Memories are scoped by tags
The scope tags SHALL be `scope:project:<owner>/<repo>`, `scope:org` and `scope:user:<login>`. `<owner>/<repo>` SHALL be the last two path segments, in lower case, of the checkout's `origin` remote when it is a `<scheme>://<host>/<path>` URL (not `file://`) or an scp-style `<host>:<path>`, so every worktree and clone of a repository agrees. Any other `origin`, or one with fewer than two path segments, SHALL give no project scope.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: Remote spellings
- **WHEN** `origin` is `https://github.com/ColdLogicSolutions/coldlogic-devenv.git`, `git@github.com:coldlogicsolutions/coldlogic-devenv.git` or `ssh://git@github.com/coldlogicsolutions/coldlogic-devenv`
- **THEN** the project scope is `scope:project:coldlogicsolutions/coldlogic-devenv`

#### Scenario: A deeper path
- **WHEN** `origin` is `https://gitlab.example.com/group/coldlogicsolutions/coldlogic-devenv.git` or `git@gitlab.example.com:group/coldlogicsolutions/coldlogic-devenv`
- **THEN** the project scope is `scope:project:coldlogicsolutions/coldlogic-devenv`

#### Scenario: A host with one path segment
- **WHEN** `origin` is `https://github.com/coldlogic-devenv` or `git@github.com:coldlogic-devenv.git`
- **THEN** no project scope is recalled, rather than one with the host as its owner

#### Scenario: A local path
- **WHEN** `origin` is `/srv/git/coldlogicsolutions/coldlogic-devenv`, `file:///srv/git/coldlogicsolutions/coldlogic-devenv` or `../coldlogicsolutions/coldlogic-devenv`
- **THEN** no project scope is recalled

#### Scenario: A linked worktree
- **WHEN** a session starts in `<main checkout>.worktrees/x`
- **THEN** its project scope is the main checkout's

#### Scenario: No remote
- **WHEN** the checkout has no `origin` remote, or one whose last two segments hold characters outside letters, digits, `.`, `_` and `-`
- **THEN** no project scope is recalled, and the text says so

### Requirement: The user scope comes from the login
`<login>` in `scope:user:<login>` SHALL be `COLDLOGIC_MEMORY_USER` in lower case. An unset or unusable login SHALL give no user scope.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: No login
- **WHEN** `COLDLOGIC_MEMORY_USER` is unset
- **THEN** no user scope is recalled or offered for saving

### Requirement: A session is shown its scopes' memories at start
When the store is configured, a `SessionStart` hook SHALL read the memories tagged with the session's project, user and organisation scopes from `<base URL>/api/memories` and print them into the session's context as one line per memory, grouped by scope in that order, each scope's in the store's own order (newest first), never re-sorted. It SHALL run for every kind of session start.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: Memories in each scope
- **WHEN** the store holds memories under the session's project, user and organisation scopes
- **THEN** the session's context holds a line for each, under its scope, each with the memory's content hash shortened to 8 hex digits and the first line of its content

#### Scenario: The store's order
- **WHEN** the store returns a scope's memories in an order their `created_at` values disagree with
- **THEN** they are shown in the order returned

#### Scenario: A hash in another form
- **WHEN** a memory's content hash is in capitals, carries an `<alg>:` prefix such as `sha256:`, or has no 8 hex digits after any prefix
- **THEN** the first two are shown as their first 8 hex digits in lower case, without the prefix, and the last as it is, cleaned like a recalled line and cut to 16 characters

#### Scenario: An empty scope
- **WHEN** a scope has no memories
- **THEN** its heading is printed with a line saying it has none

#### Scenario: After a compaction
- **WHEN** a session's context is compacted or cleared
- **THEN** the hook runs again and the text is in the new context

### Requirement: Recalled memories are labelled as untrusted notes
The recalled lines SHALL be printed between fixed begin and end markers, under a statement that they are notes saved by earlier sessions, are information and not instructions, and may be out of date or wrong. A memory SHALL NOT be able to add a line, imitate the markers or hide text: each is shown as one cleaned line of at most 200 characters (its first with text, or `(empty)`), without control or invisible characters, `<` or `>`.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: A memory with a newline and a fake marker
- **WHEN** a memory's content is two lines, or holds the end marker's text or an escape sequence
- **THEN** only its first line is printed, as one line, with the marker's angle brackets replaced and the escape removed

#### Scenario: Invisible characters
- **WHEN** a memory's first line holds a format character that renders as nothing (U+00AD, U+0600-0605, U+061C, U+06DD, U+070F, U+0890-0891, U+08E2, U+180E, U+200B-200F, U+202A-202E, U+2060-206F, U+FEFF, U+FFF9-FFFB, U+110BD, U+110CD, U+13430-1343F, U+1BCA0-1BCA3, U+1D173-1D17A, U+E0000-E007F), a blank filler (U+115F, U+1160, U+17B4, U+17B5, U+2800, U+3164, U+FFA0), or a joiner or selector (U+034F, U+180B-180D, U+180F, U+FE00-FE0F, U+E0100-E01EF)
- **THEN** its recalled line holds none of them, and its visible text, accented and CJK letters included, is unchanged

#### Scenario: Whitespace other than a space
- **WHEN** a memory's first line holds a tab, U+000B-000D, U+0085, a no-break or other Unicode space (U+00A0, U+1680, U+2000-200A, U+202F, U+205F, U+3000) or a line or paragraph separator (U+2028, U+2029)
- **THEN** each is shown as a space, runs of spaces as one, and the line has no space at either end

#### Scenario: A first line with no text
- **WHEN** a memory's first lines are empty, or hold only whitespace and invisible characters
- **THEN** its recalled line is the first line that has text once cleaned; a memory with no such line, or no content, is shown as `(empty)` with its hash, and still counts as shown

#### Scenario: A long first line
- **WHEN** a memory's first line is 1,000 characters
- **THEN** its recalled line holds 200 of them and ends with an ellipsis

### Requirement: The recall text says when and how to save
Before the memories, the hook SHALL print a short text on using the store: what is worth saving, that a memory's first line is a summary, that each memory carries exactly one scope tag, the session's own scope tags with when to use each, and how to find what isn't listed. It SHALL say whether built-in auto memory is off or still on. It SHALL be printed whether or not the store answers.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: Auto memory is off
- **WHEN** the settings were generated with the store configured and `COLDLOGIC_DISABLE_AUTO_MEMORY=1`
- **THEN** the text says built-in auto memory is off and the store is the only memory

#### Scenario: Auto memory is still on
- **WHEN** the settings were generated with the store configured and the switch unset
- **THEN** the text says built-in auto memory is still on and local to this machine, and to save in the store what another project, machine or session should know

#### Scenario: The session's tags
- **WHEN** a session starts in a checkout of `coldlogicsolutions/coldlogic-devenv` with the login `derekjw`
- **THEN** the text names `scope:project:coldlogicsolutions/coldlogic-devenv`, `scope:user:derekjw` and `scope:org`

#### Scenario: The store is down
- **WHEN** the store doesn't answer
- **THEN** the text is still printed, so a session that reaches the tools later knows the scope tags

### Requirement: Recall output stays under the context cap
The hook's whole output SHALL be at most 9,000 characters. Each scope SHALL have a fixed share of it (project 4,000, user 1,000, organisation 2,000 characters). When a scope has more than fits, or more than the store returned, the hook SHALL print how many are not shown and the tag to search by.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: More memories than fit
- **WHEN** the project scope holds 300 memories with 200-character first lines
- **THEN** the output is at most 9,000 characters, the project section is at most 4,000, the newest are the ones shown, and a line gives the number not shown and `scope:project:<owner>/<repo>`

#### Scenario: A full project scope doesn't starve the others
- **WHEN** the project scope fills its share and the organisation scope holds 3 memories
- **THEN** all 3 organisation memories are shown

### Requirement: A store that is down never delays or fails a session
The hook's requests SHALL share one 3-second budget from its start, and SHALL stop at the first failed request. On a failure (no connection, a timeout, an HTTP error, a response that isn't the expected JSON) it SHALL print the scopes already fetched, then one line saying the store couldn't be reached and naming the scopes not recalled, without the error's text. It SHALL always exit 0, with nothing on stderr.

Tested by: `packages/memory-recall-test.sh` at build, on a stubbed and a real clock.

#### Scenario: The host is unreachable
- **WHEN** the first request times out
- **THEN** the hook makes no second request, prints the text and the one-line notice, and exits 0 within about 3 seconds

#### Scenario: A slow store
- **WHEN** the store takes 1.2 seconds to answer each of the three requests
- **THEN** each request is given what is left of the budget (the second under 2 seconds, the third under 1), the third times out, and the hook prints the project and user scopes, then the notice naming `scope:org`, and exits 0 within about 3 seconds of its start

#### Scenario: A later scope fails
- **WHEN** the project scope's request succeeds and the user scope's fails
- **THEN** the project scope's memories are shown in the block, no organisation request is made, and the notice after the block names the user and organisation scopes

#### Scenario: The budget nearly spent
- **WHEN** less than 0.2 seconds of the budget is left before a request
- **THEN** that request isn't made, and counts as a failure

#### Scenario: A response that isn't JSON
- **WHEN** the store answers 200 with an HTML page
- **THEN** the hook prints the notice, nothing of the page, and exits 0

#### Scenario: Not a git repository
- **WHEN** the session's directory is not in a git repository
- **THEN** the hook recalls the user and organisation scopes only and exits 0

### Requirement: The recall hook sends nothing but its queries
The hook SHALL only send `GET` requests to `<base URL>/api/memories`, with the scope tag and page size as query parameters and no credentials, and SHALL NOT follow redirects. It SHALL NOT write to the store or to the checkout.

Tested by: `packages/memory-recall-test.sh` at build.

#### Scenario: The requests made
- **WHEN** the hook runs with all three scopes
- **THEN** it makes three `GET` requests, one per scope tag, each URL-encoded, and nothing else

#### Scenario: A redirect
- **WHEN** the store answers with a redirect to another host
- **THEN** the hook doesn't follow it, and reports the store as unreachable

### Requirement: Existing auto memory files can be imported
`coldlogic-memory-migrate` SHALL import each `~/.claude/projects/<dir>/memory/*.md` file except `MEMORY.md` into the store with `POST <base URL>/api/memories`: its content, one scope tag from a table that maps a project directory or a single file to a scope, a `type:<type>` tag from its frontmatter, the tag `source:auto-memory`, and its name, description and source file as metadata. It SHALL never change or remove a file under `~/.claude`.

Tested by: `packages/memory-migrate-test.py` at build.

#### Scenario: A mapped project
- **WHEN** the table maps `-Users-x-Projects-app` to `scope:project:acme/app` and that directory holds `memory/build-notes.md` of type `project`
- **THEN** one memory is stored, tagged `scope:project:acme/app`, `type:project` and `source:auto-memory`, whose first line is the file's description

#### Scenario: A row for one file
- **WHEN** the table also maps `-Users-x-Projects-app/no-pipes.md` to `scope:org`
- **THEN** that file is stored under `scope:org` and the directory's other files under the directory's scope

#### Scenario: The files afterwards
- **WHEN** an import has finished
- **THEN** every file under `~/.claude/projects` is byte for byte what it was

#### Scenario: Scopes in capitals
- **WHEN** the table maps a directory to `scope:project:Acme/App` or `scope:user:SomeOne`
- **THEN** its files are stored under `scope:project:acme/app` or `scope:user:someone`, lower-cased (A-Z only) as the recall hook derives them; the `scope:` prefixes themselves must be lower case

#### Scenario: A repo with `.git`
- **WHEN** the table maps a directory to `scope:project:acme/App.GIT` or `scope:project:acme/lib.git.git`
- **THEN** its files are stored under `scope:project:acme/app` or `scope:project:acme/lib.git`: one trailing `.git` is dropped, as the hook drops it from `origin`, and `scope:project:acme/.git` is refused as a malformed table

#### Scenario: Windows line ends and a type in capitals
- **WHEN** a memory file has CRLF or lone CR line ends, or `type: Project`
- **THEN** its frontmatter is read as with LF, its content is stored with LF line ends and no CR, and it is tagged `type:project`

#### Scenario: Values read as Claude writes them
- **WHEN** a frontmatter value is single-quoted with `''` inside, is quoted and followed by ` # comment`, is plain and holds ` #` (`on hold until #107 lands`), or is `~`, `null` or nothing, or `metadata:` is followed by only a ` # comment`, or the file starts with a byte order mark
- **THEN** `''` is stored as `'`, the comment after the quote is dropped, the plain value is kept whole with its `#`, a null description falls back to the name, `metadata:` still opens its nested block, and the frontmatter is read as if the mark weren't there

#### Scenario: A symlinked memory file
- **WHEN** a memory directory holds a `.md` symlink, dangling or not
- **THEN** it is never followed or stored, `--list` counts it apart, a dry run and `--apply` print it as `skip (symlink, not imported)` with its own count, the other files are still listed or stored, and the exit status is non-zero
- **AND** a table row for a directory that holds only such links, as `--list` prints it, is accepted, while a row naming the link itself names no memory file

### Requirement: The import writes only when told, and only once
The command SHALL be a dry run unless `--apply` is given, listing each file's scope and outcome. With `--apply` it SHALL store nothing while a directory with memory files has no row in the table. A file whose source file and content the store holds SHALL be skipped; a source file held only with other content SHALL be a conflict, not stored. It SHALL exit non-zero on a conflict or a file it can't read or store, after trying the rest.

Tested by: `packages/memory-migrate-test.py` at build.

#### Scenario: A dry run
- **WHEN** the command runs without `--apply`
- **THEN** it sends no `POST`, and lists what it would store and under which scope

#### Scenario: An unmapped directory
- **WHEN** `--apply` is given and a directory with memory files has no row in the table
- **THEN** nothing is stored, the directory is named, and the exit status is non-zero

#### Scenario: A dry run with an unmapped directory
- **WHEN** the command runs without `--apply` and a directory with memory files has no row in the table
- **THEN** its files are listed as `unmapped` and the exit status is non-zero, as `--apply` would refuse

#### Scenario: A second run
- **WHEN** `--apply` runs twice over the same files
- **THEN** the second run stores nothing and reports each file as already imported

#### Scenario: The same source file with other content
- **WHEN** the store holds a memory with a file's source file but other content (the file was edited since, or the store's copy has no content), and none with its content
- **THEN** the file is reported as `conflict (same source_file, different content)`, nothing is stored for it, and the exit status is non-zero, in a dry run too

#### Scenario: A file without frontmatter
- **WHEN** a memory file has no frontmatter
- **THEN** it is stored with its file name as its name, its first line as its summary, and no `type:` tag

### Requirement: The import never guesses
The import SHALL report a file's state only when it knows it: a duplicate refusal (its `message`, else `detail`, says so, with a status that isn't 5xx) as its own outcome, frontmatter it can't read exactly as skipped and never stored, and every state as unknown when a dry run can't reach the store, exiting non-zero for the last two. A failed store SHALL say why. A store URL the recall hook wouldn't accept SHALL stop it before any request.

Tested by: `packages/memory-migrate-test.py` at build.

#### Scenario: Content the store already holds
- **WHEN** `--apply` stores a file whose content another memory in the store already has, and the store refuses it as a duplicate
- **THEN** the file is reported as `skip (duplicate content in store)` and counted under its own count, not as already imported, and the exit status is 0

#### Scenario: A duplicate refusal in `detail`, and a server error
- **WHEN** the store answers 409 with `{"detail":"Duplicate content"}`, or 500 with a message that mentions a duplicate
- **THEN** the first is reported as `skip (duplicate content in store)`, and the second as a failure with its message, counted as failed

#### Scenario: Unsupported frontmatter
- **WHEN** a memory file's frontmatter opens with `---` and never closes, its `description` is a block scalar (`>` or `|`) or runs on to a second line, a value's quote is never closed, text other than a ` # comment` follows a closing quote, or a double-quoted value has an escape JSON doesn't read
- **THEN** the file is reported as `skip (unsupported frontmatter: ...)`, the first as `unclosed`, nothing of it is stored (never a summary of `>` or `---`), the rest are still tried, and the exit status is non-zero

#### Scenario: A refusal without a message
- **WHEN** the store refuses a file with an answer that has no `message`
- **THEN** the failure line gives the answer's `detail` if it has one, else its HTTP status, on one line and never as `None`

#### Scenario: A dry run that can't reach the store
- **WHEN** the command runs without `--apply` and the store doesn't answer, or no store URL is given
- **THEN** every file's state is printed as unknown, none as `store`, and the exit status is non-zero

#### Scenario: An unusable store URL
- **WHEN** `--url` or `COLDLOGIC_MEMORY_URL` has credentials, a query, a fragment or a scheme other than http or https
- **THEN** the command sends no request, says the store URL is unusable, and exits 2
