# Proposal

## Why

Every `gh-app api` call prompts (#110). No allow rule names `gh-app api`, so reading a pull request, its reviews or its review threads through the API waits for a user each time, though it changes nothing. A rule can't fix it: `gh-app api *` would also allow a DELETE, a POST with fields, a GraphQL mutation, another host and a full URL.

## What Changes

- **A `gh-app api` call that only reads runs without a prompt**, bare or behind `devenv shell --`, with no allow rule. The guard reads the call's options itself:
  - REST: no method, or GET or HEAD in any spelling. Fields (`-f`, `-F`) only with an explicit GET or HEAD, which sends them in the query string.
  - GraphQL (`gh-app api graphql`): a `query` field whose document holds no mutation. Other fields are variables.
  - It may carry `--paginate`, `--slurp`, `--cache`, `-i`, `--silent`, `-p`, an `Accept` or `X-GitHub-Api-Version` header, and a `--jq` or `--template` filter that doesn't mention `env`.
  - It gets no allow with `--hostname`, a full-URL endpoint, `--verbose`, any other header, `--input`, an option the guard doesn't know, or a field read from a file other than the query.
- **A GraphQL query in a file is read by the guard.** `-F query=@file` stops asking when the file is a readable regular file in scratch or the project, at most 64 KiB. The guard judges its text as it judges an inline query: a merge or an approval in it is denied, a mutation gets no allow. Any other file, `@-`, and a file the guard can't read keep asking.
- **A `-F` field never uploads a secrets file.** `gh-app api ... -F key=@.env` is denied. Today it asks.
- **An `@` that names no file no longer asks.** On a `gh-app api` line the guard reads in full, only `--input` and a field value starting `@` name a file. A jq format (`--jq '... | @tsv'`) or a GraphQL directive (`@include`) doesn't.
- **`gh-app api`'s endpoint is not a file path.** A leading slash (`/repos/o/r/pulls`) no longer counts as a path outside the project.
- Ask and deny rules still win. The merge and approval denies are unchanged and come first.

Not in this change: the user's own `gh` (every `gh api` call is judged as today), any edit to `devenv.nix`, a `$TMPDIR` inside a word (`query=@$TMPDIR/q.graphql` gets no allow; an absolute scratch path does), and the existing deny of an endpoint that names a secrets file or a `secrets` path segment (`repos/o/r/contents/.env`, `repos/o/r/actions/secrets`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: adds read-only `gh-app api` calls as commands that only read, the reading of a GraphQL query file, the deny of a secrets file as a field, and the endpoint as not a path.

## Impact

- `packages/claude-guard.py`: four new helpers beside `devenv_query()`, and small edits in `forbidden_from()`, `plain_args()`, `read_only()` and the module docstring.
- `packages/claude-guard-test.py`: two expected values flip from no decision to allow, and one block is appended.
- `README.md`: the `packages/claude-guard.py` row.
- No change to `devenv.nix`, `packages/gh-app.sh` or any rule.
- Every project that imports the module gets the guard change on its next lock update. Sessions can then read, without a prompt, anything on GitHub the App's installation can read.
