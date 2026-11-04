# Runs a GitHub CLI command as the coldlogic-ai App instead of the owner's
# personal account: sessions open PRs and issues, and comment, as the App.
#
# Example:
#   gh-app issue create --title "foo"
#   gh-app pr comment 123 --body "approved"
#   gh-app pr merge 123 --squash
#
# `gh-app pr merge` merges only a PR the App opened, that isn't a draft, and
# whose head commit the approver (GH_APP_APPROVER, default derekjw) approved
# last. GitHub's ruleset requires the approval too; this adds the author, so
# a session can't merge someone else's approved PR. `--admin` is refused.
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

  if ! pr="$(gh pr view "${selector[@]}" "${repo[@]}" --json url,author,isDraft,headRefOid \
    --jq '[.url, .author.login, (.isDraft|tostring), .headRefOid] | @tsv')"; then
    exit 1
  fi
  IFS=$'\t' read -r url author draft head <<<"$pr"
  if [[ "$author" != "app/coldlogic-ai" ]]; then
    echo "gh-app: $url was opened by $author, not the App; only its own PRs merge from a session" >&2
    exit 1
  fi
  if [[ "$draft" == true ]]; then
    echo "gh-app: $url is a draft" >&2
    exit 1
  fi
  # The approver's last review that decides anything, on the head commit.
  api="${url#https://github.com/}"
  api="repos/${api%/pull/*}/pulls/${api##*/pull/}/reviews"
  if ! last="$(gh api --paginate "$api" --jq ".[] | select(.user.login == \"$approver\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")) | [.state, .commit_id] | @tsv" | tail -n 1)"; then
    exit 1
  fi
  if [[ "$last" != "APPROVED"$'\t'"$head" ]]; then
    echo "gh-app: $approver hasn't approved $url at its head commit ${head:0:7}" >&2
    exit 1
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
