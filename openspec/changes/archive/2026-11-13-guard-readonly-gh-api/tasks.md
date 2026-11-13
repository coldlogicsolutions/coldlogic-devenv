# Tasks

Make only the edits below, at the anchors named, with Edit. Don't reformat, reorder or rename anything else, and don't touch `devenv.nix`, `packages/gh-app.sh` or `MODULE_ALLOW`. Line numbers are from `b53d4b6` and may have moved; find each anchor by its text. Every code block below is indented two spaces to sit under its task: remove those two spaces when you copy it.

Run the guard's tests with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed`, or a `FAIL` line per wrong case. On `b53d4b6` it prints `1621/1621 passed`.

Never run a `gh-app api` command to try something out. Every check here goes through `guard.decide()`, which runs nothing.

All of the code below was run as written in a scratch copy of the guard (see design.md, "Checked by prototype"). If a row fails that this plan says passes, stop and report it: the guard on this branch differs from the one the plan was checked against.

## 1. The tests, first

- [x] 1.1 In `packages/claude-guard-test.py`, in the `BASH` table, change the expected value of two rows from `NONE` to `ALLOW`: `("gh-app api repos/o/r/pulls/1/merge", NONE),` (near line 62) and `("gh-app api repos/o/r/pulls/12/reviews", NONE),` (near line 305). Both are GETs. Leave every other `gh-app api` and `gh api` row as it is, in particular `("gh api graphql -F query=@q.graphql", ASK)`, the two `--input` rows (`ASK`), the four thread-reply and resolve mutation rows (`NONE`) and `("gh api repos/o/r/pulls/12 --jq .mergeable", NONE)`. Verify: the run ends `1619/1621 passed`, with exactly two `FAIL Bash` lines, for those two commands.
- [x] 1.2 In the same file, add the block below at the end, directly above the line `total = checks`, with one blank line before and after it. It uses `module_policy`, `tempfile`, `os` and `guard`, all defined above it. Copy it as written. Verify: the run ends `1800/1937 passed`. Of the 137 `FAIL` lines, 2 are the `FAIL Bash` lines from 1.1 and 135 start `FAIL gh-app api`: 110 expect `allow`, 19 expect `deny` (a query file holding a merge or a review, and a secrets file as a field, which ask today) and 6 expect `None` (a query file holding another mutation or unbalanced braces, which asks today). Every row whose command starts `gh api` passes. Totals shift if other cases have landed; what must hold is that no line fails outside those kinds.

  ```python
  # #110: a `gh-app api` call that only reads needs no rule. Each row runs
  # bare and behind `devenv shell --quiet --`, against the module's own
  # allow list, which names no `gh-app api`.
  GH_API = [
      # REST: no method, or GET or HEAD however it is spelled.
      ("gh-app api repos/o/r/pulls/12", ALLOW),
      ("gh-app api /repos/o/r/pulls/12", ALLOW),
      ("gh-app api repos/o/r/pulls/12/reviews", ALLOW),
      ("gh-app api repos/o/r/pulls/1/merge", ALLOW),
      ("gh-app api 'repos/{owner}/{repo}/pulls?state=open&per_page=5'", ALLOW),
      ("gh-app api -X GET repos/o/r/issues", ALLOW),
      ("gh-app api -XGET repos/o/r/issues", ALLOW),
      ("gh-app api -X=get repos/o/r/issues", ALLOW),
      ("gh-app api --method get repos/o/r/issues", ALLOW),
      ("gh-app api --method=HEAD repos/o/r/issues", ALLOW),
      ("gh-app api -iXHEAD repos/o/r/issues", ALLOW),
      ("gh-app api -Xget repos/o/r/issues", ALLOW),
      ("gh-app api repos/o/r/issues -X GET", ALLOW),
      # Fields go in the query string only with an explicit GET or HEAD.
      ("gh-app api -X GET repos/o/r/issues -f state=open -F per_page=5", ALLOW),
      ("gh-app api --method GET search/issues --raw-field q='repo:o/r is:open' --field=per_page=5", ALLOW),
      ("gh-app api -XGET repos/o/r/issues -fstate=open", ALLOW),
      ("gh-app api repos/o/r/issues -f state=open", NONE),
      ("gh-app api repos/o/r/issues -F per_page=5", NONE),
      ("gh-app api repos/o/r/issues --raw-field state=open", NONE),
      ("gh-app api repos/o/r/issues --field=title=x", NONE),
      ("gh-app api repos/o/r/issues -fstate=open", NONE),
      # Any other method.
      ("gh-app api -X POST repos/o/r/issues", NONE),
      ("gh-app api -XDELETE repos/o/r/issues/1/labels/x", NONE),
      ("gh-app api --method=patch repos/o/r/issues/1", NONE),
      ("gh-app api -X GET -X POST repos/o/r/issues", NONE),
      ("gh-app api -X PUT repos/o/r/pulls/1/merge", DENY),
      ("gh-app api repos/o/r/pulls/12/reviews -f event=APPROVE", DENY),
      # The options a read may carry.
      ("gh-app api repos/o/r/pulls --paginate --slurp", ALLOW),
      ("gh-app api repos/o/r/pulls --cache 1h -i --silent", ALLOW),
      ("gh-app api repos/o/r/pulls -p corsair --include", ALLOW),
      ("gh-app api repos/o/r/pulls/12 --jq .mergeable", ALLOW),
      ("gh-app api repos/o/r/pulls/12 -q '.head.sha'", ALLOW),
      ("gh-app api repos/o/r/pulls --jq '.[] | [.number, .title] | @tsv'", ALLOW),
      ("gh-app api repos/o/r/pulls/12 -t '{{.title}}'", ALLOW),
      ("gh-app api repos/o/r/pulls/12 --template='{{.title}}'", ALLOW),
      ("gh-app api repos/o/r/contents/README.md -H 'Accept: application/vnd.github.raw'", ALLOW),
      ("gh-app api repos/o/r/pulls -H X-GitHub-Api-Version:2022-11-28 --header=accept:application/json", ALLOW),
      # Where the request goes, who it speaks as, what it prints.
      ("gh-app api --hostname ghe.example.com repos/o/r/pulls", NONE),
      ("gh-app api https://api.github.com/repos/o/r/pulls", NONE),
      ("gh-app api https://example.com/x", NONE),
      ("gh-app api repos/o/r/pulls --verbose", NONE),
      ("gh-app api repos/o/r/pulls -H 'Authorization: token x'", NONE),
      ("gh-app api repos/o/r/pulls -H 'X-HTTP-Method-Override: DELETE'", NONE),
      # A filter that could read the App's token from the environment.
      ("gh-app api repos/o/r/pulls --jq 'env.GH_TOKEN'", NONE),
      ("gh-app api repos/o/r/pulls -q '$ENV.GH_TOKEN'", NONE),
      ("gh-app api repos/o/r/pulls -t '{{env \"GH_TOKEN\"}}'", NONE),
      ("gh-app api repos/o/r/pulls --template '{{env}}'", NONE),
      ("gh-app api repos/o/r/pulls -q.environment", NONE),
      # An option the guard doesn't know, or a line it can't read in full.
      ("gh-app api repos/o/r/pulls --allow-escape-sequences", NONE),
      ("gh-app api repos/o/r/pulls --allow-escape-sequences --jq '.[] | @tsv'", ASK),
      ("gh-app api repos/o/r/pulls --pagin", NONE),
      ("gh-app api repos/o/r/pulls --paginate=true", NONE),
      ("gh-app api repos/o/r/pulls extra", NONE),
      ("gh-app api", NONE),
      ("gh-app api -- repos/o/r/pulls", NONE),
      ("gh-app api repos/o/r/pulls -X", NONE),
      ("gh-app -R o/r api repos/o/r/pulls", NONE),
      ("/nix/store/x/bin/gh-app api repos/o/r/pulls", NONE),
      # What the shell would expand: quote it.
      ("gh-app api repos/{owner}/{repo}/pulls", NONE),
      ("gh-app api repos/o/r/pulls?state=open", NONE),
      ("gh-app api repos/o/r/pulls --jq .[0].title", NONE),
      ("gh-app api repos/o/r/pulls/$PR", NONE),
      ("gh-app api repos/o/r/pulls/$(cat n)", NONE),
      # A request body from a file or stdin still asks.
      ("gh-app api repos/o/r/pulls/1/reviews --input x.json", ASK),
      ("gh-app api graphql --input q.json", ASK),
      ("gh-app api -X GET repos/o/r/issues -F body=@notes.md", ASK),
      ("gh-app api -X GET repos/o/r/issues -F body=@-", ASK),
      # GraphQL: a query, and nothing that changes anything.
      ("gh-app api graphql -f query='{viewer{login}}'", ALLOW),
      ("gh-app api graphql -f query='query{viewer{login}}'", ALLOW),
      ("gh-app api graphql -F query='query { viewer { login } }'", ALLOW),
      ("gh-app api graphql --raw-field query='query($o:String!,$n:String!){repository(owner:$o,name:$n){id}}' -f o=o -f n=r", ALLOW),
      ("gh-app api graphql -f query='query($n:Int!){repository(owner:\"o\",name:\"r\"){pullRequest(number:$n){reviewThreads(first:50){nodes{id isResolved}}}}}' -F n=12", ALLOW),
      ("gh-app api graphql --paginate --slurp -f query='query($endCursor:String){viewer{repositories(first:100,after:$endCursor){nodes{name} pageInfo{hasNextPage endCursor}}}}'", ALLOW),
      ("gh-app api graphql -X POST -f query='{viewer{login}}' --jq .data.viewer.login", ALLOW),
      ("gh-app api graphql -f query='{viewer{login}}' -f operationName=Q", ALLOW),
      ("gh-app api graphql -f query='query($mutation:Boolean!){viewer{login}}' -F mutation=true", ALLOW),
      ("gh-app api graphql -f query='query{repository(owner:\"o\",name:\"mutation\"){id}} # mutation'", ALLOW),
      ("gh-app api graphql -f query='fragment F on User{login} query{viewer{...F}}'", ALLOW),
      ("gh-app api graphql -f query='{repository(owner:\"o\",name:\"r\"){mutation:id}}'", ALLOW),
      # An `@` that names no file: a jq format, a GraphQL directive.
      ("gh-app api graphql -f query='query($a:Boolean!){viewer{login @include(if:$a)}}' -F a=true", ALLOW),
      ("gh-app api graphql -f query='{viewer{login}}' --jq '.data.viewer | [.login] | @tsv'", ALLOW),
      # A mutation, wherever it sits in the document.
      ("gh-app api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{url}}}' -f t=X -f b=done", NONE),
      ("gh-app api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t=X", NONE),
      ("gh-app api graphql -f query='query Q{viewer{login}} mutation M{addStar(input:{starrableId:\"X\"}){clientMutationId}}' -f operationName=M", NONE),
      ("gh-app api graphql -f query='MUTATION{addStar(input:{starrableId:\"X\"}){clientMutationId}}'", NONE),
      ("gh-app api graphql -f query='# a query\nmutation{addStar(input:{starrableId:\"X\"}){clientMutationId}}'", NONE),
      ("gh-app api graphql -f query='{viewer{login}}' -f query='mutation{addStar(input:{starrableId:\"X\"}){clientMutationId}}'", NONE),
      ("gh-app api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"X\"}){clientMutationId}}'", DENY),
      ("gh-app api graphql -f query='mutation{addPullRequestReview(input:{pullRequestId:\"X\",event:APPROVE}){clientMutationId}}'", DENY),
      # A document the guard can't read, or none.
      ("gh-app api graphql -f query='{viewer{login}'", NONE),
      ("gh-app api graphql -f query='{viewer{login}}}'", NONE),
      ("gh-app api graphql -f query='{repository(owner:\"o){id}}'", NONE),
      ("gh-app api graphql", NONE),
      ("gh-app api graphql -f o=o", NONE),
      # Not the GraphQL endpoint as gh reads it, or not as GitHub serves it.
      ("gh-app api graphql -X GET -f query='{viewer{login}}'", NONE),
      ("gh-app api /graphql -f query='{viewer{login}}'", NONE),
      ("gh-app api /graphql -X GET -f query='mutation{addStar(input:{starrableId:\"X\"}){clientMutationId}}'", NONE),
      ("gh-app api GraphQL -X GET -f query='{viewer{login}}'", NONE),
      # A variable read from a file, or a query from stdin, is uploaded unread.
      ("gh-app api graphql -f query='query($b:String!){viewer{login}}' -F b=@notes.md", ASK),
      ("gh-app api graphql -F query=@-", ASK),
      ("gh-app api graphql -F query=@q.graphql", ASK),
      # In a chain or a pipeline, each part on its own.
      ("gh-app api repos/o/r/pulls | jq '.[].number'", ALLOW),
      ("gh-app api repos/o/r/pulls --jq '.[].title' | head -5", ALLOW),
      ("gh-app api repos/o/r/pulls 2>&1", ALLOW),
      ("gh-app api repos/o/r/pulls > \"$TMPDIR/pulls.json\"", ALLOW),
      ("gh-app api repos/o/r/pulls > /dev/null", ALLOW),
      ("git status && gh-app api repos/o/r/pulls/12", ALLOW),
      ("gh-app api repos/o/r/pulls > pulls.json", DENY),
      ("gh-app api repos/o/r/pulls; rm -rf build", NONE),
      ("gh-app api repos/o/r/pulls && git push --force", DENY),
      ("gh-app api repos/o/r/pulls | sh", NONE),
      ("cd /elsewhere && gh-app api repos/o/r/pulls", NONE),
      # An endpoint that names a secrets file is still one (as before).
      ("gh-app api repos/o/r/contents/.env", DENY),
      ("gh-app api repos/o/r/actions/secrets", DENY),
      # The user's own gh is out of scope.
      ("gh api repos/o/r/pulls/12 --jq .mergeable", NONE),
      ("gh api graphql -f query='{viewer{login}}'", NONE),
      ("gh api graphql -F query=@q.graphql", ASK),
  ]
  for command, expected in [(c, e) for command, e in GH_API
                            for c in (command, "devenv shell --quiet -- " + command)]:
      got = guard.decide("Bash", {"command": command}, module_policy)
      checks += 1
      got = got[0] if got else None
      if got != expected:
          failures += 1
          print(f"FAIL gh-app api read {command!r}: expected {expected}, got {got}")

  # An ask or deny rule still wins, and a project's own allow rule for
  # `gh-app api` is not narrowed.
  for policy, command, expected in [
      ({}, "gh-app api repos/o/r/pulls/12", ALLOW),
      ({}, "devenv shell --quiet -- gh-app api repos/o/r/pulls/12", ALLOW),
      ({"ask": ["gh-app api *"]}, "gh-app api repos/o/r/pulls/12", ASK),
      ({"ask": ["gh-app api *"]}, "devenv shell --quiet -- gh-app api repos/o/r/pulls/12", ASK),
      ({"deny": ["gh-app api *"]}, "gh-app api repos/o/r/pulls/12", DENY),
      ({"deny": ["gh-app *"]}, "devenv shell --quiet -- gh-app api graphql -f query='{viewer{login}}'", DENY),
      ({"ask": ["gh-app api *"]}, "git status && gh-app api repos/o/r/pulls/12", ASK),
      ({"ask": ["gh-app api *"]}, "gh-app api repos/o/r/pulls | head -5", ASK),
      ({"ask": ["gh-app api graphql *"]}, "gh-app api graphql -f query='{viewer{login}}'", ASK),
      ({"allow": ["gh-app api *"]}, "gh-app api -X POST /repos/o/r/issues -f title=x", ALLOW),
      ({"allow": ["gh-app api *"]}, "gh-app api -X PUT repos/o/r/pulls/1/merge", DENY),
      ({"allow": ["devenv shell *"]}, "devenv shell --quiet -- gh-app api -X POST repos/o/r/issues", ASK),
  ]:
      got = guard.decide("Bash", {"command": command}, policy)
      checks += 1
      got = got[0] if got else None
      if got != expected:
          failures += 1
          print(f"FAIL gh-app api read {policy} {command!r}: expected {expected}, got {got}")

  # A GraphQL query in a file: the guard reads what gh would upload. The
  # project and the scratch directory are both under the temporary directory,
  # which is itself scratch: the relative paths go through the project.
  with tempfile.TemporaryDirectory() as top:
      top = os.path.realpath(top)
      root = os.path.join(top, "p")
      os.makedirs(os.path.join(root, "queries"))
      os.makedirs(os.path.join(root, "secrets"))
      scratch_dir = os.path.join(top, "scratch")
      os.makedirs(scratch_dir)
      files = {
          os.path.join(root, "queries", "threads.graphql"):
              "# Review threads. This is not a mutation.\nquery($n: Int!) {\n  repository(owner: \"o\", name: \"r\") {\n"
              "    pullRequest(number: $n) { reviewThreads(first: 50) { nodes { id isResolved } } }\n  }\n}\n",
          os.path.join(root, "queries", "reply.graphql"):
              "mutation($t: ID!, $b: String!) {\n  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $t, body: $b}) { comment { url } }\n}\n",
          os.path.join(root, "queries", "merge.graphql"):
              "mutation { mergePullRequest(input: {pullRequestId: \"X\"}) { clientMutationId } }\n",
          os.path.join(root, "queries", "approve.graphql"):
              "mutation { addPullRequestReview(input: {pullRequestId: \"X\", event: APPROVE}) { clientMutationId } }\n",
          os.path.join(root, "queries", "broken.graphql"): "query { viewer { login }\n",
          os.path.join(root, "queries", "big.graphql"): "query { viewer { login } }\n" + "# pad\n" * 20000,
          os.path.join(root, "queries", "binary.graphql"): None,
          os.path.join(root, ".env"): "query { viewer { login } }\n",
          os.path.join(root, "secrets", "q.graphql"): "query { viewer { login } }\n",
          os.path.join(scratch_dir, "q.graphql"): "query { viewer { login } }\n",
          os.path.join(scratch_dir, "m.graphql"): "mutation { addStar(input: {starrableId: \"X\"}) { clientMutationId } }\n",
          os.path.join(scratch_dir, "merge.graphql"): "mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"X\"}) { clientMutationId } }\n",
      }
      for path, text in files.items():
          if text is None:
              with open(path, "wb") as f:
                  f.write(b"\xff\xfe query { viewer { login } }")
          else:
              with open(path, "w") as f:
                  f.write(text)
      os.symlink(os.path.join(root, ".env"), os.path.join(root, "queries", "link.graphql"))
      os.mkdir(os.path.join(root, "queries", "dir.graphql"))
      cases = [
          ("gh-app api graphql -F query=@queries/threads.graphql -F n=12", ALLOW),
          ("gh-app api graphql --field query=@queries/threads.graphql -F n=12", ALLOW),
          ("gh-app api graphql --field=query=@queries/threads.graphql -F n=12 --jq .data", ALLOW),
          ("gh-app api graphql -Fquery=@queries/threads.graphql -F n=12", ALLOW),
          (f"gh-app api graphql -F query=@{root}/queries/threads.graphql -F n=12", ALLOW),
          (f"gh-app api graphql -F query=@{scratch_dir}/q.graphql", ALLOW),
          (f"gh-app api graphql -F query=@{scratch_dir}/q.graphql | jq .data", ALLOW),
          # A mutation in the file gets no allow; a merge or an approval is denied.
          ("gh-app api graphql -F query=@queries/reply.graphql -f t=X -f b=done", NONE),
          (f"gh-app api graphql -F query=@{scratch_dir}/m.graphql", NONE),
          ("gh-app api graphql -F query=@queries/merge.graphql", DENY),
          ("gh-app api graphql -F query=@queries/approve.graphql", DENY),
          (f"gh-app api graphql -F query=@{scratch_dir}/merge.graphql", DENY),
          # A file the guard won't or can't read keeps asking.
          ("gh-app api graphql -F query=@queries/missing.graphql", ASK),
          ("gh-app api graphql -F query=@queries/dir.graphql", ASK),
          ("gh-app api graphql -F query=@queries/big.graphql", ASK),
          ("gh-app api graphql -F query=@queries/binary.graphql", ASK),
          ("gh-app api graphql -F query=@/etc/hosts", ASK),
          ("gh-app api graphql -F query=@../outside.graphql", ASK),
          ("gh-app api graphql -F query=@-", ASK),
          ("gh-app api graphql -F query=@queries/broken.graphql", NONE),
          # Only the query is read: any other file is uploaded unread.
          ("gh-app api graphql -F query=@queries/threads.graphql -F n=@queries/threads.graphql", ASK),
          ("gh-app api graphql -f query='{viewer{login}}' -F body=@queries/threads.graphql", ASK),
          ("gh-app api graphql -f query=@queries/threads.graphql", ASK),
          ("gh-app api -X GET repos/o/r/issues -F query=@queries/threads.graphql", ASK),
          ("gh-app api graphql -F query=@queries/threads.graphql --input queries/threads.graphql", ASK),
          ("gh-app api graphql -F query=@queries/threads.graphql --allow-escape-sequences", ASK),
          # Never a secrets file.
          ("gh-app api graphql -F query=@.env", DENY),
          ("gh-app api graphql -F query=@secrets/q.graphql", DENY),
          ("gh-app api graphql -F query=@queries/link.graphql", DENY),
          ("gh-app api graphql -Fquery=@.env", DENY),
          ("gh-app api graphql --field=query=@.env", DENY),
          ("gh-app api -X GET repos/o/r/issues -F body=@.env", DENY),
          # The user's own gh still asks.
          ("gh api graphql -F query=@queries/threads.graphql", ASK),
      ]
      guard.WORKING.update(cwd=root, root=root)
      try:
          for command, expected in [(c, e) for command, e in cases
                                    for c in (command, "devenv shell --quiet -- " + command)]:
              got = guard.decide("Bash", {"command": command}, module_policy)
              checks += 1
              got = got[0] if got else None
              if got != expected:
                  failures += 1
                  print(f"FAIL gh-app api query file {command!r}: expected {expected}, got {got}")
          # With an ask rule the file changes nothing.
          got = guard.decide("Bash", {"command": "gh-app api graphql -F query=@queries/threads.graphql"},
                             {"ask": ["gh-app api *"]})
          checks += 1
          if not got or got[0] != ASK:
              failures += 1
              print(f"FAIL gh-app api query file under an ask rule: got {got}")
      finally:
          guard.WORKING.update(cwd=None, root=None)
      # Where the cwd is unknown: only an absolute scratch path can be read.
      for command, expected in [
          (f"gh-app api graphql -F query=@{scratch_dir}/q.graphql", ALLOW),
          (f"gh-app api graphql -F query=@{scratch_dir}/merge.graphql", DENY),
          ("gh-app api graphql -F query=@queries/threads.graphql", ASK),
      ]:
          got = guard.decide("Bash", {"command": command}, module_policy)
          checks += 1
          got = got[0] if got else None
          if got != expected:
              failures += 1
              print(f"FAIL gh-app api query file, no cwd {command!r}: expected {expected}, got {got}")
  ```

## 2. Reading a `gh-app api` line

Invariant for the whole group: the reader gives up (`None`) on anything it doesn't know, and every caller then behaves as before this change. Nothing here may guess what an unknown option does. Each helper is used only by the tasks in groups 3 and 4, so the test totals don't move in this group.

- [x] 2.1 In `packages/claude-guard.py`, directly above `def devenv_command(words):` (below `devenv_query()`), add the constants and `gh_api_call()` below. Keep two blank lines before `def devenv_command`. Protects: an option that takes a value is never read as a flag, so its value can't be taken for the endpoint or another option; a long name must match exactly (`--pagin`, `--paginate=true` and `--` end the read); exactly one operand. `--allow-escape-sequences` is left off the lists on purpose. Verify: the file still runs, with the same result as after 1.2.

  ```python
  # gh api's options (cli.github.com/manual/gh_api), by the name each goes
  # under: those that take no value, and those that take one. gh takes no
  # abbreviation of a long name. One missing here only means the call prompts.
  GH_API_FLAGS = {"-i": "include", "--include": "include", "--paginate": "paginate",
                  "--slurp": "slurp", "--silent": "silent", "--verbose": "verbose"}
  GH_API_VALUED = {"-X": "method", "--method": "method", "-f": "raw-field",
                   "--raw-field": "raw-field", "-F": "field", "--field": "field",
                   "-H": "header", "--header": "header", "-q": "jq", "--jq": "jq",
                   "-t": "template", "--template": "template", "-p": "preview",
                   "--preview": "preview", "--cache": "cache", "--hostname": "hostname",
                   "--input": "input"}
  # The request headers a read may set: they choose how the answer is
  # written, not where the request goes or who makes it.
  GH_API_HEADERS = {"accept", "x-github-api-version"}
  # The largest GraphQL query file the guard reads.
  GH_QUERY_LIMIT = 65536
  # What a GraphQL document's operations can't hide in: block strings,
  # strings and comments.
  GRAPHQL_SKIP = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|#[^\n]*')


  def gh_api_call(args):
      """(the endpoint, [(option name, value or None), ...]) of the gh
      arguments `api ...`, or None when they aren't a call this reads in
      full: `api` not first, an option not listed above, a value missing, or
      not exactly one operand. Options are in the order given, under their
      long names; a short one may sit in a cluster and hold its value
      (`-iXGET`, `-X=GET`), a long one may hold it after `=`."""
      if args[:1] != ["api"]:
          return None
      operands, options = [], []
      i = 1
      while i < len(args):
          w = args[i]
          i += 1
          if w == "-" or not w.startswith("-"):
              operands.append(w)
              continue
          if w.startswith("--"):
              name, given, value = w.partition("=")
              if name in GH_API_FLAGS and not given:
                  options.append((GH_API_FLAGS[name], None))
                  continue
              if name not in GH_API_VALUED:
                  return None
              if not given:
                  if i >= len(args):
                      return None
                  value = args[i]
                  i += 1
              options.append((GH_API_VALUED[name], value))
              continue
          letters = w[1:]
          while letters:
              flag, letters = "-" + letters[0], letters[1:]
              if flag in GH_API_FLAGS:
                  options.append((GH_API_FLAGS[flag], None))
                  continue
              if flag not in GH_API_VALUED:
                  return None
              if letters:
                  value = letters[1:] if letters.startswith("=") else letters
              elif i < len(args):
                  value = args[i]
                  i += 1
              else:
                  return None
              options.append((GH_API_VALUED[flag], value))
              letters = ""
      return (operands[0], options) if len(operands) == 1 else None
  ```

- [x] 2.2 Directly below `gh_api_call()`, add `gh_query_file()`. Protects: the guard reads a query only from scratch or the project (Derek's decision 1), never follows a path out of them (`resolve()` judges where a link leads), never reads a device, a directory or a huge file, and returns `None`, which makes the caller ask, for anything else. `scratch()` and `resolve()` are defined further down the file; that is fine, they are looked up when called. Verify: the file still runs, same result.

  ```python
  def gh_query_file(path):
      """The text of a GraphQL query file `-F query=@path` uploads, or None
      when the guard won't read it: not in scratch or the project (a relative
      path where the cwd is unknown included), not a regular file, over
      GH_QUERY_LIMIT, unreadable, or not UTF-8."""
      if scratch(path):
          full = path
      else:
          where = resolve(path)
          if where is None or where[1] is None:
              return None
          full = where[0]
      try:
          if not os.path.isfile(full) or os.path.getsize(full) > GH_QUERY_LIMIT:
              return None
          with open(full, encoding="utf-8") as f:
              return f.read()
      except (OSError, UnicodeDecodeError):
          return None
  ```

- [x] 2.3 Directly below `gh_query_file()`, add `graphql_reads()`. Protects: a mutation can't hide from the check in a comment or a string (they are dropped first, in one left-to-right pass, so a `#` in a string and a `"` in a comment are read right), and a document the pass can't read (a `"` left over, braces that don't balance) is not a read. The lookbehind keeps `$mutation` and `@mutation` from counting. Verify: the file still runs, same result.

  ```python
  def graphql_reads(text):
      """Whether a GraphQL document holds no mutation: with comments and
      strings dropped, no `mutation` word outside every brace, where an
      operation starts. A document this can't read that way (an unclosed
      string or brace) doesn't count."""
      text = GRAPHQL_SKIP.sub(" ", text)
      if '"' in text:
          return False
      depth, top = 0, []
      for c in text:
          if c == "{":
              depth += 1
          elif c == "}":
              depth -= 1
              if depth < 0:
                  return False
              top.append(" ")
          elif depth == 0:
              top.append(c)
      return depth == 0 and not re.search(r"(?<![\w$@])mutation(?!\w)", "".join(top), re.I)
  ```

## 3. The denies and the ask, before any allow

Do this group before group 4. Until it is in, a query file can't be allowed (it still asks), so nothing is approved that the denies haven't seen.

- [x] 3.1 In `forbidden_from()`, in the `if head == "gh-app":` branch only, replace the body of `if sub and sub[0] == "api":` (the five lines from `text = " ".join(lowered)` to `raise Unparsable("gh-app api reading its request from a file")`) with the block below. Don't touch the `if head == "gh":` branch above it, which has the same five lines for the user's `gh`. Protects: (a) the merge and review denies still run on the command's words exactly as before, and now also on a query file's text, checked on its own so the REST half of `api_changes_review()` can't match it against the line's `-F`; (b) gh uploads a `-F` file, so a secrets file as any field's value is denied; (c) a file the guard hasn't read still raises `Unparsable`, which asks: `--input`, any field value starting `@` other than a query file read, and, on a line `gh_api_call()` can't read, the same text check as before. Verify: the run ends `1825/1937 passed`. The 112 `FAIL` lines left all expect `allow`: the 2 `FAIL Bash` lines, and 110 starting `FAIL gh-app api`. Every `ASK`, `DENY` and `NONE` row passes.

  ```python
          if sub and sub[0] == "api":
              text = " ".join(lowered)
              call = gh_api_call(args)
              if call is None:
                  # A line this can't read in full: any `@` may name a file.
                  unread = "--input" in text or "=@" in text or re.search(r"(^| )@", text)
                  bodies = []
              else:
                  # Read in full, only `--input` and a field value starting
                  # `@` name a file (a jq `@tsv` or a GraphQL directive
                  # doesn't). gh uploads a `-F` file's contents: never a
                  # secrets file, and the guard reads only a GraphQL query
                  # (gh_query_file), judged by its text here and in
                  # gh_api_reads.
                  unread, bodies = any(n == "input" for n, _ in call[1]), []
                  for name, value in call[1]:
                      key, _, at = (value or "").partition("=")
                      if name not in ("field", "raw-field") or not at.startswith("@"):
                          continue
                      if name == "field" and secret_path(at[1:]):
                          return f"gh-app api uploading {at[1:]}, a secrets file"
                      body = (gh_query_file(at[1:])
                              if name == "field" and call[0] == "graphql" and key == "query" else None)
                      if body is None:
                          unread = True
                      else:
                          bodies.append(body.lower())
              if api_changes_review(lowered) or any(api_changes_review([b]) for b in bodies):
                  return "the App merging or reviewing through gh-app api; merge with gh-app pr merge, which checks the PR first"
              if unread:
                  raise Unparsable("gh-app api reading its request from a file")
  ```

  If the count after this task isn't `1825`, don't chase the number: list the `FAIL` lines and check that each expects `allow`. Any failing row that expects `ask`, `deny` or `None` is a defect in this task.

## 4. The allow

- [x] 4.1 Directly below `graphql_reads()` (above `def devenv_command`), add `gh_api_reads()`. Protects, each by its own line: the program is spelled `gh-app` exactly, so a path to another program of that name isn't approved; a line the reader gives up on is not a read; the request stays on GitHub's API as the App (no `--hostname`, no `://` endpoint, no header but the two listed) and prints no request (`--verbose`); no filter can read `GH_TOKEN` from the environment, in the short spellings too, which `reads_environment()` skips for `api`; a REST call is GET or HEAD, with fields only when the method is given, since a bare field makes gh POST; a GraphQL call holds a query and no mutation in any `query` field, inline or in the file; no other spelling of `graphql` passes as REST; no `-F` value but the query is read from a file. Verify: the file still runs, same result as after 3.1 (nothing calls it yet).

  ```python
  def gh_api_reads(words):
      """Whether these words are a `gh-app api` call that only reads, with
      the program spelled `gh-app` and every option one gh_api_call knows:

      - REST: no method, or GET or HEAD in any case; fields only with an
        explicit GET or HEAD, which sends them in the query string, and none
        read from a file;
      - GraphQL (the endpoint `graphql`): no method, or POST; at least one
        `query` field, given in the word or as `-F query=@file`
        (gh_query_file), and no mutation in any (graphql_reads). Every other
        field is a variable, and none is read from a file;
      - no `--hostname`, `--input` or `--verbose`, no endpoint that is a full
        URL, no header but GH_API_HEADERS, and no jq or template filter that
        mentions env (the App's GH_TOKEN)."""
      if words[0] != "gh-app" or any(PLACEHOLDER in a for a in words[1:]):
          return False
      call = gh_api_call(words[1:])
      if call is None:
          return False
      endpoint, options = call

      def values(*names):
          return [v for n, v in options if n in names]

      if values("hostname", "input", "verbose"):
          return False
      if any(h.split(":", 1)[0].strip().lower() not in GH_API_HEADERS for h in values("header")):
          return False
      if any("env" in v.lower() for v in values("jq", "template")):
          return False
      methods = [m.upper() for m in values("method")]
      fields = [(n, v.partition("=")[0], v.partition("=")[2]) for n, v in options
                if n in ("field", "raw-field")]
      if endpoint == "graphql":
          if any(m != "POST" for m in methods):
              return False
          queries = []
          for name, key, value in fields:
              if name == "field" and value.startswith("@"):
                  text = gh_query_file(value[1:]) if key == "query" else None
                  if text is None:
                      return False
                  queries.append(text)
              elif key.lower() == "query":
                  queries.append(value)
          return bool(queries) and all(graphql_reads(q) for q in queries)
      if "://" in endpoint or endpoint.strip("/").lower() == "graphql":
          return False
      if any(m not in ("GET", "HEAD") for m in methods) or (fields and not methods):
          return False
      return not any(name == "field" and value.startswith("@") for name, _, value in fields)
  ```

  Note `values("hostname", "input", "verbose")`: `--verbose` carries the value `None`, so the list is `[None]`, which is true. Don't "simplify" it to a test on the values.

- [x] 4.2 In `read_only()`, change `if devenv_query(words):` to `if devenv_query(words) or gh_api_reads(words):`, and change the docstring to:

  ```python
      """Whether this is a READ_ONLY command reading only inside the project,
      a devenv version or help query (devenv_query), which reads nothing, or
      a `gh-app api` call that only reads GitHub (gh_api_reads)."""
  ```

  Don't add `gh-app` to `READ_ONLY`: that set is matched by program name alone in `stage_kind()` and `data_consumer()`. `read_only()` is called only from `approved()`, after `plain_args()`, and `decide()` reaches `approved()` only after every deny and ask rule. Verify: the run ends `1928/1937 passed`. The 9 `FAIL` lines left all expect `allow`, and are what `plain_args()` still refuses: four commands, each bare and wrapped (`gh-app api /repos/o/r/pulls/12`, `gh-app api -Xget repos/o/r/issues`, `gh-app api -XGET repos/o/r/issues -fstate=open`, `gh-app api graphql -Fquery=@queries/threads.graphql -F n=12`), and once, under `{'allow': ['gh-app api *']}`, `gh-app api -X POST /repos/o/r/issues -f title=x`. If the set differs, report the lines rather than adjusting the tests.

- [x] 4.3 In `plain_args()`, three edits. Protects: only the one word that is the endpoint of a line read in full skips the outside-the-project check; every other word, a `--cache` value or a field value included, is still checked, and the secrets check (`secret_named()`, elsewhere) still sees the endpoint. The editor check is skipped only where `gh_api_call()` has matched every option to gh api's own list, which has no editor.

  (a) After the line `text_options = text_options_of(prog, words)`, add:

  ```python
      # `gh-app api`'s endpoint is a path on GitHub, not a file: `/repos/o/r`.
      call = gh_api_call(words[1:]) if prog == "gh-app" else None
      endpoint = call[0] if call else None
  ```

  (b) Change `if any(outside(c) and not scratch(c) for c in option_values(w)):` to `if w != endpoint and any(outside(c) and not scratch(c) for c in option_values(w)):`.

  (c) Change the editor check to:

  ```python
          if (prog in ("gh", "gh-app") and not text and call is None
                  and (w.startswith("--edit") or re.match(r"^-[A-Za-z]*e", w))):
              # An editor waits for a user who isn't there: `-e`, `--editor`,
              # `--edit-last`. A `gh-app api` line read in full has none: an
              # `e` there is in a value (`-Xget`, `-fstate=open`).
              return False
  ```

  Verify: the whole test file passes, `1937/1937 passed`, with no `FAIL` line.

## 5. Documentation

- [x] 5.1 In the module docstring at the top of `packages/claude-guard.py`, in the bullet that starts `- allows a call only when its sequences`, change its last sentence from `Quoted heredoc bodies are data, and redirects to a device or a scratch file outside the project are fine;` (it is wrapped over three lines) to end `... outside the project are fine. A \`gh-app api\` call that only reads (a GET or HEAD, or a GraphQL query with no mutation; see gh_api_reads) needs no rule;`, wrapped at the same width as the lines around it. Verify: the test file still prints `1937/1937 passed`.
- [x] 5.2 In `README.md`, in the `packages/claude-guard.py` row of the table (it starts `| \`packages/claude-guard.py\` | The PreToolUse guard hook:`), after the sentence ending ``any other `devenv` option the guard doesn't know asks.``, insert: ``A `gh-app api` call that only reads needs no rule either: a REST call with no method or an explicit GET or HEAD (fields only with the method given), or `gh-app api graphql` with a `query` that holds no mutation, inline or as `-F query=@file` for a file in scratch or the project, which the guard reads; with `--hostname`, a full-URL endpoint, `--verbose`, a header other than `Accept` or `X-GitHub-Api-Version`, a `--jq` or `--template` filter that mentions `env`, or an option the guard doesn't know, it is left to Claude Code's rules, and `--input` or any other `@file` field asks. A `-F` field that names a secrets file is denied.`` Keep the row on one line. Verify: the row still renders as one table row (no newline added).

## 6. The gate

- [x] 6.1 Run `devenv shell --quiet -- openspec validate guard-readonly-gh-api --strict` and fix anything it reports in this change's files. Verify: it reports the change valid.
- [x] 6.2 Run the gate on its own, `devenv shell --quiet -- scripts/check.sh` (to keep its output, redirect it to `"$TMPDIR/check.log"` and read that; don't pipe it). Verify: it ends `check: all passed`. `build: shell` rebuilds the guard package, which runs the test file again inside the build, where there is no `devenv.nix` beside it (one check fewer).

## Workflow follow-up

- This change closes #110.
- The two open questions in design.md (`repos/o/r/actions/secrets` denied as a secrets path; `submitPullRequestReview` not denied) are each their own issue, if wanted.
- Archive the change after review.
