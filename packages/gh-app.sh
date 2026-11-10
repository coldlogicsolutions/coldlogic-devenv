# Runs a GitHub CLI command as the coldlogic-ai App instead of the owner's
# personal account: sessions open PRs and issues, and comment, as the App.
#
# Example:
#   gh-app issue create --title "foo"
#   gh-app pr comment 123 --body "approved"
#   gh-app pr merge 123 --squash
#   gh-app pr merge 123 --auto --squash
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
# If the App's private key is not present, this exits with a clear error
# message on stderr.

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
    if ! last="$(gh api --paginate "$api" --jq ".[] | select(.user.login == \"$approver\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")) | [.state, .commit_id] | @tsv" | tail -n 1)"; then
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
