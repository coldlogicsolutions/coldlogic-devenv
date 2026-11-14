#!/usr/bin/env bash
# Tests for gh-app.sh, run when packages/gh-app.nix builds. By hand:
#
#   devenv shell --quiet -- bash packages/gh-app-test.sh packages/gh-app.sh
#
# Needs bash 4 or later (macOS's /bin/bash is 3.2; the shell's is newer),
# coreutils and jq on PATH, and no network, key or credentials.
# Stand-ins on PATH take the place of gh-app-token (prints `stub-token`;
# fails when the case's token-fail exists) and gh. The gh stand-in logs each
# call to the case's `calls` file, one line per call, and answers from the
# case's files, running the caller's own `--jq` filter over them with jq, so
# the script's filters are what's tested:
#
#   pr view ...            pr.json, or pr-<n>.json for the n-th view of the
#                          case when it exists; fails when neither does, or
#                          when pr-<n>.fail exists
#   api orgs/coldlogicsolutions/teams/developer/memberships/<login>
#                          member-<login>.json; GitHub's 404 when missing
#   api orgs/coldlogicsolutions/teams/developer
#                          team.json; GitHub's 404 when missing
#   (<slug> below is $slug, the PR's repository, as STUB_SLUG)
#   api repos/<slug>/pulls/12/reviews         reviews.json; fails when missing
#   api -X POST repos/<slug>/pulls/12/reviews {"id": 99}; fails when
#                                             approve-fail exists
#   api -X PUT .../reviews/99/dismissals      fails when dismiss-fail exists
#   api repos/<slug>/pulls/12/reviews/99      review-99.json; fails when missing
#   api repos/<slug>/rules/branches/main      rules.json; fails when missing
#   anything else          exits 0
#
# The script is run with the shell options writeShellApplication gives the
# built one (errexit, nounset, pipefail), which it has no `set` line for.
#
# The stand-ins' bodies are single-quoted on purpose: they expand when a
# stand-in runs, not when it is written.
# shellcheck disable=SC2016
set -eu

script="$(cd "$(dirname "${1:?usage: gh-app-test.sh <gh-app.sh>}")" && pwd)/$(basename "$1")"
root="$(mktemp -d)"
root="$(cd "$root" && pwd -P)"
trap 'rm -rf "$root"' EXIT

# Also run by hand inside a session or a shell, which may set these.
unset GH_APP_KEY GH_APP_APPROVER GH_TOKEN GITHUB_TOKEN GH_REPO GH_HOST

bash_bin="$(command -v bash)"
outer_path="$PATH"
passed=0
failed=0
n=0
code=0
out=""

head=1111111111111111111111111111111111111111
old=2222222222222222222222222222222222222222
moved=3333333333333333333333333333333333333333
# The team's organization's repository: the App approves only those.
slug=coldlogicsolutions/r
url="https://github.com/$slug/pull/12"

stubs="$root/stubs"
mkdir -p "$stubs"
printf '#!%s\n%s\n' "$bash_bin" '
: >"$STUB_DIR/token-called"
[ ! -e "$STUB_DIR/token-fail" ] || { echo "gh-app-token: stub failure" >&2; exit 1; }
[ -f "$GH_APP_KEY" ] || { echo "gh-app-token: stub got no key" >&2; exit 1; }
echo stub-token' >"$stubs/gh-app-token"
printf '#!%s\n%s\n' "$bash_bin" '
{
  printf "gh"
  printf " %s" "$@"
  printf "\n"
} >>"$STUB_DIR/calls"
echo "${GH_TOKEN-unset}" >"$STUB_DIR/token"
filter=.
method=GET
endpoint=""
args=("$@")
i=0
while ((i < ${#args[@]})); do
  case "${args[i]}" in
    --jq)
      filter="${args[i + 1]}"
      i=$((i + 2))
      ;;
    -X)
      method="${args[i + 1]}"
      i=$((i + 2))
      ;;
    -f | --json | --repo | --match-head-commit) i=$((i + 2)) ;;
    -*) i=$((i + 1)) ;;
    *)
      if ((i >= 1)) && [ "$1" = api ] && [ -z "$endpoint" ]; then endpoint="${args[i]}"; fi
      i=$((i + 1))
      ;;
  esac
done
not_found() {
  echo "{\"message\":\"Not Found\",\"status\":\"404\"}"
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
}
answer() {
  [ -f "$STUB_DIR/$1" ] || return 1
  jq -r "$filter" "$STUB_DIR/$1"
}
case "$1 ${2-}" in
  "pr view")
    count=$(($(cat "$STUB_DIR/views" 2>/dev/null || echo 0) + 1))
    echo "$count" >"$STUB_DIR/views"
    if [ -e "$STUB_DIR/pr-$count.fail" ]; then
      echo "gh: could not read the pull request" >&2
      exit 1
    elif [ -f "$STUB_DIR/pr-$count.json" ]; then
      answer "pr-$count.json"
    elif ! answer pr.json; then
      echo "gh: no pull requests found" >&2
      exit 1
    fi
    ;;
  "api "*)
    case "$method $endpoint" in
      "GET orgs/coldlogicsolutions/teams/developer/memberships/"*)
        answer "member-${endpoint##*/}.json" || not_found
        ;;
      "GET orgs/coldlogicsolutions/teams/developer") answer team.json || not_found ;;
      "GET repos/$STUB_SLUG/pulls/12/reviews") answer reviews.json || exit 1 ;;
      "POST repos/$STUB_SLUG/pulls/12/reviews")
        [ ! -e "$STUB_DIR/approve-fail" ] || exit 1
        echo "{\"id\": 99, \"state\": \"APPROVED\"}" | jq -r "$filter"
        ;;
      "PUT repos/$STUB_SLUG/pulls/12/reviews/99/dismissals") [ ! -e "$STUB_DIR/dismiss-fail" ] || exit 1 ;;
      "GET repos/$STUB_SLUG/pulls/12/reviews/99") answer review-99.json || exit 1 ;;
      "GET repos/$STUB_SLUG/rules/branches/main") answer rules.json || exit 1 ;;
      *)
        echo "gh stand-in: unexpected api call: $method $endpoint" >&2
        exit 1
        ;;
    esac
    ;;
esac
exit 0' >"$stubs/gh"
chmod +x "$stubs/gh-app-token" "$stubs/gh"

# pr_json <state> <draft> <login> <is_bot> [<head>]: what `gh pr view --json`
# gives for the fields the script asks for.
pr_json() {
  printf '{"url":"%s","state":"%s","isDraft":%s,"headRefOid":"%s","baseRefName":"main","author":{"login":"%s","is_bot":%s}}\n' \
    "$url" "$1" "$2" "${5:-$head}" "$3" "$4"
}
# reviews_json <login>:<STATE>:<commit>...: a PR's reviews, oldest first.
reviews_json() {
  local sep="" r login state commit
  printf '['
  for r in "$@"; do
    IFS=: read -r login state commit <<<"$r"
    printf '%s{"user":{"login":"%s"},"state":"%s","commit_id":"%s"}' "$sep" "$login" "$state" "$commit"
    sep=,
  done
  printf ']\n'
}
app='coldlogic-ai[bot]'

# fresh: a case where `pr approve 12` would succeed: an open PR by derekjw,
# an active member of the team, with the App's comment review on its head.
fresh() {
  n=$((n + 1))
  case_dir="$root/case$n"
  mkdir -p "$case_dir/home"
  : >"$case_dir/key.pem"
  : >"$case_dir/calls"
  pr_json OPEN false derekjw false >"$case_dir/pr.json"
  echo '{"state":"active","role":"member"}' >"$case_dir/member-derekjw.json"
  echo '{"slug":"developer"}' >"$case_dir/team.json"
  reviews_json "$app:COMMENTED:$head" >"$case_dir/reviews.json"
  key="$case_dir/key.pem"
}

# run <args...>: gh-app with the stand-ins first on PATH. Sets $code and
# $out (stdout); stderr goes to the case's `stderr`.
run() {
  code=0
  out="$(
    export STUB_DIR="$case_dir" STUB_SLUG="$slug" HOME="$case_dir/home" GH_APP_KEY="$key"
    export PATH="$stubs:$outer_path"
    "$bash_bin" -o errexit -o nounset -o pipefail "$script" "$@" 2>"$case_dir/stderr"
  )" || code=$?
}

check() {
  name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok   $name"
  else
    failed=$((failed + 1))
    echo "FAIL $name (exit $code; out '$out')"
    echo "     stderr: $(tr '\n' '|' <"$case_dir/stderr")"
    echo "     calls: $(tr '\n' '|' <"$case_dir/calls")"
  fi
}

exits() { [ "$code" = "$1" ]; }
# says <text>: stderr holds the text.
says() {
  local all
  all="$(<"$case_dir/stderr")"
  [[ $all == *"$1"* ]]
}
not_says() { ! says "$1"; }
# called <text>: some gh call's line holds the text.
called() {
  local all
  all="$(<"$case_dir/calls")"
  [[ $all == *"$1"* ]]
}
never() { ! called "$1"; }
# call_is <line>: gh was called with exactly these arguments, once or more.
call_is() {
  local l
  while IFS= read -r l; do
    if [ "$l" = "gh $1" ]; then return 0; fi
  done <"$case_dir/calls"
  return 1
}
no_calls() { [ ! -s "$case_dir/calls" ]; }
# refused <text>: exit 1, the text on stderr, nothing on stdout, and no
# approval, dismissal or merge sent.
refused() {
  exits 1 && says "$1" && [ -z "$out" ] && never "-X POST" && never "-X PUT" && never "pr merge"
}
approve_call="api -X POST repos/$slug/pulls/12/reviews -f event=APPROVE -f commit_id=$head --jq .id"

# ---------------------------------------------------------------- approve --
# (a) the approval, pinned to the head commit the checks read.
fresh
run pr approve 12
check "(a) approve: exit 0" exits 0
check "(a) ... one approval, pinned to the head" call_is "$approve_call"
check "(a) ... says so on stdout" [ "$out" = "gh-app: approved $url at its head commit ${head:0:7}" ]
check "(a) ... nothing on stderr" [ ! -s "$case_dir/stderr" ]
check "(a) ... no dismissal" never "-X PUT"
check "(a) ... the author's membership was read" called "api orgs/coldlogicsolutions/teams/developer/memberships/derekjw"
check "(a) ... as the App" [ "$(<"$case_dir/token")" = stub-token ]
check "(a) ... and nothing reached gh pr approve" never "gh pr approve"

# (a2) the repository, in each spelling and position.
for spelling in "12 -R $slug" "-R $slug 12" "12 --repo $slug" "--repo=$slug 12" "12 -R$slug" "-R$slug 12" "12 -R=$slug"; do
  fresh
  # shellcheck disable=SC2086 # the spelling's words are separate arguments
  run pr approve $spelling
  check "(a2) $spelling: exit 0" exits 0
  check "(a2) $spelling: the PR is read from that repository" called "gh pr view 12 --repo $slug --json"
  check "(a2) $spelling: approved" call_is "$approve_call"
done

# (b) arguments: a number and -R only. Nothing reaches gh.
for bad in "" "abc" "0" "012" "12 13" "$url" "12 --body x" "12 -b x" "12 --approve" "12 --admin" "12 -R" "12 -R=" "--repo" "12 --comment"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr approve $bad
  check "(b) pr approve $bad: refused" exits 1
  check "(b) pr approve $bad: says why" says "gh-app: "
  check "(b) pr approve $bad: gh never ran" no_calls
done

# (b2) help, anywhere among the arguments: usage on stdout, exit 0, no gh,
# no token, and no key needed.
for spelling in "--help" "-h" "12 --help" "-R $slug -h" "abc --help" "12 --body x -h"; do
  fresh
  key="$case_dir/missing.pem"
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr approve $spelling
  check "(b2) pr approve $spelling: exit 0" exits 0
  check "(b2) ... usage on stdout" [ "${out%%$'\n'*}" = "usage: gh-app pr approve <number> [-R owner/repo]" ]
  check "(b2) ... nothing on stderr" [ ! -s "$case_dir/stderr" ]
  check "(b2) ... gh never ran" no_calls
  check "(b2) ... no token asked for" [ ! -e "$case_dir/token-called" ]
done

# (b) the value of -R is a repository, never help: `-R -h` is refused, not
# answered with usage.
for bad in "12 -R -h" "12 -R --help" "-R -h 12" "12 --repo -h" "12 --repo=-h" "12 -R-h" "12 -R=-h" "12 --repo="; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr approve $bad
  check "(b) pr approve $bad: refused" refused "-R needs a repository"
  check "(b) pr approve $bad: no usage" not_says "usage:"
  check "(b) pr approve $bad: gh never ran" no_calls
done

# (c) the PR's state.
for state in CLOSED MERGED; do
  fresh
  pr_json "$state" false derekjw false >"$case_dir/pr.json"
  run pr approve 12
  check "(c) $state: refused" refused "is ${state,,}, not open"
done
fresh
pr_json OPEN true derekjw false >"$case_dir/pr.json"
run pr approve 12
check "(c) draft: refused" refused "is a draft"
fresh
rm "$case_dir/pr.json"
run pr approve 12
check "(c) no such PR: refused with gh's message" refused "no pull requests found"

# (d) the author.
fresh
pr_json OPEN false app/coldlogic-ai true >"$case_dir/pr.json"
run pr approve 12
check "(d) the App's own PR: refused" refused "opened by the App"
check "(d) ... before any team read" never "api orgs/"
fresh
pr_json OPEN false app/dependabot true >"$case_dir/pr.json"
run pr approve 12
check "(d) another bot: refused" refused "app/dependabot, a bot"
check "(d) ... before any team read" never "api orgs/"
fresh
pr_json OPEN false derekjw null >"$case_dir/pr.json"
run pr approve 12
check "(d) is_bot missing: refused as a bot" refused "a bot"
fresh
pr_json OPEN false "" false >"$case_dir/pr.json"
run pr approve 12
check "(d) no author login: refused" refused "can't read $url's author"
fresh
pr_json OPEN false "x/../../y" false >"$case_dir/pr.json"
run pr approve 12
check "(d) a login that isn't one: refused" refused "can't read $url's author"
check "(d) ... and never put in an API path" never "api orgs/"

# (e) team membership, read when the command runs. Fails closed.
fresh
pr_json OPEN false stranger false >"$case_dir/pr.json"
run pr approve 12
check "(e) not on the team: refused" refused "stranger isn't a member of the coldlogicsolutions/developer team"
fresh
echo '{"state":"pending","role":"member"}' >"$case_dir/member-derekjw.json"
run pr approve 12
check "(e) invited, not yet a member: refused" refused "is 'pending', not active"
fresh
rm "$case_dir/member-derekjw.json" "$case_dir/team.json"
run pr approve 12
check "(e) the App can't read the team: refused, naming the permission" refused "the App needs the organization permission Members: read"
check "(e) ... and the team" says "can't read the coldlogicsolutions/developer team"
fresh
echo '{}' >"$case_dir/member-derekjw.json"
run pr approve 12
check "(e) an answer with no state: refused" refused "not active"

# (f) the App's own review on the head commit.
fresh
reviews_json >"$case_dir/reviews.json"
run pr approve 12
check "(f) no review: refused" refused "hasn't reviewed $url at its head commit ${head:0:7}"
fresh
reviews_json "$app:COMMENTED:$old" "$app:APPROVED:$old" >"$case_dir/reviews.json"
run pr approve 12
check "(f) reviewed and approved an earlier commit only: refused" refused "hasn't reviewed"
fresh
reviews_json "derekjw:COMMENTED:$head" "derekjw:APPROVED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) someone else's review on the head: refused" refused "hasn't reviewed"
fresh
reviews_json "$app:PENDING:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a review not yet submitted: refused" refused "hasn't reviewed"
fresh
reviews_json "$app:CHANGES_REQUESTED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) the App requested changes: refused" refused "requested changes"
fresh
reviews_json "$app:CHANGES_REQUESTED:$head" "$app:COMMENTED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) ... and a comment after it (a thread reply) doesn't take it back" refused "requested changes"
fresh
reviews_json "$app:DISMISSED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) only a dismissed review on the head: refused as unreviewed" refused "hasn't reviewed $url at its head commit ${head:0:7}; review it first"
fresh
reviews_json "$app:CHANGES_REQUESTED:$head" "$app:DISMISSED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a change request, then some other review dismissed: the change request stands" refused "requested changes"
fresh
rm "$case_dir/reviews.json"
run pr approve 12
check "(f) the reviews can't be read: refused" exits 1
check "(f) ... with no approval" never "-X POST"
# What passes.
fresh
reviews_json "$app:CHANGES_REQUESTED:$old" "derekjw:CHANGES_REQUESTED:$head" "$app:COMMENTED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) changes requested on an earlier commit, a comment review on the head: approved" call_is "$approve_call"
fresh
reviews_json "$app:DISMISSED:$head" "$app:COMMENTED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a dismissed review, then a comment review: approved" call_is "$approve_call"
# A deleted account's review has a null user, and one may lack its commit.
fresh
printf '[{"user":null,"state":"CHANGES_REQUESTED","commit_id":"%s"},{"user":{"login":"%s"},"state":"CHANGES_REQUESTED","commit_id":null},{"user":{"login":"%s"},"state":"COMMENTED","commit_id":"%s"}]\n' \
  "$head" "$app" "$app" "$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a review with a null user, one with no commit: exit 0" exits 0
check "(f) ... approved" call_is "$approve_call"
fresh
printf '[{"user":null,"state":"COMMENTED","commit_id":"%s"}]\n' "$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) only a null user's review: refused" refused "hasn't reviewed"
# A dismissed review no longer stands, whatever it was: GitHub lists a
# dismissed change request, or approval, as DISMISSED.
fresh
reviews_json "$app:COMMENTED:$head" "$app:DISMISSED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a comment, then a dismissed change request: exit 0" exits 0
check "(f) ... approved" call_is "$approve_call"
fresh
# What a withdrawn approval leaves: the comment review and a dismissed approval.
reviews_json "$app:COMMENTED:$head" "$app:DISMISSED:$head" "$app:DISMISSED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a comment, then a withdrawn approval: approves again" call_is "$approve_call"
fresh
reviews_json "$app:COMMENTED:$head" "$app:DISMISSED:$head" "$app:CHANGES_REQUESTED:$head" >"$case_dir/reviews.json"
run pr approve 12
check "(f) a dismissed review, then a change request that stands: refused" refused "requested changes"

# (g) already approved at the head: success, and no second approval.
for later in "" "$app:COMMENTED:$head"; do
  fresh
  # Empty means no further review; quoted, as `[bot]` is a glob.
  reviews_json "$app:COMMENTED:$head" "$app:APPROVED:$head" ${later:+"$later"} >"$case_dir/reviews.json"
  run pr approve 12
  check "(g) already approved${later:+, then a comment}: exit 0" exits 0
  check "(g) ... says so" [ "$out" = "gh-app: $url is already approved by the App at its head commit ${head:0:7}" ]
  check "(g) ... and sends nothing" never "-X POST"
done

# (h) GitHub refuses the approval.
fresh
: >"$case_dir/approve-fail"
run pr approve 12
check "(h) approval fails: exit 1" exits 1
check "(h) ... says so" says "GitHub didn't take the approval"
check "(h) ... nothing on stdout" [ -z "$out" ]

# (i) the head moves between the checks and the approval: withdrawn.
fresh
pr_json OPEN false derekjw false "$moved" >"$case_dir/pr-2.json"
run pr approve 12
check "(i) head moved: exit 1" exits 1
check "(i) ... the approval was for the commit checked" call_is "$approve_call"
check "(i) ... and was dismissed" called "api -X PUT repos/$slug/pulls/12/reviews/99/dismissals"
check "(i) ... says so, and that the new head needs a review" says "the approval was withdrawn; review the new head, then approve again"
check "(i) ... nothing on stdout" [ -z "$out" ]
fresh
pr_json OPEN false derekjw false "$moved" >"$case_dir/pr-2.json"
: >"$case_dir/dismiss-fail"
run pr approve 12
check "(i) head moved, dismissal fails: exit 1" exits 1
check "(i) ... read the review to tell" called "api repos/$slug/pulls/12/reviews/99"
check "(i) ... says to dismiss by hand" says "could NOT be withdrawn"
# The dismissal fails because the ruleset already dismissed the stale
# approval on the push: withdrawn all the same.
fresh
pr_json OPEN false derekjw false "$moved" >"$case_dir/pr-2.json"
: >"$case_dir/dismiss-fail"
echo '{"id":99,"state":"DISMISSED"}' >"$case_dir/review-99.json"
run pr approve 12
check "(i) head moved, already dismissed by the ruleset: exit 1" exits 1
check "(i) ... says it was withdrawn, and that the new head needs a review" says "the approval was withdrawn; review the new head, then approve again"
check "(i) ... doesn't say to dismiss by hand" not_says "could NOT be withdrawn"
# The dismissal fails and the approval still stands: by hand.
fresh
pr_json OPEN false derekjw false "$moved" >"$case_dir/pr-2.json"
: >"$case_dir/dismiss-fail"
echo '{"id":99,"state":"APPROVED"}' >"$case_dir/review-99.json"
run pr approve 12
check "(i) head moved, dismissal fails, approval stands: exit 1" exits 1
check "(i) ... says to dismiss by hand" says "could NOT be withdrawn"
check "(i) ... doesn't say it was withdrawn" not_says "the approval was withdrawn"
# Closed, made a draft, or unreadable between the checks and the approval.
# The comment review still counts at the same head, so approving again works
# as soon as the PR passes again.
for change in closed draft unreadable; do
  fresh
  case "$change" in
    closed) pr_json CLOSED false derekjw false >"$case_dir/pr-2.json"; again="approve again once it's open" ;;
    draft) pr_json OPEN true derekjw false >"$case_dir/pr-2.json"; again="approve again once it's ready for review" ;;
    unreadable) : >"$case_dir/pr-2.fail"; again="approve again" ;;
  esac
  run pr approve 12
  check "(i) $change while approving: exit 1" exits 1
  check "(i) ... the approval was dismissed" called "api -X PUT repos/$slug/pulls/12/reviews/99/dismissals"
  check "(i) ... says so, and what to do" says "the approval was withdrawn; $again"
  check "(i) ... nothing on stdout" [ -z "$out" ]
done
fresh
pr_json OPEN false derekjw false >"$case_dir/pr-2.json"
run pr approve 12
check "(i) unchanged at the second read: approved, no dismissal" never "-X PUT"
check "(i) ... and the PR was read twice" [ "$(<"$case_dir/views")" = 2 ]

# (j) what gh pr view gives isn't the shape expected: nothing is sent.
fresh
pr_json OPEN false derekjw false "not-a-commit" >"$case_dir/pr.json"
run pr approve 12
check "(j) a head that isn't a commit id: refused" refused "can't read $url's head commit"
fresh
echo '{"url":"https://example.com/o/r/pull/12","state":"OPEN","isDraft":false,"headRefOid":"'"$head"'","author":{"login":"derekjw","is_bot":false}}' >"$case_dir/pr.json"
run pr approve 12
check "(j) a URL that isn't a GitHub PR: refused" refused "unexpected URL"

# (o) only the team's organization's PRs: elsewhere the team check means
# nothing. Owner names ignore case.
fresh
url_kept="$url"
url=https://github.com/o/r/pull/12
pr_json OPEN false derekjw false >"$case_dir/pr.json"
run pr approve 12
check "(o) a PR in another owner's repository: refused" refused "is in o's repository, not coldlogicsolutions's"
check "(o) ... before any team or review read" never "api "
fresh
url=https://github.com/coldlogicsolutions-x/r/pull/12
pr_json OPEN false derekjw false >"$case_dir/pr.json"
run pr approve 12
check "(o) an owner that only starts with the org's name: refused" refused "not coldlogicsolutions's"
fresh
slug_kept="$slug"
slug=ColdLogicSolutions/r
url="https://github.com/$slug/pull/12"
pr_json OPEN false derekjw false >"$case_dir/pr.json"
run pr approve 12
check "(o) the org's name in another case: approved" exits 0
check "(o) ... in that repository" called "api -X POST repos/ColdLogicSolutions/r/pulls/12/reviews -f event=APPROVE"
slug="$slug_kept"
url="$url_kept"

# (k) pr review --approve never reaches gh; other reviews pass through.
for spelling in "--approve" "-a" "-ab LGTM" "--approve=true" "--approve --body x" "-R o/r --approve"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review 12 $spelling
  check "(k) pr review 12 $spelling: refused" refused "approve with gh-app pr approve"
  check "(k) pr review 12 $spelling: gh never ran" no_calls
done
fresh
run pr review 12 --comment --body "Looks right; -a isn't used."
check "(k) a comment review: exit 0" exits 0
check "(k) ... passed to gh as given" call_is "pr review 12 --comment --body Looks right; -a isn't used."
fresh
run pr review 12 --request-changes --body-file /tmp/x.md
check "(k) a change request: passed to gh as given" call_is "pr review 12 --request-changes --body-file /tmp/x.md"
# Read as gh's flag parser reads them: an approval in a cluster or with `=`,
# with a value after it, or after an option given its value with `=`.
for spelling in "-a=true" "-cab x" "--body=x -a" "--body-file=x --approve" "-b=x -ca"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review 12 $spelling
  check "(k) pr review 12 $spelling: refused" refused "approve with gh-app pr approve"
  check "(k) pr review 12 $spelling: gh never ran" no_calls
done
fresh
run pr review 12 -ab"looks good"
check "(k) -ab\"looks good\" (a value with a space): refused" refused "refusing pr review -ablooks good"
# A body or file name that looks like an option is a value, not an approval,
# and so is anything after `--`.
for body in "-all good" "--approve-ish" "-a"; do
  for opt in --body -b; do
    fresh
    run pr review 12 --comment "$opt" "$body"
    check "(k) pr review 12 --comment $opt '$body': passed to gh" call_is "pr review 12 --comment $opt $body"
  done
done
for spelling in "-ba" "-b=-a" "--body=-a" "-F -a" "-Fa" "-R -a --body x" "--repo -a --body x" "--body x -- --approve"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review 12 --comment $spelling
  check "(k) pr review 12 --comment $spelling: passed to gh" call_is "pr review 12 --comment $spelling"
done
# With no mode gh asks which review to give, offering Approve: refused.
for spelling in "" "--body x" "-b x" "-c=false --body x" "--comment=false --body x" "-r=false -b x" "-b -c" "--body --comment" "--body x -- --comment" "--body -h" "-b --help" "-- --help" "--help=true" "--comment=0 --body x" "--comment=f --body x" "--comment=yes --body x" "--request-changes=False -b x" "-c=0 -b x" "-r=no -b x" "-c= -b x" "--comment --comment=false -b x" "-c -c=false -b x" "--request-changes --request-changes=0 -b x" "-rc -c=f -r=false -b x"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review 12 $spelling
  check "(k) pr review 12 $spelling (no mode): refused" refused "pr review needs --comment or --request-changes"
  check "(k) pr review 12 $spelling: gh never ran" no_calls
done
for spelling in "-c -b x" "-cb x" "-r -b x" "-rbx" "--comment=true --body x" "-c=true -b x" "--request-changes=true -F f" "-b x --comment" "--comment=1 --body x" "--comment=t --body x" "--comment=T --body x" "--comment=TRUE --body x" "--request-changes=True -b x" "-c=1 -b x" "-r=t -b x" "-c=TRUE -b x" "-c=True -b x" "--comment=false --comment -b x" "-c=false -r -b x" "--comment --comment=false --request-changes -b x" "-cr=false -b x"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review 12 $spelling
  check "(k) pr review 12 $spelling (a mode): passed to gh" call_is "pr review 12 $spelling"
done
# Help, anywhere it isn't a value, only prints help: passed to plain gh,
# with no key needed and no token asked for.
for spelling in "--help" "-h" "12 --help" "12 -h" "12 --body x --help" "-R o/r 12 -h"; do
  fresh
  key="$case_dir/missing.pem"
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review $spelling
  check "(k) pr review $spelling (help): exit 0" exits 0
  check "(k) pr review $spelling (help): passed to gh" call_is "pr review $spelling"
  check "(k) pr review $spelling (help): no key error" not_says "private key not found"
  check "(k) pr review $spelling (help): no token asked for" [ ! -e "$case_dir/token-called" ]
  check "(k) pr review $spelling (help): gh got no App token" [ "$(<"$case_dir/token")" = unset ]
done
for spelling in "12 --help --approve" "12 -h -a"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run pr review $spelling
  check "(k) pr review $spelling: still refused as an approval" refused "approve with gh-app pr approve"
done

# ------------------------------------------------------------------ merge --
# merge_case: the App's own open PR, approved by derekjw at its head.
merge_case() {
  fresh
  pr_json OPEN false app/coldlogic-ai true >"$case_dir/pr.json"
  reviews_json "derekjw:COMMENTED:$head" "derekjw:APPROVED:$head" "$app:COMMENTED:$head" >"$case_dir/reviews.json"
  echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true}}]' >"$case_dir/rules.json"
}
merge_case
run pr merge 12 --squash
check "(m) merge of the App's approved PR: exit 0" exits 0
check "(m) ... pinned to the head" call_is "pr merge 12 --squash --match-head-commit $head"
merge_case
pr_json OPEN false derekjw false >"$case_dir/pr.json"
run pr merge 12 --squash
check "(m) someone else's PR: refused" refused "was opened by derekjw, not the App"
merge_case
pr_json OPEN true app/coldlogic-ai true >"$case_dir/pr.json"
run pr merge 12 --squash
check "(m) draft: refused" refused "is a draft"
merge_case
run pr merge 12 --squash --admin
check "(m) --admin: refused" refused "refusing --admin"
check "(m) ... before gh runs" no_calls
merge_case
reviews_json "derekjw:APPROVED:$old" "$app:APPROVED:$head" >"$case_dir/reviews.json"
run pr merge 12 --squash
check "(m) approved before the last push, and the App's approval doesn't count: refused" refused "derekjw hasn't approved"
merge_case
reviews_json "derekjw:APPROVED:$head" "derekjw:CHANGES_REQUESTED:$head" >"$case_dir/reviews.json"
run pr merge 12 --squash
check "(m) changes requested after the approval: refused" refused "derekjw hasn't approved"
merge_case
run pr merge 12 --squash --match-head-commit "$old"
check "(m) --match-head-commit naming another commit: refused" refused "isn't $url's head"
merge_case
run pr merge 12 --squash --match-head-commit "$head"
check "(m) --match-head-commit naming the head: passed as given" call_is "pr merge 12 --squash --match-head-commit $head"
# --auto: the ruleset instead of the approval.
merge_case
reviews_json >"$case_dir/reviews.json"
run pr merge --auto --squash 12
check "(m) --auto with the approval rule: exit 0" exits 0
check "(m) ... pinned to the head" call_is "pr merge --auto --squash 12 --match-head-commit $head"
check "(m) ... the rules were read" called "api repos/$slug/rules/branches/main"
merge_case
echo '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":false}}]' >"$case_dir/rules.json"
run pr merge --auto --squash 12
check "(m) --auto, approvals not dismissed on push: refused" refused "turn on auto-merge by hand"
merge_case
rm "$case_dir/rules.json"
run pr merge --auto --squash 12
check "(m) --auto, rules unreadable: refused" exits 1
check "(m) ... nothing merged" never "pr merge"
merge_case
pr_json OPEN false derekjw false >"$case_dir/pr.json"
run pr merge --auto --squash 12
check "(m) --auto on someone else's PR: refused" refused "not the App"
merge_case
run pr merge --disable-auto 12
check "(m) --disable-auto: passed straight through" call_is "pr merge --disable-auto 12"
check "(m) ... with no PR read" never "pr view"

# ------------------------------------------------------------ everything else --
fresh
run issue view 5 --json title
check "(p) another command: exit 0" exits 0
check "(p) ... passed to gh as given" call_is "issue view 5 --json title"
check "(p) ... as the App" [ "$(<"$case_dir/token")" = stub-token ]
check "(p) ... and only that" [ "$(wc -l <"$case_dir/calls")" -eq 1 ]

fresh
key="$case_dir/missing.pem"
run pr approve 12
check "(q) no key: exit 1" exits 1
check "(q) ... names the path" says "gh-app: private key not found at $case_dir/missing.pem"
check "(q) ... nothing on stdout" [ -z "$out" ]
check "(q) ... gh never ran" no_calls
fresh
: >"$case_dir/token-fail"
run pr approve 12
check "(q) no token: exit 1" exits 1
check "(q) ... gh never ran" no_calls

# (r) an option before the command or subcommand would hide it from the
# checks: refused. Help passes through.
for spelling in "pr -R o/r review 12 --approve" "pr --repo=o/r approve 12" "pr -R o/r merge 12 --squash" "-R o/r pr review 12 --approve" "--repo o/r issue view 5"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run $spelling
  check "(r) $spelling: refused" refused "before the subcommand; put options after it"
  check "(r) $spelling: gh never ran" no_calls
done
for spelling in "pr --help" "pr -h" "--help" "--version"; do
  fresh
  # shellcheck disable=SC2086 # the words are separate arguments
  run $spelling
  check "(r) $spelling: passed to gh" call_is "$spelling"
done

# (s) refusals by the arguments alone need no key and mint no token.
for spelling in "pr review 12 --approve" "pr approve abc" "pr approve 12 --body x" "pr -R o/r review 12"; do
  for missing in key token; do
    fresh
    if [ "$missing" = key ]; then key="$case_dir/missing.pem"; else : >"$case_dir/token-fail"; fi
    # shellcheck disable=SC2086 # the words are separate arguments
    run $spelling
    check "(s) $spelling, no $missing: refused" exits 1
    check "(s) ... by its arguments" says "gh-app: "
    check "(s) ... not for the $missing" eval '! says "private key not found" && ! says "stub failure"'
    check "(s) ... gh never ran" no_calls
  done
done

echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
