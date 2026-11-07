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

# Succeeds for a name safe as one path component: no "/", "." or "..".
safe_component() {
  case $1 in "" | . | .. | -*) return 1 ;; esac
  [ -z "${1//[A-Za-z0-9._@+-]/}" ]
}

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

# Succeeds when a user-scope record, or a project-scope one for this root,
# covers the plugin and its files are still in the cache.
covered() {
  local path
  while IFS= read -r path; do
    [ -d "$path" ] && return 0
  done < <(read_records | jq -r --arg p "$1" --arg root "$root" \
    '.plugins[$p][]? | select(.scope == "user" or (.scope == "project" and .projectPath == $root)) | .installPath // empty' 2>/dev/null)
  return 1
}

# Taken before the first write, so a shell with nothing to install never
# touches ~/.claude. Two shells (say, two worktrees under direnv) would
# otherwise lose each other's records. Claude Code doesn't take this lock, so
# a session writing the records at the same moment can still lose one; the
# next shell redoes it.
lock="$records.devenv-lock"
locked=""
tmp_copy=""
writable_hint="if this shell runs inside a sandboxed Claude Code session, enter it from a terminal"
take_lock() {
  [ -z "$locked" ] || return 0
  if [ ! -w "$plugins" ]; then
    echo "Can't write $plugins, so no Claude Code plugins were installed ($writable_hint)" >&2
    exit 0
  fi
  # A lock older than ten minutes is left by a shell that was killed.
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$lock" 2>/dev/null; then
      locked=1
      trap 'rm -rf "$tmp_copy"; rmdir "$lock" 2>/dev/null' EXIT
      return 0
    fi
    if [ ! -d "$lock" ]; then
      # Not another shell: the write itself was refused.
      echo "Can't write $plugins, so no Claude Code plugins were installed ($writable_hint)" >&2
      exit 0
    fi
    sleep 1
  done
  echo "Couldn't take $lock, so no Claude Code plugins were installed. Remove it if no other shell is starting" >&2
  exit 0
}

now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
done_list=""
# Installs one plugin, then the dependencies its plugin.json declares.
install_plugin() {
  local plugin=$1 name market clone clone_real catalog entry source base src sha version cache tmp record dep
  case " $done_list " in *" $plugin "*) return ;; esac
  done_list="$done_list $plugin"
  name=${plugin%@*}
  market=${plugin##*@}
  if ! safe_component "$name" || ! safe_component "$market"; then
    warn "$plugin" "its name isn't one this can use as a folder name"
    return
  fi
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
  source=$(jq -r '.source | strings' <<<"$entry" 2>/dev/null) || source=""
  # A relative path, "./" or "." for the marketplace's root; anything else
  # (an object naming a repo or URL, or no source) this can't install.
  base=$(jq -r '.metadata.pluginRoot? // "." | strings' "$catalog" 2>/dev/null) || base=.
  [ -n "$base" ] || base=.
  case "$source" in
    ./* | .) src=$(cd "$clone/$base/$source" 2>/dev/null && pwd -P) || src="" ;;
    *) src="" ;;
  esac
  # The source must stay inside the marketplace.
  clone_real=$(cd "$clone" && pwd -P) || clone_real=""
  case "$src/" in "$clone_real"/*) ;; *) src="" ;; esac
  if [ -z "$src" ]; then
    covered "$plugin" || warn "$plugin" "its source isn't a folder in the marketplace, which this can't install. Install it with Claude Code"
    return
  fi

  if ! covered "$plugin"; then
    # A git clone, or an archive download that records its commit in .gcs-sha.
    # Only the clone's own repository: git would otherwise find a parent's,
    # say a dotfiles repo holding ~/.claude.
    sha=""
    if [ -e "$clone/.git" ]; then
      sha=$(git -C "$clone" rev-parse HEAD 2>/dev/null) || sha=""
    elif [ -f "$clone/.gcs-sha" ]; then
      sha=$(tr -d '[:space:]' <"$clone/.gcs-sha" 2>/dev/null) || sha=""
    fi
    version=$(jq -r '.version // empty | strings' "$src/.claude-plugin/plugin.json" 2>/dev/null) || version=""
    [ -n "$version" ] || version=$(jq -r '.version // empty | strings' <<<"$entry" 2>/dev/null) || version=""
    [ -n "$version" ] || version=${sha:0:12}
    if ! safe_component "$version"; then
      warn "$plugin" "couldn't work out a usable version (got '$version')"
      return
    fi

    take_lock
    cache="$plugins/cache/$market/$name/$version"
    if [ ! -d "$cache" ]; then
      # Built beside the cache, not among the version directories, where
      # Claude Code could take a leftover for a version.
      tmp="$plugins/cache/.devenv-tmp.$$"
      tmp_copy=$tmp
      # The source can be the marketplace's root, so leave its .git behind.
      if ! err=$({ mkdir -p "$tmp" "$(dirname "$cache")" && tar -C "$src" --exclude=.git -cf - . | tar -C "$tmp" -xf - &&
        chmod -R u+w "$tmp" && mv "$tmp" "$cache"; } 2>&1); then
        rm -rf "$tmp"
        warn "$plugin" "couldn't copy it to $cache: ${err:-unknown error}"
        return
      fi
    fi

    record=$(jq -n --arg root "$root" --arg path "$cache" --arg v "$version" --arg sha "$sha" --arg now "$now" '
      {scope: "project", projectPath: $root, installPath: $path, version: $v,
       installedAt: $now, lastUpdated: $now}
      + (if $sha == "" then {} else {gitCommitSha: $sha} end)')
    tmp="$records.tmp.$$"
    # Re-reads the records just before writing, and drops the stale
    # project-scope record for this root (its files gone) this one replaces.
    if err=$({ read_records | jq -e --arg p "$plugin" --arg root "$root" --argjson r "$record" '
      if .version != 2 then error("installed_plugins.json changed to a format this does not know")
      else .plugins[$p] = ([(.plugins[$p] // [])[] | select(.scope != "project" or .projectPath != $root)] + [$r]) end
    ' >"$tmp" && mv "$tmp" "$records"; } 2>&1); then
      echo "Installed Claude Code plugin $plugin $version for this checkout" >&2
    else
      rm -f "$tmp"
      warn "$plugin" "couldn't write $records: ${err:-unknown error} ($writable_hint)"
      return
    fi
  fi

  # "name@marketplace", or a bare name in the same marketplace.
  while IFS= read -r dep; do
    case "$dep" in
      "") ;;
      "?"*) echo "Claude Code plugin $plugin declares a dependency this can't read (${dep#?}); install it with Claude Code" >&2 ;;
      *@*) install_plugin "$dep" ;;
      *) install_plugin "$dep@$market" ;;
    esac
  done < <(jq -r '.dependencies[]? | if type == "string" then . else "?" + tojson end' "$src/.claude-plugin/plugin.json" 2>/dev/null)
}

while IFS= read -r plugin; do
  install_plugin "$plugin"
done <<<"$enabled"
exit 0
