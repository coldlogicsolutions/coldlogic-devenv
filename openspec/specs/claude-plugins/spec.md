# claude-plugins Specification

## Purpose
The Claude Code plugins every project's sessions load: the marketplaces and plugins the generated settings enable, and the shell task that installs them for the checkout, since Claude Code can't install them through the store link.

## Requirements

### Requirement: The coldlogic plugin and its dependencies are enabled
The generated settings SHALL add the `coldlogic-plugins` marketplace (`coldlogicsolutions/claude-plugins-coldlogic`, auto-updating) and the `openai-codex` marketplace. They SHALL enable `coldlogic@coldlogic-plugins` and its dependencies, and enable the `mcp.devenv.sh` MCP server. A profile or project SHALL be able to add plugins through the same settings key.

Tested by: none.

#### Scenario: A project adds a plugin
- **WHEN** a project sets `files."${config.claude.code.settingsPath}".json.enabledPlugins."playwright@claude-plugins-official" = true`
- **THEN** the generated settings enable both the module's plugins and `playwright`

### Requirement: The shell installs enabled plugins for the checkout
On each `developer` shell, a task SHALL install every enabled plugin, and every dependency its `plugin.json` declares, that no user-scope or this-checkout project-scope install covers. It SHALL copy the plugin from Claude Code's fetched marketplace into the plugin cache and record a project-scope install, without writing user settings or `settings.local.json`.

Tested by: none.

#### Scenario: First shell in a new checkout
- **WHEN** Claude Code has fetched the `coldlogic-plugins` marketplace and a developer enters the shell in a checkout with no install
- **THEN** stderr shows `Installed Claude Code plugin coldlogic@coldlogic-plugins <version> for this checkout`

#### Scenario: Already installed
- **WHEN** an install already covers the plugin and its files are in the cache
- **THEN** the task changes nothing

### Requirement: Plugin installation never fails the shell
The install task SHALL report each problem as a warning on stderr and never fail the shell. Problems include: a marketplace Claude Code hasn't fetched yet, a plugin directory it can't write (as in a sandboxed session), a records format it doesn't know, and a dependency that isn't enabled in the settings.

Tested by: none.

#### Scenario: Inside a sandboxed session
- **WHEN** the shell runs inside a Claude Code session that can't write `~/.claude/plugins`
- **THEN** it warns that no plugins were installed, and the shell still starts

#### Scenario: Dependency not enabled
- **WHEN** an enabled plugin declares a dependency the settings don't enable
- **THEN** it warns to add the dependency to `enabledPlugins`
