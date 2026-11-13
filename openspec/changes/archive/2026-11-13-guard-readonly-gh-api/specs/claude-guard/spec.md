# Spec Delta

## ADDED Requirements

### Requirement: A gh-app api call that only reads needs no rule
The guard SHALL approve a `gh-app api` call that only reads, as the requirements below define it, as a command that only reads, with no allow rule, bare or behind `devenv shell --`. The program SHALL be spelled `gh-app`, with `api` as its next word. Ask and deny rules SHALL still apply to it, and so SHALL every other check on a call. The user's own `gh api` SHALL be judged as before.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: A REST read
- **WHEN** a session runs `gh-app api repos/o/r/pulls/12`, `gh-app api repos/o/r/pulls/12/reviews` or `gh-app api repos/o/r/pulls/1/merge`, bare or behind `devenv shell --quiet --`, and no rule names it
- **THEN** the guard allows it

#### Scenario: In a chain or a pipeline
- **WHEN** an allow rule covers `git status *` and a session runs `git status && gh-app api repos/o/r/pulls/12`, `gh-app api repos/o/r/pulls | jq '.[].number'`, `gh-app api repos/o/r/pulls 2>&1` or `gh-app api repos/o/r/pulls > "$TMPDIR/pulls.json"`
- **THEN** the guard allows it

#### Scenario: With another command or a redirect into the project
- **WHEN** a session runs `gh-app api repos/o/r/pulls; rm -rf build`, `gh-app api repos/o/r/pulls | sh` or `cd /elsewhere && gh-app api repos/o/r/pulls`
- **THEN** the guard returns no allow; it denies `gh-app api repos/o/r/pulls > pulls.json` as a write to a project file and `gh-app api repos/o/r/pulls && git push --force` for the push

#### Scenario: An ask or deny rule
- **WHEN** the ask rules list `gh-app api *`, or the deny rules do, and a session runs `gh-app api repos/o/r/pulls/12`, bare, wrapped, in a chain or in a pipeline
- **THEN** the guard asks, or denies it

#### Scenario: Another spelling of the program
- **WHEN** a session runs `/nix/store/x/bin/gh-app api repos/o/r/pulls` or `gh-app -R o/r api repos/o/r/pulls`
- **THEN** the guard returns no allow

#### Scenario: The user's own gh
- **WHEN** a session runs `gh api repos/o/r/pulls/12 --jq .mergeable` or `gh api graphql -f query='{viewer{login}}'`
- **THEN** the guard returns no allow, as before; `gh api graphql -F query=@q.graphql` still asks

#### Scenario: A project's own allow rule
- **WHEN** a project's allow rules list `gh-app api *` and a session runs `gh-app api -X POST /repos/o/r/issues -f title=x`
- **THEN** the guard allows it: the rule is not narrowed, and `gh-app api -X PUT repos/o/r/pulls/1/merge` is still denied, with the method in a cluster (`-iXPUT`) too; a filter that mentions `env` (`-q env`) asks

### Requirement: A REST read through gh-app api uses GET or HEAD
A `gh-app api` call to a REST endpoint SHALL count as one that only reads when it gives no method or gives GET or HEAD, in any spelling gh takes and any case, gives no request body, and gives fields only with an explicit GET or HEAD, where gh sends them in the query string. With no method, a field makes gh send a POST, so the call SHALL get no allow.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: The method spelled out
- **WHEN** a session runs `gh-app api -X GET repos/o/r/issues`, `-XGET`, `-Xget`, `-X=get`, `--method get`, `--method=HEAD`, `-iXHEAD`, or the method after the endpoint
- **THEN** the guard allows it

#### Scenario: Fields with an explicit GET
- **WHEN** a session runs `gh-app api -X GET repos/o/r/issues -f state=open -F per_page=5`, `gh-app api --method GET search/issues --raw-field q='repo:o/r is:open' --field=per_page=5`, `gh-app api -XGET repos/o/r/issues -fstate=open` or `gh-app api -X GET repos/o/r/pulls/12/reviews -f per_page=100`
- **THEN** the guard allows it

#### Scenario: Fields with no method
- **WHEN** a session runs `gh-app api repos/o/r/issues` with `-f state=open`, `-F per_page=5`, `--raw-field state=open`, `--field=title=x` or `-fstate=open`
- **THEN** the guard returns no allow

#### Scenario: Any other method
- **WHEN** a session runs `gh-app api -X POST repos/o/r/issues`, `gh-app api -XDELETE repos/o/r/issues/1/labels/x`, `gh-app api --method=patch repos/o/r/issues/1` or `gh-app api -X GET -X POST repos/o/r/issues`
- **THEN** the guard returns no allow

#### Scenario: A request body
- **WHEN** a session runs `gh-app api repos/o/r/pulls/1/reviews --input x.json`, `gh-app api -X GET repos/o/r/issues -F body=@notes.md` or the same with `body=@-`
- **THEN** the guard asks, as before

### Requirement: A GraphQL read through gh-app api holds no mutation
A `gh-app api graphql` call SHALL count as one that only reads when it gives no method or POST, has at least one `query` field, and no `query` document holds a mutation: with comments and string literals dropped, no `mutation` word outside every brace. Every other field is a variable. A document the guard can't read that way SHALL get no allow, and so SHALL any other spelling of the endpoint.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: A query
- **WHEN** a session runs `gh-app api graphql -f query='{viewer{login}}'`, the same starting `query`, with `-F` or `--raw-field`, with variables (`-f o=o -F n=12`), with `-f operationName=Q`, with `-X POST`, with `--paginate --slurp` and an `$endCursor` variable, or with a fragment before the query
- **THEN** the guard allows it

#### Scenario: The word mutation where no operation starts
- **WHEN** a session runs a query with a variable named `$mutation`, a string `"mutation"`, a comment `# mutation` or a field alias `mutation:id` inside the braces
- **THEN** the guard allows it

#### Scenario: A mutation
- **WHEN** a session replies to or resolves a review thread through `gh-app api graphql`, or runs a document that holds a query and a mutation, `MUTATION{...}`, a mutation after a comment line (ended by `\n` or a bare `\r`), or a second `query` field that holds one
- **THEN** the guard returns no allow; a merge, an auto-merge or a review is denied, as before

#### Scenario: A document the guard can't read, or none
- **WHEN** a session runs `gh-app api graphql` with a `query` whose braces don't balance or whose string isn't closed, with no `query` field, or with no field at all
- **THEN** the guard returns no allow

#### Scenario: Another method or spelling of the endpoint
- **WHEN** a session runs `gh-app api graphql -X GET -f query='{viewer{login}}'`, `gh-app api /graphql -f query='{viewer{login}}'`, `gh-app api /graphql -X GET` with a mutation in `query`, or `gh-app api GraphQL -X GET -f query='{viewer{login}}'`
- **THEN** the guard returns no allow

### Requirement: A gh-app api read stays on GitHub as the App and keeps its token
A `gh-app api` call SHALL count as one that only reads only when the guard knows every option and there is one endpoint. It SHALL get no allow with `--hostname`, a full-URL endpoint, `--verbose`, a header other than `Accept` or `X-GitHub-Api-Version`, or a jq or template filter that mentions `env`, which could print the App's token.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: Options a read may carry
- **WHEN** a session runs `gh-app api repos/o/r/pulls` with `--paginate --slurp`, `--cache 1h -i --silent`, `-p corsair --include`, `--jq .mergeable`, `-q '.head.sha'`, `-t '{{.title}}'`, `--template='{{.title}}'`, `-H 'Accept: application/vnd.github.raw'` or `-H X-GitHub-Api-Version:2022-11-28 --header=accept:application/json`
- **THEN** the guard allows it

#### Scenario: Another host, another identity, or the request printed
- **WHEN** a session runs `gh-app api --hostname ghe.example.com repos/o/r/pulls`, `gh-app api https://api.github.com/repos/o/r/pulls`, `gh-app api repos/o/r/pulls --verbose`, or `gh-app api repos/o/r/pulls` with `-H 'Authorization: token x'` or `-H 'X-HTTP-Method-Override: DELETE'`
- **THEN** the guard returns no allow

#### Scenario: A filter that mentions env
- **WHEN** a session runs `gh-app api repos/o/r/pulls` with `--jq 'env.GH_TOKEN'`, `-q '$ENV.GH_TOKEN'`, `-t '{{env "GH_TOKEN"}}'`, `--template '{{env}}'` or `-q.environment`
- **THEN** the guard returns no allow

#### Scenario: A line the guard can't read in full
- **WHEN** a session runs `gh-app api repos/o/r/pulls` with `--allow-escape-sequences`, `--pagin`, `--paginate=true`, a second operand or `-X` with no value, or `gh-app api` alone, or `gh-app api -- repos/o/r/pulls`
- **THEN** the guard returns no allow

#### Scenario: Words the shell would expand
- **WHEN** a session runs `gh-app api repos/{owner}/{repo}/pulls`, `gh-app api repos/o/r/pulls?state=open` or `gh-app api repos/o/r/pulls --jq .[0].title` unquoted, or an endpoint holding `$PR` or `$(cat n)`
- **THEN** the guard returns no allow; single-quoted, `gh-app api 'repos/{owner}/{repo}/pulls?state=open&per_page=5'` is allowed

### Requirement: A GraphQL query file is read and judged by its text
For `gh-app api graphql` with `-F` or `--field` `query=@file`, the guard SHALL read the file when it is a regular UTF-8 file of at most 64 KiB, in scratch or inside the project, and judge its text as it judges a `query` given in the command. Where it doesn't read the file, it SHALL ask, as before.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block, in a temporary directory.

#### Scenario: A query in a file
- **WHEN** a session runs `gh-app api graphql -F query=@queries/threads.graphql -F n=12` for a file in the project that holds a query (and a comment that says "mutation"), the same with `--field query=@...`, `--field=query=@...` or `-Fquery=@...`, with the file's absolute path, or with the absolute path of a query file in scratch, alone or piped to `jq .data`
- **THEN** the guard allows it

#### Scenario: A mutation in the file
- **WHEN** the file holds a review-thread reply or another mutation
- **THEN** the guard returns no allow; where it holds `mergePullRequest`, `enablePullRequestAutoMerge` or `addPullRequestReview`, the guard denies the call

#### Scenario: A file the guard doesn't read
- **WHEN** the file is missing, a directory, over 64 KiB, not UTF-8, outside the project and scratch (`@/etc/hosts`, `@../outside.graphql`), or standard input (`@-`), or the path is relative and the session's directory is unknown
- **THEN** the guard asks

#### Scenario: A call that could write the file first
- **WHEN** a session runs `printf x > <scratch>/q.graphql && gh-app api graphql -F query=@<scratch>/q.graphql`, or the call holds any other redirect or a command that doesn't only read, such as `cp` or `git status`
- **THEN** the guard returns no allow

#### Scenario: A file whose document can't be read
- **WHEN** the file's braces don't balance
- **THEN** the guard returns no allow

#### Scenario: Any other file
- **WHEN** a session runs `gh-app api graphql` with a query and `-F n=@file` or `-F body=@file`, with `-f query=@file` (a raw field, which gh sends as written), with `--input file`, with an option the guard doesn't know beside `-F query=@file`, or `gh-app api -X GET repos/o/r/issues -F query=@file`
- **THEN** the guard asks

#### Scenario: Where the session's directory is unknown
- **WHEN** the guard doesn't know the session's directory and a session runs `gh-app api graphql -F query=@<absolute scratch path>`
- **THEN** the guard reads the file: it allows a query and denies a merge

#### Scenario: Under an ask rule
- **WHEN** the ask rules list `gh-app api *` and a session runs `gh-app api graphql -F query=@queries/threads.graphql`
- **THEN** the guard asks

### Requirement: A gh-app api field never uploads a secrets file
The guard SHALL deny a `gh-app api` call it reads in full whose `-F` or `--field` value is `@` and the path of a secrets file, directly or through a symlink, since gh uploads the file's contents.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block, in a temporary directory.

#### Scenario: A secrets file as the query
- **WHEN** a session runs `gh-app api graphql` with `-F query=@.env`, `-Fquery=@.env`, `--field=query=@.env`, `-F query=@secrets/q.graphql` or `-F query=@queries/link.graphql`, a link to `.env`
- **THEN** the guard denies it

#### Scenario: A secrets file as any field
- **WHEN** a session runs `gh-app api -X GET repos/o/r/issues -F body=@.env`
- **THEN** the guard denies it

### Requirement: On a gh-app api call only --input and an @ field value name a file
On a `gh-app api` call the guard reads in full, it SHALL ask for a request read from a file only for `--input` and for a field value that starts with `@`, other than a GraphQL query file it has read. An `@` anywhere else SHALL NOT make it ask. On a call it can't read in full, any `--input`, `=@` or word starting `@` SHALL make it ask, as before.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: A jq format or a GraphQL directive
- **WHEN** a session runs `gh-app api repos/o/r/pulls --jq '.[] | [.number, .title] | @tsv'` or `gh-app api graphql -f query='query($a:Boolean!){viewer{login @include(if:$a)}}' -F a=true`
- **THEN** the guard allows it

#### Scenario: The same on a line the guard can't read in full
- **WHEN** a session runs `gh-app api repos/o/r/pulls --allow-escape-sequences --jq '.[] | @tsv'`
- **THEN** the guard asks

### Requirement: A gh-app api endpoint is not a file path
The guard SHALL NOT take the endpoint of a `gh-app api` call it reads in full for a path outside the project: gh sends it to GitHub and reads no file by it. An endpoint that names a secrets file SHALL still be denied.

Tested by: `claude-guard-test.py`, the "gh-app api reads" block.

#### Scenario: A leading slash
- **WHEN** a session runs `gh-app api /repos/o/r/pulls/12`, bare or wrapped
- **THEN** the guard allows it

#### Scenario: An endpoint naming a secrets file
- **WHEN** a session runs `gh-app api repos/o/r/contents/.env`
- **THEN** the guard denies it, as before
