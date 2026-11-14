# Runs a GitHub CLI command as the coldlogic-ai App instead of the owner's
# personal account: sessions open PRs and issues, and comment, as the App.
#
# Example:
#   gh-app issue create --title "foo"
#   gh-app pr comment 123 --body "approved"
#   gh-app pr merge 123 --squash
#   gh-app pr merge 123 --auto --squash
#   gh-app pr review 123 --comment --body-file "$TMPDIR/review.md"
#   gh-app pr approve 123
#
# `gh-app pr merge` merges only a PR the App opened, that isn't a draft, and
# whose head commit the approver (GH_APP_APPROVER, default derekjw) approved
# last. GitHub's ruleset requires the approval too; this adds the author, so
# a session can't merge someone else's approved PR. `--admin` is refused.
#
# `--auto` skips the approval check, so auto-merge can be turned on as soon
# as the PR opens: GitHub then merges only once the ruleset is satisfied.
# So it checks the ruleset instead, and refuses unless the base branch's
# rules require an approval and dismiss it when new commits are pushed. The
# author and draft checks, and pinning the head commit, still apply.
# `--disable-auto` merges nothing and is passed through.
#
# `gh-app pr approve <number> [-R owner/repo]` is the only way the App
# approves, and it is not a gh command: nothing of it reaches `gh pr`. It
# approves a developer's PR the App has reviewed, and refuses unless the PR
# is open and not a draft, its author is a person who is an active member of
# the coldlogicsolutions `developer` team (read when it runs; that needs the
# App's organization permission Members: read), and the App has a submitted
# review on the PR's head commit with no change request of its own standing
# there. The approval is pinned to that commit; if meanwhile the head moved
# or the PR was closed or made a draft, it is withdrawn. The App never
# approves its own PRs, so with the ruleset's one required approval a
# developer's PR needs the App and the App's needs a developer.
# `gh-app pr review --approve` is refused: it would skip all of this. So is
# an option before the command or subcommand (`gh-app pr -R o/r review`),
# which would hide the subcommand from these checks.
#
# If the App's private key is not present, this exits with a clear error
# message on stderr.

# Refusals by the arguments alone come first: they need no key or network.

# gh takes options before the command or subcommand too (`gh pr -R o/r
# review 12 --approve`), where the checks below wouldn't see the
# subcommand, so they go after it. Help and the version change nothing.
for arg in "${1:-}" "${2:-}"; do
  if [[ "$arg" == -* && "$arg" != -h && "$arg" != --help && "$arg" != --version ]]; then
    echo "gh-app: refusing $arg before the subcommand; put options after it (gh-app pr <subcommand> <number> -R owner/repo)" >&2
    exit 1
  fi
  [[ "$arg" == pr ]] || break
done

# pflag_true <value>: whether pflag reads a boolean option's `=value` as
# true. Anything it reads as false, or rejects, names no mode.
pflag_true() {
  case "$1" in
    1 | t | T | true | TRUE | True) return 0 ;;
  esac
  return 1
}

# review_words <args...>: reads gh's `pr review` words as gh's flag parser
# reads them, and prints the review they ask for, first match winning:
# `approve <word>`, with the word that approves; `comment` or `changes`, a
# review that doesn't (`--comment`, `--request-changes`, `c` or `r` in a
# cluster); `help`, a `-h` or `--help` that isn't a value; or `none`. As in
# pflag, a mode's last occurrence wins, so `--comment --comment=false` names
# none. Both modes set is left to gh, which refuses it ("need exactly
# one"). `--` ends the options. A
# value-taking option's value is skipped, so a body such as `-all good`
# isn't an option; in a cluster, the letters before `=` are read in turn: `a`
# approves, and after `b`, `F` or `R` the rest is its value (`-ab LGTM`
# approves, `-ba` is the body `a`). A value after `=` belongs to the last
# letter, so `-c=false` names no mode.
review_words() {
  local skip=0 a letters i set_to comment="" changes="" help=""
  for a in "$@"; do
    if ((skip)); then
      skip=0
      continue
    fi
    case "$a" in
      --) break ;;
      # Help, not an option's value: gh prints it and reviews nothing.
      -h | --help) help="$a" ;;
      --approve | --approve=*)
        echo "approve $a"
        return 0
        ;;
      --comment) comment="$a" ;;
      --request-changes) changes="$a" ;;
      --comment=*)
        comment=""
        if pflag_true "${a#*=}"; then comment="$a"; fi
        ;;
      --request-changes=*)
        changes=""
        if pflag_true "${a#*=}"; then changes="$a"; fi
        ;;
      --body | --body-file | --repo) skip=1 ;;
      --*) ;;
      -?*)
        letters="${a#-}"
        letters="${letters%%=*}"
        for ((i = 0; i < ${#letters}; i++)); do
          case "${letters:i:1}" in
            a)
              echo "approve $a"
              return 0
              ;;
            c | r)
              # Only the last letter takes the `=` value; any other is true.
              set_to="$a"
              if ((i + 1 == ${#letters})) && [[ "$a" == *=* ]] && ! pflag_true "${a#*=}"; then
                set_to=""
              fi
              if [[ "${letters:i:1}" == c ]]; then comment="$set_to"; else changes="$set_to"; fi
              ;;
            b | F | R)
              if ((i + 1 == ${#letters})) && [[ "$a" != *=* ]]; then skip=1; fi
              break
              ;;
          esac
        done
        ;;
    esac
  done
  if [[ -n "$comment" ]]; then
    echo comment
  elif [[ -n "$changes" ]]; then
    echo changes
  elif [[ -n "$help" ]]; then
    echo help
  else
    echo none
  fi
}

if [[ "${1:-}" == pr && "${2:-}" == review ]]; then
  review_kind="$(review_words "${@:3}")"
  case "$review_kind" in
    # An approval goes through `pr approve` below, which checks the PR first.
    approve\ *)
      echo "gh-app: refusing pr review ${review_kind#approve }; approve with gh-app pr approve <number>, which checks the PR first" >&2
      exit 1
      ;;
    # With no mode gh asks which review to give, and one answer approves;
    # with help it only prints help.
    none)
      echo "gh-app: pr review needs --comment or --request-changes, with a body; without one gh asks, offering to approve" >&2
      exit 1
      ;;
    # Help only, with no mode: gh prints help and calls nothing, so it needs
    # no key or token.
    help) exec gh "$@" ;;
  esac
fi

if [[ "${1:-}" == pr && "${2:-}" == approve ]]; then
  # gh has no pr approve, so gh-app answers help itself, needing no token.
  # The word after -R or --repo is its value, never help.
  skip=""
  for arg in "${@:3}"; do
    if [[ -n "$skip" ]]; then
      skip=""
      continue
    fi
    if [[ "$arg" == -R || "$arg" == --repo ]]; then
      skip=1
    elif [[ "$arg" == -h || "$arg" == --help ]]; then
      echo "usage: gh-app pr approve <number> [-R owner/repo]"
      echo
      echo "Approve a PR as coldlogic-ai[bot], pinned to its head commit. Refused unless"
      echo "the PR is in a coldlogicsolutions repository, open and not a draft, its author"
      echo "is an active member of the developer team, and the App has reviewed the head"
      echo "commit (gh-app pr review <number> --comment) with no change request standing."
      exit 0
    fi
  done
  number=""
  repo=()
  args=("${@:3}")
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg="${args[i]}"
    case "$arg" in
      -R | --repo)
        if ((i + 1 >= ${#args[@]})); then
          echo "gh-app: $arg needs a repository" >&2
          exit 1
        fi
        repo=(--repo "${args[i + 1]}")
        i=$((i + 1))
        ;;
      --repo=*) repo=(--repo "${arg#--repo=}") ;;
      # pflag's attached forms: the rest of the word, past an `=`, is the
      # repository (`-Ro/r`, `-R=o/r`).
      -R=?* | -R[!=]*)
        arg="${arg#-R}"
        repo=(--repo "${arg#=}")
        ;;
      # No other option: none may reach gh, and an approval takes no body.
      -*)
        echo "gh-app: pr approve takes a PR number and -R owner/repo, not $arg" >&2
        exit 1
        ;;
      *)
        if [[ -n "$number" ]]; then
          echo "gh-app: pr approve takes one PR number, not $number and $arg" >&2
          exit 1
        fi
        number="$arg"
        ;;
    esac
  done
  # A repository is owner/repo, never empty or an option (`-R -h`).
  if ((${#repo[@]})) && [[ -z "${repo[1]}" || "${repo[1]}" == -* ]]; then
    echo "gh-app: -R needs a repository, not '${repo[1]}'" >&2
    exit 1
  fi
  # A number only: a branch name or a URL could name another PR than the
  # one the session reviewed.
  if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
    echo "gh-app: usage: gh-app pr approve <number> [-R owner/repo]" >&2
    exit 1
  fi
fi

gh_app_key="${GH_APP_KEY:-$HOME/.config/github/coldlogic-ai.pem}"

if [[ ! -f "$gh_app_key" ]]; then
  echo "gh-app: private key not found at $gh_app_key (App identity not configured)" >&2
  exit 1
fi

# gh-app-token prints a clear error message on stderr if it fails.
if ! token="$(GH_APP_KEY="$gh_app_key" gh-app-token)"; then
  exit 1
fi

# Exported, not passed through `env`, so the token never appears in argv.
export GH_TOKEN="$token"

if [[ "${1:-}" == pr && "${2:-}" == approve ]]; then
  # Fixed, not read from the environment: a session can't point the checks
  # at another team or another reviewer.
  team_org=coldlogicsolutions
  team=developer
  app_author=app/coldlogic-ai
  app_reviewer='coldlogic-ai[bot]'

  # The author's login is last: it alone can be empty (a deleted account),
  # and an empty field in the middle would shift the ones after it.
  if ! pr="$(gh pr view "$number" "${repo[@]}" --json url,state,isDraft,headRefOid,author \
    --jq '[.url, .state, (.isDraft|tostring), .headRefOid, (.author.is_bot|tostring), .author.login] | @tsv')"; then
    exit 1
  fi
  IFS=$'\t' read -r url state draft head bot author <<<"$pr"
  # Everything below goes into an API path or a message: refuse what isn't
  # the shape GitHub gives.
  if [[ ! "$url" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([1-9][0-9]*)$ ]]; then
    echo "gh-app: can't read PR $number: unexpected URL '$url'" >&2
    exit 1
  fi
  slug="${BASH_REMATCH[1]}"
  pull="${BASH_REMATCH[2]}"
  # The team check means something only for the team's organization's
  # repositories. GitHub's owner names ignore case.
  owner="${slug%%/*}"
  if [[ "${owner,,}" != "${team_org,,}" ]]; then
    echo "gh-app: $url is in $owner's repository, not $team_org's; the App approves only $team_org's PRs" >&2
    exit 1
  fi
  if [[ ! "$head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "gh-app: can't read $url's head commit" >&2
    exit 1
  fi
  if [[ "$state" != OPEN ]]; then
    echo "gh-app: $url is ${state,,}, not open" >&2
    exit 1
  fi
  if [[ "$draft" != false ]]; then
    echo "gh-app: $url is a draft" >&2
    exit 1
  fi
  if [[ "$author" == "$app_author" ]]; then
    echo "gh-app: $url was opened by the App, which doesn't approve its own PRs; a developer approves it" >&2
    exit 1
  fi
  # Anything but a plain `false` counts as a bot.
  if [[ "$bot" != false ]]; then
    echo "gh-app: $url was opened by ${author:-an unknown account}, a bot; the App approves only developers' PRs" >&2
    exit 1
  fi
  if [[ ! "$author" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "gh-app: can't read $url's author '$author'" >&2
    exit 1
  fi

  # The author must be on the developer team now, not when the PR opened.
  # Fails closed: GitHub answers 404 both for someone not on the team and
  # when the App may not read teams, so a second read tells which to say.
  if ! membership="$(gh api "orgs/$team_org/teams/$team/memberships/$author" --jq .state)"; then
    if gh api "orgs/$team_org/teams/$team" --silent >/dev/null 2>&1; then
      echo "gh-app: $author isn't a member of the $team_org/$team team; the App approves only its members' PRs" >&2
    else
      echo "gh-app: can't read the $team_org/$team team to check $author: the App needs the organization permission Members: read (or GitHub can't be reached)" >&2
    fi
    exit 1
  fi
  if [[ "$membership" != active ]]; then
    echo "gh-app: $author's membership of the $team_org/$team team is '$membership', not active" >&2
    exit 1
  fi

  # The App's own submitted reviews on the head commit, oldest first.
  reviews_api="repos/$slug/pulls/$pull/reviews"
  if ! reviews="$(gh api --paginate "$reviews_api" \
    --jq ".[] | select((.user.login // \"\") == \"$app_reviewer\" and .state != \"PENDING\" and (.commit_id // \"\") == \"$head\") | .state")"; then
    exit 1
  fi
  last=""
  decided=""
  while IFS= read -r review; do
    # A dismissed review no longer stands: neither a change request someone
    # dismissed nor an approval this command withdrew counts.
    [[ -n "$review" && "$review" != DISMISSED ]] || continue
    last="$review"
    # A reply in a review thread is a COMMENTED review too, so a comment
    # after a change request doesn't take it back; a dismissal does, and so
    # do new commits.
    if [[ "$review" == APPROVED || "$review" == CHANGES_REQUESTED ]]; then
      decided="$review"
    fi
  done <<<"$reviews"
  if [[ -z "$last" ]]; then
    echo "gh-app: the App hasn't reviewed $url at its head commit ${head:0:7}; review it first (gh-app pr review $pull --comment)" >&2
    exit 1
  fi
  if [[ "$decided" == CHANGES_REQUESTED ]]; then
    echo "gh-app: the App requested changes on $url at its head commit ${head:0:7}; that stands until new commits are reviewed or it is dismissed" >&2
    exit 1
  fi
  if [[ "$decided" == APPROVED ]]; then
    echo "gh-app: $url is already approved by the App at its head commit ${head:0:7}"
    exit 0
  fi
  if [[ "$last" != COMMENTED ]]; then
    echo "gh-app: the App's last review of $url at its head commit ${head:0:7} is ${last,,}; review it again first" >&2
    exit 1
  fi

  # Approves only the commit checked.
  if ! review_id="$(gh api -X POST "$reviews_api" -f event=APPROVE -f commit_id="$head" --jq .id)"; then
    echo "gh-app: GitHub didn't take the approval of $url" >&2
    exit 1
  fi
  # A push, a close or a move to draft between the checks and the approval:
  # what GitHub does with an approval for an earlier commit isn't known, and
  # the PR no longer passes the checks, so it is taken back. So is one for a
  # PR that can't be read again.
  # The withdrawn approval is DISMISSED, which the checks ignore, so the
  # App's comment review still counts at the same head; a new head needs its
  # own review.
  changed=""
  again="approve again"
  if ! now="$(gh pr view "$number" "${repo[@]}" --json state,isDraft,headRefOid \
    --jq '[.state, (.isDraft|tostring), .headRefOid] | @tsv')"; then
    changed=" couldn't be read again"
  else
    IFS=$'\t' read -r now_state now_draft now_head <<<"$now"
    if [[ "$now_head" != "$head" ]]; then
      changed="'s head moved from ${head:0:7}"
      again="review the new head, then approve again"
    elif [[ "$now_state" != OPEN ]]; then
      changed=" was ${now_state,,}"
      again="approve again once it's open"
    elif [[ "$now_draft" != false ]]; then
      changed=" became a draft"
      again="approve again once it's ready for review"
    fi
  fi
  if [[ -n "$changed" ]]; then
    # A ruleset that dismisses stale approvals may have dismissed it on the
    # push already, and then the dismissal fails: read the review to tell.
    if [[ "$review_id" =~ ^[0-9]+$ ]] && { gh api -X PUT "$reviews_api/$review_id/dismissals" --silent \
      -f event=DISMISS -f message="The pull request changed at ${head:0:7} while this approval was being submitted." ||
      [[ "$(gh api "$reviews_api/$review_id" --jq '(.state // "")' 2>/dev/null)" == DISMISSED ]]; }; then
      echo "gh-app: $url$changed while it was being approved, so the approval was withdrawn; $again" >&2
    else
      echo "gh-app: $url$changed while it was being approved, and the approval could NOT be withdrawn: dismiss the App's review by hand" >&2
    fi
    exit 1
  fi
  echo "gh-app: approved $url at its head commit ${head:0:7}"
  exit 0
fi

if [[ "${1:-}" == pr && "${2:-}" == merge ]]; then
  approver="${GH_APP_APPROVER:-derekjw}"
  selector=()
  repo=()
  match=""
  auto=0
  disable=0
  args=("${@:3}")
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg="${args[i]}"
    case "$arg" in
      --admin | --admin=*)
        echo "gh-app: refusing --admin; the PR must be approved" >&2
        exit 1
        ;;
      -R | --repo)
        repo=(--repo "${args[i + 1]:-}")
        i=$((i + 1))
        ;;
      --repo=*) repo=(--repo "${arg#--repo=}") ;;
      --auto) auto=1 ;;
      --disable-auto) disable=1 ;;
      # Options that take a value, so it isn't read as the PR.
      --match-head-commit)
        match="${args[i + 1]:-}"
        i=$((i + 1))
        ;;
      --match-head-commit=*) match="${arg#--match-head-commit=}" ;;
      -b | --body | -F | --body-file | -t | --subject | -A | --author-email) i=$((i + 1)) ;;
      -*) ;;
      *) [[ ${#selector[@]} -eq 0 ]] && selector=("$arg") ;;
    esac
  done

  if ((disable && !auto)); then
    exec gh "$@"
  fi
  if ! pr="$(gh pr view "${selector[@]}" "${repo[@]}" --json url,author,isDraft,headRefOid,baseRefName \
    --jq '[.url, .author.login, (.isDraft|tostring), .headRefOid, .baseRefName] | @tsv')"; then
    exit 1
  fi
  IFS=$'\t' read -r url author draft head base <<<"$pr"
  if [[ "$author" != "app/coldlogic-ai" ]]; then
    echo "gh-app: $url was opened by $author, not the App; only its own PRs merge from a session" >&2
    exit 1
  fi
  if [[ "$draft" == true ]]; then
    echo "gh-app: $url is a draft" >&2
    exit 1
  fi
  slug="${url#https://github.com/}"
  slug="${slug%/pull/*}"
  if ((auto)); then
    # GitHub holds an auto-merge until the ruleset's approval is in, so the
    # ruleset must ask for one. Fails closed.
    if ! required="$(gh api "repos/$slug/rules/branches/$base" --jq '[.[] | select(.type == "pull_request") | .parameters | select(.required_approving_review_count >= 1 and .dismiss_stale_reviews_on_push)] | length')"; then
      exit 1
    fi
    if [[ ! "$required" =~ ^[1-9][0-9]*$ ]]; then
      echo "gh-app: $slug's $base rules don't require an approval that a push dismisses; turn on auto-merge by hand" >&2
      exit 1
    fi
  else
    # The approver's last review that decides anything, on the head commit.
    api="repos/$slug/pulls/${url##*/pull/}/reviews"
    if ! last="$(gh api --paginate "$api" --jq ".[] | select((.user.login // \"\") == \"$approver\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")) | [.state, (.commit_id // \"\")] | @tsv" | tail -n 1)"; then
      exit 1
    fi
    if [[ "$last" != "APPROVED"$'\t'"$head" ]]; then
      echo "gh-app: $approver hasn't approved $url at its head commit ${head:0:7}" >&2
      exit 1
    fi
  fi
  # Merges only the commit checked, should the branch move meanwhile.
  if [[ -z "$match" ]]; then
    exec gh "$@" --match-head-commit "$head"
  elif [[ "$match" != "$head" ]]; then
    echo "gh-app: --match-head-commit $match isn't $url's head ${head:0:7}" >&2
    exit 1
  fi
fi

exec gh "$@"
