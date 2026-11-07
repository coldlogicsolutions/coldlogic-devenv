# Installs, for one checkout, each Claude Code plugin its settings enable that
# no install covers yet, and the dependencies those plugins declare.
# Usage: claude-plugins-install <settings.json> <root>
#
# `claude plugin install --scope project` can't do it: it also writes
# enabledPlugins into the project's settings.json, refuses to write through
# devenv's symlink into the store, and so records nothing. This does the rest
# of what it does, without the settings write: copies the plugin from the
# marketplace copy Claude Code keeps into its plugin cache, and adds a
# project-scope record to installed_plugins.json. Nothing goes in user
# settings or settings.local.json.
#
# Mirrors Claude Code's formats (installed_plugins.json version 2; a cache
# directory per version, named for the plugin's version or else the first 12
# characters of the marketplace commit). If those change, it warns and
# installs nothing. It never fails: every problem is a warning on stderr.

settings=$1
# Claude Code records the resolved path, so /tmp and /private/tmp match.
root=$(cd "$2" 2>/dev/null && pwd -P) || root=$2
plugins="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
records="$plugins/installed_plugins.json"
empty='{"version":2,"plugins":{}}'

warn() {
  echo "Claude Code plugin $1 is enabled but not installed for this checkout, so sessions run without it: $2" >&2
}

[ -f "$settings" ] || exit 0
if ! enabled=$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$settings" 2>/dev/null); then
  echo "Couldn't read enabledPlugins from $settings, so no Claude Code plugins were checked" >&2
  exit 0
fi
[ -n "$enabled" ] || exit 0

# Prints the records' JSON, or the empty records when there is no file yet.
read_records() {
  if [ -f "$records" ]; then cat "$records"; else echo "$empty"; fi
}
if ! jq -e '.version == 2' >/dev/null 2>&1 <<<"$(read_records)"; then
  echo "$records isn't valid JSON, or has a format this doesn't know, so no Claude Code plugins were installed" >&2
  exit 0
fi

# Succeeds when a record covers this checkout (user scope, or this root) and
# its files are still in the cache.
covered() {
  local path
  while IFS= read -r path; do
    [ -d "$path" ] && return 0
  done < <(read_records | jq -r --arg p "$1" --arg root "$root" \
    '.plugins[$p][]? | select(.scope == "user" or .projectPath == $root) | .installPath // empty' 2>/dev/null)
  return 1
}

# Two shells (say, two worktrees under direnv) would otherwise lose each
# other's records. Claude Code doesn't take this lock, so a session writing
# the records at the same moment can still lose one; the next shell redoes it.
lock="$records.devenv-lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  mkdir "$lock" 2>/dev/null && break
  sleep 1
done
if [ ! -d "$lock" ]; then
  echo "Couldn't take $lock, so no Claude Code plugins were installed. Remove it if no other shell is starting" >&2
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT

now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
done_list=""
# Installs one plugin, then the dependencies its plugin.json declares.
install() {
  local plugin=$1 name market clone catalog entry source base src sha version cache tmp record dep
  case " $done_list " in *" $plugin "*) return ;; esac
  done_list="$done_list $plugin"
  name=${plugin%@*}
  market=${plugin##*@}
  if ! grep -qxF "$plugin" <<<"$enabled"; then
    echo "Claude Code plugin $plugin is a dependency of an enabled plugin but isn't enabled in $settings; add it to enabledPlugins" >&2
  fi

  clone=$(jq -r --arg m "$market" '.[$m].installLocation // empty' "$plugins/known_marketplaces.json" 2>/dev/null) || clone=""
  catalog="$clone/.claude-plugin/marketplace.json"
  if [ -z "$clone" ] || [ ! -f "$catalog" ]; then
    covered "$plugin" || warn "$plugin" "Claude Code hasn't fetched the $market marketplace yet. Start Claude Code here once, then re-enter the shell"
    return
  fi
  entry=$(jq -c --arg n "$name" '.plugins[]? | select(.name == $n)' "$catalog" 2>/dev/null) || entry=""
  if [ -z "$entry" ]; then
    covered "$plugin" || warn "$plugin" "the $market marketplace has no plugin named $name"
    return
  fi
  source=$(jq -r '.source | strings' <<<"$entry")
  base=$(jq -r '.metadata.pluginRoot // "."' "$catalog")
  case "$source" in
    ./* | "") src=$(cd "$clone/$base/${source:-.}" 2>/dev/null && pwd -P) || src="" ;;
    *) src="" ;;
  esac
  if [ -z "$src" ]; then
    covered "$plugin" || warn "$plugin" "its source isn't a folder in the marketplace, which this can't install. Install it with Claude Code"
    return
  fi

  if ! covered "$plugin"; then
    # A git clone, or an archive download that records its commit in .gcs-sha.
    sha=$(git -C "$clone" rev-parse HEAD 2>/dev/null) || sha=""
    [ -n "$sha" ] || [ ! -f "$clone/.gcs-sha" ] || sha=$(tr -d '[:space:]' <"$clone/.gcs-sha")
    version=$(jq -r '.version // empty' "$src/.claude-plugin/plugin.json" 2>/dev/null) || version=""
    [ -n "$version" ] || version=$(jq -r '.version // empty' <<<"$entry")
    [ -n "$version" ] || version=${sha:0:12}
    if [ -z "$version" ]; then
      warn "$plugin" "couldn't work out its version"
      return
    fi

    cache="$plugins/cache/$market/$name/$version"
    if [ ! -d "$cache" ]; then
      tmp="$cache.tmp.$$"
      # The source can be the marketplace's root, so leave its .git behind.
      if ! { mkdir -p "$tmp" && tar -C "$src" --exclude=.git -cf - . | tar -C "$tmp" -xf - &&
        chmod -R u+w "$tmp" && mv "$tmp" "$cache"; } 2>/dev/null; then
        rm -rf "$tmp"
        warn "$plugin" "couldn't write $cache (a shell inside a sandboxed Claude Code session can't; enter it from a terminal)"
        return
      fi
    fi

    record=$(jq -n --arg root "$root" --arg path "$cache" --arg v "$version" --arg sha "$sha" --arg now "$now" '
      {scope: "project", projectPath: $root, installPath: $path, version: $v,
       installedAt: $now, lastUpdated: $now}
      + (if $sha == "" then {} else {gitCommitSha: $sha} end)')
    tmp="$records.tmp.$$"
    # Re-reads the records just before writing, and drops any stale record for
    # this root (its files gone from the cache) that this one replaces.
    if { read_records | jq --arg p "$plugin" --arg root "$root" --argjson r "$record" \
      '.plugins[$p] = ([(.plugins[$p] // [])[] | select(.projectPath != $root)] + [$r])' >"$tmp" &&
      mv "$tmp" "$records"; } 2>/dev/null; then
      echo "Installed Claude Code plugin $plugin $version for this checkout" >&2
    else
      rm -f "$tmp"
      warn "$plugin" "couldn't write $records (a shell inside a sandboxed Claude Code session can't; enter it from a terminal)"
      return
    fi
  fi

  while IFS= read -r dep; do
    [ -n "$dep" ] && install "$dep"
  done < <(jq -r '.dependencies[]? | strings' "$src/.claude-plugin/plugin.json" 2>/dev/null)
}

while IFS= read -r plugin; do
  install "$plugin"
done <<<"$enabled"
exit 0
