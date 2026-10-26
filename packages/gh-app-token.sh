# Mints a GitHub App installation access token for the coldlogic-ai App and
# prints it on stdout.
#
# Used so Claude Code sessions act on GitHub (gh api / PR / issue / review
# calls) as the coldlogic-ai App, not the owner's personal account. git push
# is untouched — that still uses the owner's SSH key.
#
# Flow:
#   1. Build an RS256 JWT (iss=<App ID>, iat=now-60, exp=now+540) signed with
#      the App's private key, using openssl.
#   2. GET /app/installations with the JWT to find the installation id for
#      org coldlogicsolutions. Cached in
#      ${XDG_CACHE_HOME:-$HOME/.cache}/coldlogic-ai/installation so we don't
#      re-list installations on every call.
#   3. POST /app/installations/{id}/access_tokens to mint a ~1h token.
#
# Env:
#   GH_APP_KEY   path to the App's PEM private key
#                (default: $HOME/.config/github/coldlogic-ai.pem —
#                this directory is provisioned from 1Password by nix and is
#                read-only by design; never write cache files there)
#   GH_APP_ID    the App's numeric ID (default: 4680184)
#
# Exit behavior: if the key file is missing, this prints nothing on stdout
# and exits non-zero with a message on stderr. Callers that treat a missing
# key as "not configured, no-op" (e.g. the devenv shell hook) should check
# for the key themselves before invoking this script, so they can stay
# silent; this script itself always reports an error to stderr when asked to
# mint a token it cannot mint.
set -euo pipefail

GH_APP_KEY="${GH_APP_KEY:-$HOME/.config/github/coldlogic-ai.pem}"
GH_APP_ID="${GH_APP_ID:-4680184}"
ORG="coldlogicsolutions"

CONFIG_DIR="${GH_APP_CONFIG_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/coldlogic-ai}"
INSTALLATION_CACHE="$CONFIG_DIR/installation"

if [[ ! -f "$GH_APP_KEY" ]]; then
  echo "gh-app-token: private key not found at $GH_APP_KEY (set GH_APP_KEY)" >&2
  exit 1
fi

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GH_APP_ID" | b64url)
signing_input="${header}.${payload}"
signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$GH_APP_KEY" | b64url)
jwt="${signing_input}.${signature}"

api() {
  curl -sS \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

installation_id=""
if [[ -f "$INSTALLATION_CACHE" && ! -L "$INSTALLATION_CACHE" ]]; then
  installation_id=$(cat "$INSTALLATION_CACHE")
  # It goes into an authenticated URL, so anything but a number is ignored
  # and looked up again.
  [[ "$installation_id" =~ ^[0-9]+$ ]] || installation_id=""
fi

if [[ -z "$installation_id" ]]; then
  installations=$(api "https://api.github.com/app/installations")
  installation_id=$(printf '%s' "$installations" | jq -r --arg org "$ORG" \
    '.[] | select(.account.login == $org) | .id' | head -n1)

  if [[ -z "$installation_id" || "$installation_id" == "null" ]]; then
    echo "gh-app-token: no installation of this App found for org $ORG" >&2
    echo "gh-app-token: response was: $installations" >&2
    exit 1
  fi

  # Caching the installation id is a pure optimization: if we can't write
  # it (e.g. permissions), don't let that fail the whole mint — we still
  # have the id in hand for this run.
  if { mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR" &&
    printf '%s' "$installation_id" > "$INSTALLATION_CACHE"; } 2>/dev/null; then
    chmod 600 "$INSTALLATION_CACHE" 2>/dev/null || true
  else
    echo "gh-app-token: warning: could not cache installation id at $INSTALLATION_CACHE (continuing without cache)" >&2
  fi
fi

token_response=$(api -X POST "https://api.github.com/app/installations/${installation_id}/access_tokens")
token=$(printf '%s' "$token_response" | jq -r '.token // empty')

if [[ -z "$token" ]]; then
  echo "gh-app-token: failed to mint installation token" >&2
  echo "gh-app-token: response was: $token_response" >&2
  exit 1
fi

printf '%s\n' "$token"
