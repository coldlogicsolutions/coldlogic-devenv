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
              "devenv shell *", "wrangler dev *", "wc *", "npm run *",
              "git diff:*"],
    "ask": ["git push *", "npm run deploy:*"],
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
    ("git -c core.x=y push -f", DENY),
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
    ("gh-app pr review 12 --approve", DENY),
    ("gh-app api repos/o/r/pulls/12/reviews -f event=APPROVE", DENY),
    ("gh-app pr view 12", ALLOW),
    # From the security review.
    ("git status\ngit push --force", DENY),
    ("git log --oneline\nrm -rf build", NONE),
    ("git push --forc", DENY),
    ("git push --mirr /x", DENY),
    ("git push -4f /x", DENY),
    ("git reset --har", DENY),
    ("git -c alias.p='push --force' p", ASK),
    ("git -c core.x=y push -f; echo 'unclosed", DENY),
    ("echo 'unclosed; git reset --hard", DENY),
    ("cat $(echo /etc/passwd)", NONE),
    ("uniq in.txt out.txt", NONE),
    ("git --exec-path=/tmp/x status", ASK),
    ("git --git-dir=/x/.git log", ASK),
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
    # From the second review.
    ("git status # check\nrm -rf build", NONE),
    ("git status x#; rm -rf build", NONE),
    ("git commit -m \"see <<EOF\"\ngit push --force\nEOF", DENY),
    ("echo '<<X'\nrm -rf build\nX", NONE),
    ("cat <(python3 evil.py)", NONE),
    ("cat <(git push -f)", DENY),
    ("git -c diff.external=./evil.sh diff", ASK),
    ("git -c pager.log='sh -c evil' log", ASK),
    ("git -c include.path=x.cfg status", ASK),
    ("cd && cat .ssh/id_rsa", NONE),
    ("cd sub && scripts/check.sh", NONE),
    ("sort --compress-program=./evil x", NONE),
    ("cat .DEV.VARS", DENY),
    ("< .dev.vars cat", DENY),
    ("echo \"$(<.dev.vars)\"", DENY),
    ("{ git push -f; }", DENY),
    ("if true; then git push -f; fi", DENY),
    ("for b in a c; do git push -f; done", DENY),
    ("! git push -f", DENY),
    ("env -u FOO git push -f", DENY),
    ("env -S 'git push -f'", DENY),
    ("exec -a x git push -f", DENY),
    ("bash -o pipefail -c 'git push -f'", DENY),
    ("echo x | xargs git push -f", DENY),
    ("git -P push --force", DENY),
    ("git -c remote.origin.mirror=true push origin", ASK),
    ("git -C sub status", NONE),
    ("git -C . status", ALLOW),
    ("npx wrangler@latest deploy", DENY),
    ("pnpm wrangler deploy", DENY),
    ("wrangler --env prod deploy", DENY),
    ("wrangler pages deploy dist", DENY),
    ("nix --extra-experimental-features flakes develop", DENY),
    ("gh pr --repo o/r merge 1", DENY),
    ("gh api graphql -F query=@q.graphql", ASK),
    ("git log '*.rs'", ALLOW),
    ("git log *.rs", NONE),
    ("echo $HOME", NONE),
    ("git commit -m 'fix #12'", ALLOW),
    # From the third review.
    ("cat <<EOF\n$(git push --force)\nEOF", DENY),
    ("git commit -F - <<X\n$(rm -rf build)\nX", NONE),
    ("cat <<'EOF'\n$(rm -rf build)\nEOF", ALLOW),
    ("git diff --no-index /dev/null $(printf .dev.%s vars)", NONE),
    ("git commit --allow-empty -F \"$(printf x)\"", NONE),
    ("git push $(echo --force)", ASK),
    ("git commit --allow-empty --file=.dev.vars", DENY),
    ("wc --files0-from=.dev.vars", DENY),
    ("wc --files0-from=list.txt", NONE),
    ("git diff --output=out.patch", NONE),
    ("time -p git push --force", DENY),
    ("sudo git push --force", DENY),
    ("env -P /tmp git push --force", DENY),
    ("find . -exec git push --force \\;", DENY),
    ("busybox sh -c 'git push --force'", DENY),
    ("fish -c 'git push --force'", DENY),
    ("git --no-lazy-fetch push --force", DENY),
    ("git --git-dir .git push --force", DENY),
    ("git --work-tree . reset --hard", DENY),
    ("git push $'--force'", DENY),
    ("git reset $'--hard'", DENY),
    ("git push {--force,}", DENY),
    ("cat {.dev.vars,}", DENY),
    ("cat .dev.var{s,}", DENY),
    ("cat $'.dev.vars'", DENY),
    ("env --split-string='git push --force'", DENY),
    ("env -S'git push --force'", DENY),
    ("gh pr review 12 --approve=true", DENY),
    ("gh pr review 12 -ab LGTM", DENY),
    ("gh --repo o/r api repos/o/r/pulls/1/merge", DENY),
    ("node node_modules/wrangler/bin/wrangler.js deploy", DENY),
    ("git -C /tmp/evil status", NONE),
    ("npx -p evil-pkg wrangler dev", NONE),
    ("npx wrangler dev", ALLOW),
    ("npm run deploy:prod", ASK),
    ("cat {a,b}{c,d}{e,f}{g,h}{i,j}{k,l}{m,n}", ASK),
    ("git --a --b --c --d --e --f push --force", DENY),
    ("git commit -aF.dev.vars", DENY),
    ("gh -R o/r --hostname h.com x api repos/o/r/pulls/1/merge", DENY),
    # From the fourth review.
    ("npx -c 'git status && touch pwned'", NONE),
    ("pnpm exec -c 'git push --force'", DENY),
    ("\"git status x/evil\"", NONE),
    ("git log -m \"$(printf x)\"", NONE),
    ("git commit -m \"$(printf x)\"", ALLOW),
    ("git commit -F/etc/passwd", NONE),
    ("grep -f/etc/passwd README.md", NONE),
    ("cargo test --config 'build.rustc-wrapper=\"./evil\"'", NONE),
    ("cargo +nightly test", NONE),
    ("jq -n env", NONE),
    ("cat =ssh", NONE),
    ("echo hi >&2x", NONE),
    ("echo hi >&2", ALLOW),
    ("ls *", NONE),
    ("cat .e*", DENY),
    ("env FOO=1 timeout 5 git push -f", DENY),
    # Ordinary pushes and resets are left to the rules.
    ("git push -u origin feat", ASK),
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
    ("cd sub && git diff", NONE),
    ("git diff HEAD~1", ALLOW),
    ("git commit -qm \"$(cat <<'EOF'\nfix: x\n\ngit push --force is mentioned here\nEOF\n)\"", ALLOW),
    # A wrapper's own allow rule doesn't reach inside it.
    ("devenv shell --quiet -- rm -rf build", ASK),
    ("devenv shell -- cargo publish", DENY),
    # Writing a file isn't auto-allowed.
    ("git log > out.txt", NONE),
    # Nothing to say: Claude Code's rules decide.
    ("rm -rf build", NONE),
    ("npm run deploy", ASK),
    ("git difftool -y -x 'touch pwned'", NONE),
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
    ("Read", {"file_path": "/p/.DEV.VARS"}, DENY),
    ("Grep", {"path": "/p", "glob": ".dev.vars"}, DENY),
    ("Glob", {"pattern": "**/.env.local"}, DENY),
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
