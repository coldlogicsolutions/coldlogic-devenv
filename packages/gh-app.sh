# Runs a GitHub CLI command as the coldlogic-ai App instead of the owner's
# personal account. Use for App-identity actions like opening issues or
# posting comments; commits and PRs are authored by the owner (derekjw).
#
# Example:
#   gh-app issue create --title "foo"
#   gh-app pr comment 123 --body "approved"
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
exec gh "$@"
