"""Cases for claude-guard.py: python3 claude-guard-test.py."""

import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location(
    "guard", os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

POLICY = {
    "allow": ["scripts/check.sh", "git status *", "git diff *", "git log *",
              "git add *", "git commit *", "cargo test *", "gh-app pr view *",
              "devenv shell *"],
    "deny": ["cargo publish *"],
}

DENY, ALLOW, ASK, NONE = "deny", "allow", "ask", None

BASH = [
    # Forbidden however it's spelled.
    ("git push --force", DENY),
    ("git push -f origin main", DENY),
    ("git push -uf origin feat", DENY),
    ("git push origin +main", DENY),
    ("git push --force-with-lease", DENY),
    ("git -C . push --force", DENY),
    ("git -c core.x=y push -f", ASK),
    ("devenv shell --quiet -- git push --force", DENY),
    ("devenv shell git reset --hard", DENY),
    ("devenv --quiet shell -- git -C /x reset --hard HEAD~1", DENY),
    ("bash -c 'git reset --hard'", DENY),
    ("env FOO=1 git reset --hard", DENY),
    ("timeout 5 git push -f", DENY),
    ("npx wrangler deploy", DENY),
    ("pnpm exec wrangler deploy", DENY),
    ("pnpm dlx wrangler versions deploy", DENY),
    ("wrangler deploy --env preview", DENY),
    ("nix develop", DENY),
    ("echo $(git reset --hard)", DENY),
    ("cat $(echo .env)", DENY),
    ("git log $(rm -rf x)", NONE),
    ("git status && git push -f", DENY),
    ("gh pr merge 12 --squash", DENY),
    ("gh api -X PUT repos/o/r/pulls/12/merge", DENY),
    ("gh-app pr merge 12 --squash", NONE),
    # From the security review.
    ("git status\ngit push --force", DENY),
    ("git log --oneline\nrm -rf build", NONE),
    ("git push --forc", DENY),
    ("git push --mirr /x", DENY),
    ("git push -4f /x", DENY),
    ("git reset --har", DENY),
    ("git -c alias.p='push --force' p", ASK),
    ("bash <<'EOF'\ngit push --force\nEOF", DENY),
    ("cat <<EOF | sh\ngit reset --hard\nEOF", DENY),
    ("python3 <<'EOF'\nimport os\nEOF", ASK),
    ("cat .e*", DENY),
    ("cat .dev.v?rs", DENY),
    ("./cat README.md", NONE),
    ("cat ~/.ssh/id_rsa", NONE),
    ("cat ../other/file", NONE),
    ("sort -o out.txt in.txt", NONE),
    ("grep -r KEY .", NONE),
    ("PATH=/tmp/x git status", NONE),
    ("GIT_SSH_COMMAND=x git status", NONE),
    ("gh pr review 12 --approve", DENY),
    ("gh api graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'", DENY),
    ("gh api repos/o/r/pulls/12/reviews -f event=APPROVE", DENY),
    ("gh alias set m 'pr merge'", DENY),
    ("gh api repos/o/r/pulls/1 --input body.json", ASK),
    # Ordinary pushes and resets are left to the rules.
    ("git push -u origin feat", NONE),
    ("git reset --soft HEAD~1", NONE),
    # Secrets files.
    ("cat .env", DENY),
    ("cat app/.env", DENY),
    ("cat .env.local", DENY),
    ("cp .env.example .env", DENY),
    ("echo X=1 >> .env", DENY),
    ("cat .dev.vars", DENY),
    ("devenv shell -- cat ./.dev.vars", DENY),
    ("ls secrets/", DENY),
    ("cat .env.example", ALLOW),
    ("cat .dev.vars.example", ALLOW),
    # Allowed when every command inside matches.
    ("git status", ALLOW),
    ("git log --oneline -3 | head -5", ALLOW),
    ("devenv shell --quiet -- scripts/check.sh", ALLOW),
    ("devenv shell --quiet -- cargo test 2>&1 | tail -20", ALLOW),
    ("cd sub && git diff", ALLOW),
    ("git diff HEAD~1", ALLOW),
    ("git commit -qm \"$(cat <<'EOF'\nfix: x\n\ngit push --force is mentioned here\nEOF\n)\"", ALLOW),
    # A wrapper's own allow rule doesn't reach inside it.
    ("devenv shell --quiet -- rm -rf build", ASK),
    ("devenv shell -- cargo publish", DENY),
    # Writing a file isn't auto-allowed.
    ("git log > out.txt", NONE),
    # Nothing to say: Claude Code's rules decide.
    ("rm -rf build", NONE),
    ("FOO=1 cargo build", NONE),
    # Unparsable.
    ("echo 'unclosed", ASK),
    ("devenv --weird-flag shell -- ls", ASK),
]

FILES = [
    ("Read", {"file_path": "/p/.env"}, DENY),
    ("Read", {"file_path": "/p/sub/.env.production"}, DENY),
    ("Edit", {"file_path": "/p/.dev.vars"}, DENY),
    ("Write", {"file_path": "/p/config/secrets/key.pem"}, DENY),
    ("Read", {"file_path": "/p/.env.example"}, NONE),
    ("Edit", {"file_path": "/p/.env.example"}, NONE),
    ("Grep", {"path": "/p/.env"}, DENY),
    ("Read", {"file_path": "/p/src/env.rs"}, NONE),
]

failures = 0
for command, expected in BASH:
    got = guard.decide("Bash", {"command": command}, POLICY)
    got = got[0] if got else None
    if got != expected:
        failures += 1
        print(f"FAIL Bash {command!r}: expected {expected}, got {got}")
for tool, tool_input, expected in FILES:
    got = guard.decide(tool, tool_input, POLICY)
    got = got[0] if got else None
    if got != expected:
        failures += 1
        print(f"FAIL {tool} {tool_input}: expected {expected}, got {got}")
total = len(BASH) + len(FILES)
print(f"{total - failures}/{total} passed")
sys.exit(1 if failures else 0)
