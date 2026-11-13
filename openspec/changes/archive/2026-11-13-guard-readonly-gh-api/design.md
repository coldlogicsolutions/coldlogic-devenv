# Design

## Context

See proposal.md for the motivation. What follows is what was checked against the code on this branch (`b53d4b6`) and what is assumed.

**Checked in the code:**

- No allow rule names `gh-app api` (`devenv.nix`, `rules.Bash.allow`), so a read falls through to Claude Code's prompt. `decide()` returns no decision for `gh-app api repos/o/r/pulls/12`.
- `approved()` is the only caller of `read_only()`, and it runs `plain_args()` first. `read_only()` already takes one command that is not in `READ_ONLY`: `devenv_query()`, added by the archived change `2026-11-12-guard-allowed-commands-group1`.
- `decide()` checks, in this order: `forbidden()` and `secret_named()` for every command, deny rules, ask rules, and only then the allow. So a deny or ask rule beats anything this change approves.
- `forbidden_from()` for `gh-app api` denies a merge or a review (`api_changes_review()`), then raises `Unparsable`, which asks, when the joined arguments hold `--input`, `=@` or a word starting `@`.
- `plain_args()` refuses any word that `outside()` calls a path out of the project, which a leading-slash endpoint is. It also refuses, for `gh` and `gh-app`, any word matching `^-[A-Za-z]*e` as an editor option, which `-Xget`, `-fstate=open` and `-Fquery=@...` match.
- `reads_environment()` checks `--jq` and `--template` for `env`, but skips the short `-q` and `-t` when the subcommand is `api`.
- `option_values()` doesn't split `key=@path`, and `names_file()` doesn't take `query=@.env` for a file name, so `secret_named()` doesn't see a secrets file given as a field.
- `packages/gh-app.sh` ends `exec gh "$@"` for every subcommand but `pr merge`, so `gh api`'s manual applies to `gh-app api` unchanged.

**Checked by prototype.** A scratch copy of the guard with the edits in tasks.md, written out in full there, was run through `decide()`:

- The existing test file passes except two rows, `gh-app api repos/o/r/pulls/1/merge` and `gh-app api repos/o/r/pulls/12/reviews`, which move from no decision to allow. Both are GETs. Task 1.1 flips them.
- The new block in tasks.md, 316 checks, passes as written. Against the unmodified guard 135 of them fail, each a row this change moves.
- With `{"allow": ["gh-app api *"]}` in the policy, a POST to a leading-slash endpoint moves from ask to allow. That is the endpoint decision below, applied to a project's own rule.

**Checked in gh's manual** (`cli.github.com/manual/gh_api`): the option list; the default method is GET, and POST once a field is given; `--method GET` sends fields in the query string; `-F` reads a value starting `@` from that file and `@-` from standard input; `--input` reads the body from a file; for the `graphql` endpoint every field but `query` and `operationName` is a variable.

**Assumed, not checked** (no `gh-app api` call was run for this plan):

- gh takes no abbreviation of a long option, takes `-X=GET` and `-iXGET`, compares the method without regard to case, and treats only the exact endpoint `graphql` as GraphQL. This is from memory of gh's source. Where the guard and gh could differ, the guard takes the stricter reading: an abbreviation, `--flag=true` and `--` get no allow, and any other spelling of `graphql` gets no allow.
- GitHub serves GraphQL only by POST. The guard gives no allow to a GET on `graphql` either way.
- gh's jq can read the environment (`env`, `$ENV`). The guard already assumes so for `--jq`.

Constraints: the guard is a backstop for mistakes, not a boundary against an attacker (the team's standing policy), so this plan doesn't chase exotic bypasses. `devenv.nix` is not touched. Derek's five decisions, given with the task, are taken as settled: the query file may be in scratch or the project and never a secrets file; fields are allowed with an explicit GET or HEAD; the list of options that keep or lose the allow; a leading-slash endpoint is allowed; `gh-app` only.

## Goals / Non-Goals

**Goals:**

- A read through `gh-app api`, REST or GraphQL, runs with no prompt and no rule, bare and wrapped, alone or in a chain or pipeline.
- Nothing that writes is approved by this path: any other method, a field that turns a GET into a POST, a mutation, a request body.
- The call stays on GitHub's API as the App, and can't print the App's token.
- The merge and approval denies come first and also see a query file's text.
- No decision moves from deny to anything weaker.

**Non-Goals:**

- The user's own `gh api`. It is judged exactly as today.
- An allow rule in `devenv.nix`, or any change to `MODULE_ALLOW`.
- Narrowing a project's own `gh-app api *` rule. A project that adds it has allowed writes; the guard still denies merges and approvals.
- `$TMPDIR` inside a word. The strict reader takes `$TMPDIR` only at a word's start, so `-F query=@$TMPDIR/q.graphql` gets no allow. The absolute scratch path works.
- The existing deny of an endpoint with a secrets name or a `secrets` segment (`repos/o/r/contents/.env`, `repos/o/r/actions/secrets`). The second is a false deny, and it is the same before and after this change. The test block pins both.
- `submitPullRequestReview` and other approval paths `api_changes_review()` doesn't name. They are mutations, so they get no allow here; whether they should be denied is a separate matter.
- A full GraphQL parser.
- Closing the window between the guard reading a query file and gh reading it. Derek accepted it.

## Decisions

### 1. A predicate in the guard, not an allow rule

`gh_api_reads(words)` is true for a `gh-app api` call that only reads, and `read_only()` returns true for it, beside `devenv_query()`. No rule is added.

Alternatives rejected:

- **`gh-app api *` in `devenv.nix`.** The researcher checked it: `decide()` then allows a DELETE, a POST with `-f`, a mutation, `--hostname` and a full URL.
- **Narrower rules** (`gh-app api repos/*`, `gh-app api graphql -f query=*`). A rule matches text, so it can't see a `-X DELETE` or a `-f` later in the line, or what a query holds.
- **Add `gh-app` to `READ_ONLY`.** That set is matched by program name alone in `stage_kind()` and `data_consumer()`, so every `gh-app` command would count as a read-only pipeline stage.
- **An ask rule for the writes plus an allow rule for the rest.** Ask rules would have to list every method spelling and every field flag, and would still miss a mutation.

### 2. One strict reader of the option line, shared by three callers

`gh_api_call(args)` returns the endpoint and the options, in order and under their long names, or `None` when the line isn't one it reads in full: `api` isn't the first word after the program, an option isn't on its list, a value is missing, or there isn't exactly one operand. It reads `--name value`, `--name=value`, `-X value`, `-Xvalue`, `-X=value` and a cluster (`-iXGET`).

Three callers use it: the predicate, `forbidden_from()` (decisions 5 and 6) and `plain_args()` (decision 7). Where it returns `None`, each caller behaves as today.

Alternatives rejected:

- **Regexes over the joined text**, as `api_changes_review()` uses. Fine for a deny, where a false match only costs a prompt. For an allow, `-f` hidden in a cluster or a value that looks like an option would be approved wrongly.
- **Reuse `listed_options()`.** It returns operands only, not the values, and takes no `=` after a short option.
- **Guess at unknown options.** An unknown option may take a value, so the next word may or may not be the endpoint. The reader gives up instead, and the call prompts.

### 3. What counts as a REST read

No method, or every `--method` given is GET or HEAD in any case. No `--input`. Fields only when a method is given, since gh turns a bare `-f` into a POST. No `-F` value starting `@`.

HEAD with fields sends them as a body, which GitHub ignores; HEAD changes nothing either way. Derek's decision 2 covers both.

The endpoint must not hold `://`, and an endpoint that is `graphql` in another spelling (`/graphql`, `GraphQL`) gets no allow, so a mutation can't reach the GraphQL endpoint as a "REST GET with fields".

Alternative rejected: **a list of endpoints known to be safe.** GET and HEAD are safe by HTTP's own rules, and a list would prompt for every endpoint it missed.

### 4. What counts as a GraphQL read

The endpoint is exactly `graphql`; no method, or POST; at least one field whose key is `query`; and no such document holds a mutation. `graphql_reads(text)` drops block strings, strings and `#` comments in one left-to-right pass, gives up if a `"` is left or the braces don't balance, and then looks for the word `mutation`, in any case, outside every brace. An operation can only start there, so a field alias, an argument, a variable (`$mutation`) or a directive (`@mutation`) named so doesn't count. Every `query` field given must pass, since gh keeps the last.

False refusals, each costing only a prompt: an operation named `mutation`, or an enum default of that name in the variable list.

Alternatives rejected:

- **Search the whole text for `mutation`.** A comment, a string or an alias holding the word would prompt, and the researcher's finding was that the brace-depth rule is enough.
- **A real GraphQL parser.** A dependency or a few hundred lines, for the same answer on every document a session writes.
- **Also refuse `subscription`.** GitHub's API doesn't serve them, and one changes nothing.

### 5. The query file: read it, and ask where it can't be read

`gh_query_file(path)` returns the file's text when the path is absolute and in scratch (`scratch()`), or resolves inside the project (`resolve()`, which needs the session's directory), and it is a regular file of at most 65536 bytes that decodes as UTF-8. Otherwise `None`.

In `forbidden_from()`, for a `gh-app api` line read in full, a `-F`/`--field` value `query=@path` on the `graphql` endpoint is read. Its text goes to `api_changes_review()` on its own, so a merge or a review in the file is denied. A file that can't be read raises `Unparsable`, which asks, as every `@` does today. The predicate reads the same file and applies `graphql_reads()`.

The file's text is checked against `api_changes_review()` alone, not joined to the command's words. Joined, the REST half of that check would deny any query file holding the text `/reviews`, since `-F ` is on the line.

Alternatives rejected:

- **Keep asking for every `@`.** It is the form sessions use for a query too long or too awkward to quote, which is the case #110 is about.
- **Allow `query=@file` without reading it.** The file could hold a mutation, or a merge.
- **Read any `-F key=@file`.** Only the query decides what the call does; any other file is data gh uploads, and the guard has no rule for what may be uploaded.
- **Read from `@-`.** Standard input is a heredoc or a pipe, which the strict reader handles separately. No reported need.
- **Thread the directory a `cd` leads to into `forbidden()`.** A call with a `cd` gets no allow from the guard anyway. See the risk below.

### 6. On a line read in full, only `--input` and an `@` field value name a file

Today any ` @` or `=@` in the joined arguments asks. That catches `--jq '... | @tsv'`, which `gh-app.sh` itself uses, and a GraphQL `@include`. The prototype showed both asking, so without this the commonest jq output format would still prompt.

Where `gh_api_call()` reads the line, `forbidden_from()` asks only for `--input` and for a `-f`/`-F` value starting `@` that isn't a query file it has read. A raw field (`-f key=@x`) sends the text as written, but it keeps asking: a session that writes it most likely meant `-F`. Where the line isn't read in full, today's text check stays.

This goes one step past the brief, which narrowed the ask only for `query=@file`. It is in because the manual names exactly those two ways to read a file, and the alternative leaves a prompt on a read that reads nothing local.

In the same pass, a `-F`/`--field` value `@path` that `secret_path()` calls a secrets file is denied, for any key and any endpoint. gh would upload it. Today such a call asks.

Alternative rejected: **deny the secrets file in `secret_named()`**. `forbidden()` runs first and would already have raised.

### 7. The endpoint is not a path, and an API line has no editor option

In `plain_args()`, for `gh-app` with a line `gh_api_call()` reads, the word equal to the endpoint skips the `outside()` check, and the editor-option check is skipped for the whole line. `gh api` has no editor option, and the check's regex matches `-Xget`, `-fstate=open` and `-Fquery=@...`.

Both apply to any `gh-app api` line read in full, not only a read, so a project's own `gh-app api *` rule also takes a leading slash. The secrets check on the endpoint is untouched.

Alternatives rejected:

- **Exempt only inside the predicate.** `plain_args()` runs before `read_only()` in `approved()`, so the predicate never gets the chance.
- **Tell sessions to drop the slash.** GitHub's REST documentation writes every endpoint with it.

### 8. No allow, not an ask, for what the predicate refuses

`--hostname`, a full URL, `--verbose`, another header, a method that writes, a mutation: the predicate is false and the guard returns no decision, as it does for these calls today. With no rule naming `gh-app api`, Claude Code prompts. Derek's decision 3 says "ask", and a prompt is what happens.

An explicit `ask` would differ only for a project that adds its own `gh-app api *` rule: it would then be asked about calls its rule allows. The guard doesn't narrow a project's rules elsewhere, and `--input` and an unread `@` keep their explicit ask.

The `env` check on `-q`, `-t`, `--jq` and `--template` values is in the predicate, from the parsed options. `reads_environment()` is left alone: it serves every `gh` and `gh-app` subcommand, where `-t` is a title.

### 9. Tests: one appended block, bare and wrapped

The block goes at the end of `claude-guard-test.py`, above `total = checks`. It reuses `MODULE_ALLOW` and `module_policy` from the block above it, so every row is judged against the module's real rules, and runs each row bare and behind `devenv shell --quiet --`. A second list covers other policies (an ask rule, a deny rule, a project's own allow rule). A third runs in a temporary directory with real query files.

The temporary directory is itself in scratch, so an absolute path into the test's "project" takes the scratch branch of `gh_query_file()`. The relative paths take the project branch, and `@/etc/hosts` covers a path in neither.

Alternative rejected: **rows in the `MODULE` table.** It has no place for files or other policies, and three lists in one block read better than rows spread over three.

## Risks / Trade-offs

- [A session can read, with no prompt, anything on GitHub the App's installation can read: other private repositories, review bodies, file contents] → That is the request in #110. `gh-app pr view` and `gh-app issue view` with `-R` already read across repositories. The App's permissions and installation scope are the boundary. A project that wants the prompt back adds `gh-app api *` to its ask rules, and the tests pin that it wins.
- [What a read returns enters the session's context, and may hold text written by anyone who can comment on a repository] → Same as `gh-app issue view` today. Nothing the guard approves here can act on it.
- [A GET that has a side effect on GitHub] → GET and HEAD are safe by HTTP's rules, and GitHub's API follows them. None is known.
- [The query file changes between the guard's read and gh's] → Accepted by Derek. It needs a second writer racing the call.
- [After a `cd`, the guard reads a relative query file from the session's directory, and gh reads it from where the `cd` led] → The guard never allows a call with a `cd`. What is lost is the ask, and the deny for a merge in the other file, and only where a project's own rule allows `gh-app api`. A missing file still asks.
- [gh's option parsing differs from the reader's: a new option, or a spelling assumed above] → An option the reader doesn't know ends the read, and the call prompts as today. Each assumed spelling was resolved to the stricter side. `--allow-escape-sequences`, which the manual lists, is left off the list on purpose and pinned as no allow.
- [A mutation the depth rule misses] → It would have to start an operation inside a brace, a string or a comment, which GraphQL doesn't allow. A document the pass can't read (an unclosed string or brace) gets no allow.
- [`--jq` or `--template` reaches the App's token another way than `env`] → Not known for gh's jq or its template functions. The same assumption already covers `gh-app pr view --jq`.
- [`--cache` writes a file] → In gh's own cache directory, outside the project. It holds the response, which the session gets anyway.
- [A query file that only mentions `addPullRequestReview` or `mergePullRequest`, in a comment say, is denied] → The same happens to an inline query today. The message names the reason.
- [A filter that mentions `env` in a harmless word (`.environment`) gets no allow] → It prompts, as today. Pinned in the tests.
- [The secrets deny for a `-F` field applies only on a line read in full] → On any other line the call asks, as today.
- [Two existing test rows flip to allow] → They are GETs of a pull request's reviews and merge status. The spec's merge scenario is a PUT and is unchanged.

## Migration Plan

None. Projects get the guard on their next `devenv update`. Rolling back is reverting the commit.

## Open Questions

- Should `repos/o/r/actions/secrets` stop being denied as a secrets path? It lists secret names, never values. It is the same before and after this change, so it can be its own issue.
- Should `submitPullRequestReview` with `event: APPROVE` be denied like `addPullRequestReview`? Today it gets no decision, inline or in a file. Also its own issue.
