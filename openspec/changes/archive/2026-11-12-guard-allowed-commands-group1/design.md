# Design

## Context

See proposal.md for the motivation. What follows is what was checked against the code on this branch (`3666ba8`) and what is assumed.

**Checked** by calling `decide()` with the allow list from `devenv.nix` (lines 285-313), each command bare and behind `devenv shell --quiet --`:

- Already allowed: `git log` in every form #42 names (bare, with arguments, `| head`, `-p`, `-C .`, `-C <the checkout the session is in>`), `git status`, `git diff`; `gh-app issue view|list|create|comment|edit` and `pr list|create` with a single-quoted multi-line `--body`, a plain double-quoted one, `--body-file "$TMPDIR/x"`, `--body-file <absolute scratch path>` and `--body-file - <<'EOF'` whose body quotes `gh pr merge` and `git push --force` (#43, #61); `gh-app pr merge N [-R o/r] --auto --squash` (#62); `gh-app issue comment 49 -R coldlogicsolutions/coldlogic-devenv --body-file <scratch>` (#86's "done when" form).
- `gh() { ...; }` followed by `gh pr merge ...` asks (the "Shell function definitions ask" requirement), as #61 wanted.
- `devenv --version` and `devenv -V` ask: `devenv_command()` raises `Unparsable("devenv option --version")`. `devenv version` returns no decision.
- Two more places stand between a version query and an allow. The strict reader refuses any command whose program is in `WRAPPERS`, which holds `devenv` (`plain_commands()`, `end()`). And `approved()` wants an allow rule or `read_only()`, which looks only at `READ_ONLY` program names.
- `read_only()` is called from `approved()` only. `READ_ONLY`, the set, is also matched by program name alone in `stage_kind()` and `data_consumer()`.
- devenv 2.4.0 lists `-V, --version` and a `version` subcommand ("Print the version of devenv"); `devenv version` printed `devenv 2.4.0 (aarch64-darwin)` and nothing else.
- A scratch copy of the guard with the decision-1 edits applied passes all 1282 existing cases and the 171 new ones, built from the block in tasks.md as written. Against the unmodified guard the new cases fail only on version-query rows.

**Assumed, not checked:**

- Why auto mode's classifier denied the #62 and #86 commands. See "Follow-ups" below.

Constraints: other sessions are editing `claude-guard.py`, its tests and `devenv.nix` at the same time, so edits stay small and local, with no refactor and no reformatting, and `devenv.nix` is not touched. The guard is a backstop for mistakes, not a boundary against an attacker.

## Goals / Non-Goals

**Goals:**

- Exactly the three version queries are allowed, with no rule, bare and wrapped.
- Every other devenv option the guard doesn't know still asks.
- Every command from the six issues has a test, bare and wrapped, against the module's real allow list, with the forms that must stay without an allow.

**Non-Goals:**

- New allow rules. `git show`, `git blame` and `git rev-parse` (#42 says "consider") stay with Claude Code's own decision; the table pins that as no decision from the guard.
- `git -C <another of the project's worktrees>`. The spec has it as no allow; #65 covers it.
- A `--body "$(cat <<'EOF' ... EOF)"` form for issue and PR bodies. The supported forms are `--body-file` and a single-quoted `--body`; both work. The table pins the substitution form, and a double-quoted body with backticks or `$`, as no allow (#43's original command).
- Allowing `cd <dir> && ...` (#86's original form). A `cd` changes what every later rule and path means.
- Narrowing `gh-app issue comment *` to `-R coldlogicsolutions/*` (#86 suggested it). Narrowing can only add prompts.
- Following shell functions (#61's first case). Asking is the fix, and it is in.
- Fixing #62 and #86. See "Follow-ups".

## Decisions

### 1. The version query is read-only in the guard, by three small edits

A helper, `version_query(words)`, is true for exactly the word lists `devenv --version`, `devenv -V` and `devenv version`. It is used in three places:

- `devenv_command()` returns `None` ("another devenv subcommand") for it, so `unwrap()` keeps it as the command instead of raising `Unparsable`.
- The strict reader's wrapper check in `plain_commands()` lets it through.
- `read_only()` returns true for it, so `approved()` needs no rule.

The brief asked for a change in `devenv_command()` or its caller only. That is not enough (checked): with that edit alone the guard stops asking but gives no decision, bare or wrapped, because of the other two places. Each of the three edits is one or two lines.

The match is on the whole word list with `words[0] == "devenv"`: not a basename (so `/nix/store/x/bin/devenv --version` still asks), not a prefix (`--versio`), and nothing may come before or after the option. `devenv --version shell -- rm -rf x` keeps raising `Unparsable`, so it asks, and `rough_deny()` still denies `devenv -V shell -- git push --force`. Whether clap would stop at `--version` there is not something the guard needs to know.

Everything after approval is unchanged: ask and deny rules are matched before any allow (checked: `devenv *` as an ask or deny rule wins), every other command of a chain or pipeline must be approved on its own, and a redirect into the project is still denied.

Alternatives rejected:

- **Exact allow rules in `devenv.nix`** (`devenv --version` and the others, as #85 proposed) with the parse fix. It works and makes the allow visible in the generated settings, but it edits `devenv.nix`, which this change leaves alone, and adds three rules for something that can't do anything. The team lead settled this.
- **The rule alone.** Checked: the guard asks before any rule is consulted, so the prompt would stay.
- **Add `devenv` to `READ_ONLY`.** That set is matched by program name alone in `stage_kind()` and `data_consumer()`, so every `devenv` command would count as a read-only pipeline stage and a data consumer for heredoc bodies.
- **Remove `devenv` from `WRAPPERS`.** `unwrap()` and the body-reader checks rely on it.
- **Reading devenv's full option grammar** so `devenv --quiet --version` works too. More surface for no reported need.

### 2. One appended test block with its own copy of the allow list

`claude-guard-test.py` gains one block at the end of the file, above `total = checks`: `MODULE_ALLOW`, a copy of `rules.Bash.allow` from `devenv.nix`; one table of `(command, expected)` rows, each run bare and wrapped with `{"allow": MODULE_ALLOW}`; a few cases in a temporary directory, where `-C <checkout>` can be judged; and a short list for the version query under other policies. The shared `POLICY` at the top of the file is a different list on purpose (it holds `devenv shell *`, `cargo test *` and `wc *`, and lacks `gh-app pr merge` and `gh-app issue comment`) and is not changed.

One row can't be the same both ways: the function case. Behind the wrapper only the definition's first line is wrapped; the guard can't parse that and its rough reading denies the `gh pr merge` it sees. That is the fail-closed side, and the table states both values.

Alternatives rejected:

- **Generate the list from `devenv.nix`** (move it to a nix file both import, have `claude-guard.nix` write it out for the test). Drift-proof, but it restructures `devenv.nix`, and `scripts/check.sh` also runs the test file directly, with no build to hand it the file.
- **Add the commands to the existing `BASH` table.** Its policy isn't the module's, so it can't show what a session in a real project gets.
- **Parse `devenv.nix` from the test.** The build copies only the two Python files into its sandbox.
- **A cross-reference comment in `devenv.nix`.** It would help against drift, but this change doesn't touch that file. The comment sits in the test file only.

## Risks / Trade-offs

- [The copied allow list drifts from `devenv.nix`] → The comment above `MODULE_ALLOW` names the source. A missed update makes the table test a stale list; it can't make the guard allow more. Whoever next changes the list in `devenv.nix` should add the pointer there.
- [The version query is allowed with no rule, so nothing in the generated settings shows it] → The README row and the spec say it. Where the guard gives no decision (plan mode, a directory outside every checkout) Claude Code decides, as it does today.
- [`devenv version` could grow side effects in a later devenv] → It is documented as printing the version. The match is exact, so no argument can change what it does.
- [A project with a broad rule such as `devenv *` now gets an allow for the version query where the guard asked before] → That is what such a rule says, and the query needs no rule anyway. The guard still asks for anything run through `devenv shell` that no rule names (checked).
- [Several sessions editing `claude-guard.py` and its tests] → Each guard edit is one or two lines at a named anchor, and the tests are one whole block. Other sessions also append near the end of the test file, so expect a textual conflict there on rebase: keep both blocks.

## Migration Plan

None. Projects get the guard on their next `devenv update`. Rolling back is reverting the commit.

## Follow-ups

#62 and #86 stay open. Both are denials by auto mode's classifier of commands the guard allows today, bare and wrapped; the table now pins that. Two likely causes, neither checked here:

- The call carried a per-command `allowed_domains`. Per the Claude Code sandbox documentation, such a call is reviewed by the classifier whatever a hook decides. If so, the fix is for sessions not to pass it on `gh-app` calls (the sandbox's network allow list already covers GitHub), which is a conventions matter.
- The session ran an older guard: a stale lock or stale generated settings. #62's repository pins its own module version, so its lock is the first place to look.

After this change merges, comment on both issues with those two points.

## Open Questions

None that change this plan.

## Changes after archiving (review and user feedback)

What shipped differs from the plan above in these ways. The main spec (`openspec/specs/claude-guard/spec.md`) and the code are authoritative.

- **Help queries only read too.** Derek asked that `devenv --help` not need approval. The helper is now `devenv_query(words)`, with `DEVENV_QUERY` and `DEVENV_SUBCOMMANDS` in place of `version_query` and `DEVENV_VERSION`. Besides the three version queries, it takes exactly `devenv --help`, `-h` and `help`, `devenv <subcommand> --help` or `-h`, and `devenv help <subcommand>`, for the subcommands devenv 2.4.0's `devenv --help` lists. devenv's argument parser prints help and exits before anything runs. A subcommand missing from the list only prompts, as before. The strict reader's `devenv shell` prefix check also skips a query, so `devenv shell --help` isn't read as the wrapper. `devenv --help` and `devenv version --help` are now allowed, where the delta spec below says they ask or get no allow.
- **The copied allow list is checked against `devenv.nix` where it can be.** When `devenv.nix` is beside the test file's directory, which is the case in the gate's run from the checkout, the tests fail if `MODULE_ALLOW` differs from `rules.Bash.allow`. The package build copies only the two `.py` files, so the check is skipped there, and the gate is what catches drift.
- **The wrapped gh function is denied on purpose.** Behind `devenv shell --quiet --`, only the function definition's first line is wrapped. The guard can't read the call, and its rough reading denies it for `gh pr merge`. The main spec now says this.
