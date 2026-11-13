# Design

## Context

See proposal.md for the motivation. What shapes the approach:

Checked in the code:

- `decide()` (packages/claude-guard.py:2795) asks for a file-tool write when `claude_config(path)` is true. Read never reaches that test. `claude_config()` (2313-2329) has no other caller.
- `claude_config()` calls `resolve(path)` (1500-1519), which runs `os.path.realpath` on the whole path. For a symlink that leads out of the project, `resolve()` returns `(target, None)`, and `claude_config()` returns False on the `None`.
- `resolve()` already tells the project's own worktrees from other repositories' through `checkout_of()` (1571-1583), whose answers are remembered per guard call. `resolve()` has many other callers (`secret_path`, `project_file`, the Bash branch).
- `devenv.nix:157-179`: the `secrets` list. `.env` has `denyWrite = true`; `secrets/**` doesn't. The sandbox's `denyWrite` (476-479) is built from the entries with that flag, through `inCheckout` (181-184) and `inSiblingWorktrees` (229-232), so a flagged entry yields four paths. `denyRead` is built from every entry.
- This repository and its fixtures track no file under a `secrets` directory (`git ls-files '*secrets*'` is empty).
- `devenv shell --quiet -- python3 -I packages/claude-guard-test.py` runs the cases outside the Nix build: 1282 pass before this change.
- README has "Working on the module" (line 114) with the gate. The guard's row in the table (line 97) is one very long cell.

Assumed, not checked:

- Claude Code turns a `denyWrite` glob ending in `/**` into a deny on the directory and everything below it. Seen for reads: this session's sandbox lists the `secrets/**` read denies as `<root>/secrets` and `<root>/**/secrets`. Not seen for writes. The coder checks the generated file (task 3.3). A live write can't be tried from a session, since the guard denies a command that writes under `secrets/` before the sandbox sees it.
- devenv links generated files one by one and doesn't link whole directories inside `.claude`. This repository's `.claude/skills` and `.claude/commands` are real directories that `openspec` writes.

Constraints:

- Guardrails policy: the guard and the sandbox stop easy mistakes, not attackers. No hardening against exotic bypasses.
- Other sessions are editing `claude-guard.py` at 253-625, 1046-1240, 1571-1680 and from 2810 on. This change must touch only `claude_config()` there.

## Goals / Non-Goals

**Goals:**

- A file-tool write to a link in `.claude` asks, in the root and in the project's own worktrees.
- No path that isn't a link at its last component gets a different decision.
- A sandboxed command can't write under `secrets/` where it already can't read.
- The README says how to probe the guard without running anything.

**Non-Goals:**

- A link above the last component (a linked directory in `.claude`).
- Protecting the link from Bash. The sandbox's own write protection of `.claude/settings.json` and the sibling worktrees' `denyWrite` entries already do that.
- An automated test for generated sandbox settings.
- Changing what `resolve()` returns.

## Decisions

### 1. Judge a path twice inside `claude_config()`: where it leads and where it sits

`claude_config()` builds up to two project-relative views of the path and returns True when either has a `.claude` component under the existing worktree exception:

- Where it leads: `resolve(path)[1]`, as now.
- Where it sits: split the path into directory and name, resolve only the directory with `resolve()`, and join the name back. The name is kept as written, so a link in `.claude` is seen in `.claude`.

The second view is skipped when the name is empty, `.` or `..`, since joining those to a resolved directory would not name where the path sits.

For a path whose last component isn't a symlink, `realpath(path)` equals `realpath(directory)/name`, so the two views are the same string and the decision can't change. That is the property that keeps this safe for every existing case.

Amended in review: the second view is only built when the last component is a link (`os.path.islink`, from the cwd), so the common case still resolves once. For a non-link the two views would be equal anyway, so the gate changes no decision; it only skips the extra resolution.

Using `resolve()` for the directory keeps its notion of "inside the project": the root, `.claude/worktrees/<name>` and `<project>.worktrees/<name>` count, another repository's worktree doesn't. So `<other>.worktrees/w/.claude/settings.json` stays with Claude Code's rules.

Alternatives rejected:

- Change `resolve()` to return both views. It has callers across the secrets and project-file checks and the Bash branch, where other sessions are working. The risk of a changed decision somewhere else isn't worth it for one caller.
- Judge the path purely as written (`os.path.normpath`, no link resolution). On macOS a temporary or project path can be spelled through `/var` or `/private/var`, and a project reached through a linked directory would stop matching the root. It would also lose `checkout_of()`'s worktree test, which needs real paths.
- Test `os.path.islink(path)` and special-case links instead of the two views. It needs the same directory resolution to know whether the link is in `.claude`, so it is the chosen approach plus a branch. (Review kept the two views and added the `islink` test only as a fast path; see above.)
- Walk every ancestor and judge each prefix as written. This would cover linked directories too, but adds a loop of `realpath` calls and `..` handling for a layout no project here has. Left out under the guardrails policy; see Open Questions.
- Name the settings file specifically (`.claude/settings.json` only). devenv can link other generated files in `.claude`, and `claude.code.settingsPath` is configurable, so the general rule is simpler and covers more.

### 2. Keep the first view

A link outside `.claude` that leads into it (`alias.json -> .claude/settings.local.json`) asks today through the resolved view. Keeping both views means nothing that asks now stops asking.

### 3. Tests go in a new block, plus rows in the worktrees block

The `.claude` block at claude-guard-test.py:1210-1233 uses a bare temporary directory as the root, with no room for a file outside it. A new block right after it makes `<top>/proj` the root and `<top>/store` the outside, as the block at 1236 does. The existing block isn't edited. The sibling-worktree and other-repository cases go in the file-tool list at 1340-1347, with their links made in that block's setup.

Alternative rejected: restructure the existing block to hold the links. It would rewrite lines another session may touch and gains nothing.

### 4. One flag for the secrets write deny

Add `denyWrite = true` to the `secrets/**` entry. The existing filter then emits the four paths. No new code.

Alternative rejected: make every `secrets` entry write-denied by default and drop the flag. The `.env` entry's `readVariants` are deliberately read-only denies (the comment at devenv.nix:160-167), and the flag is how the list says so. Keeping it explicit keeps that comment true.

### 5. No automated test for the sandbox entry

The requirement stays "Tested by: none", like the rest of session-permissions' sandbox requirements. The generated settings come out of a Nix evaluation of the whole module; an assertion there would restate the line it checks. The coder verifies the generated file by reading it (task 3.3). #59 asks for a test; this is the part of it not done, and the handback says so.

### 6. The README paragraph goes under "Working on the module"

A `### Testing the guard` subsection after the gate paragraph, not in the table row at line 97, which is already too long to scan. It names the two safe ways (add a case to `claude-guard-test.py`; call `decide()` on a string) and says why running the command is not a test: the guard judges a call, it doesn't contain it.

Alternative rejected: enforce it in the guard by denying comment or commit commands from reviewer agent types. The hook input may not carry the agent type, and it would be hardening against a mistake that guidance covers. Out under the guardrails policy.

## Risks / Trade-offs

- [A project tracks files under a directory named `secrets` (encrypted sops files, or a source module such as `src/secrets/mod.rs`). After the update, a sandboxed `git switch`, `stash`, `rebase` or `checkout` that must write those files fails, as tracked `.claude/skills` once did.] → Reads there are already denied, so sessions can't work on such files today, and Edit is denied too. This repository and its fixtures track none. The failure is loud (git reports the path) and the user can run the git command in a terminal. Raised as a question for the user in the handback; the change proceeds on "accept it".
- [The write deny matches any directory named `secrets` at any depth, including in build output or `node_modules`.] → Same reach as the read deny that has been in place since #50, with no reports. Accepted.
- [The generated glob isn't honoured for writes the way it is for reads.] → Task 3.3 checks the generated entries. The guard already denies commands that name a path under `secrets/`, so the sandbox entry is the second layer, for writes the guard can't read (inside a script or a program). If the glob turned out not to work for writes, nothing gets worse than today.
- [More prompts: every file-tool write to a generated link in `.claude` now asks.] → That is the fix. Sessions don't edit generated links in normal work; the settings change through `devenv.nix`.
- [The new view makes some non-link path ask.] → It can't, by the equality in decision 1. The whole existing suite (1282 cases) must still pass unchanged, and task 1.3 lists non-link controls.
- [A linked directory in `.claude` still slips through for the files below it.] → Non-goal. The link itself asks when written. Recorded in Open Questions.
- [Merge conflicts with the sessions editing `claude-guard.py`.] → The edit is one function at 2313-2329, away from their ranges. The tests are a new block and rows appended to one list.
- [The README paragraph is guidance only; a reviewer can still run probes through Bash.] → Accepted. The plugin repository's review guidance carries the same rule to reviewers, separately.

## Migration Plan

No migration. Projects get both changes with their next `devenv update coldlogic-devenv`; the sandbox entry takes effect when the settings are regenerated outside a session and the session is restarted. Rollback is reverting the commit.

## Open Questions

- Should a linked directory in `.claude` (a link above the last component) ask too? Not needed for #56. Worth a follow-up only if devenv or a project starts linking whole directories there.
- Should #79 stay open after this change for the plugin-side review guidance, or be closed by the two together? Doesn't affect this change.
