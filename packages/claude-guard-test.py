"""Cases for claude-guard.py: python3 claude-guard-test.py."""

import importlib.util
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location(
    "guard", os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

POLICY = {
    "allow": ["scripts/check.sh", "git status *", "git diff *", "git log *",
              "git add *", "git commit *", "cargo test *", "gh-app pr view *",
              "devenv shell *", "wrangler dev *", "wc *", "npm run *",
              "git diff:*", "git worktree *"],
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
    ("cat $(echo .env)", NONE),
    ("git log $(rm -rf x)", NONE),
    ("git status && git push -f", DENY),
    ("gh pr merge 12 --squash", DENY),
    ("gh api -X PUT repos/o/r/pulls/12/merge", DENY),
    ("gh-app pr merge 12 --squash", NONE),
    ("gh-app pr review 12 --approve", DENY),
    ("gh-app api repos/o/r/pulls/12/reviews -f event=APPROVE", DENY),
    ("gh-app pr view 12", ALLOW),
    # The App merges only through `gh-app pr merge`, which checks the PR.
    ("gh-app api -X PUT repos/o/r/pulls/1/merge", DENY),
    ("gh-app api --method=PUT repos/o/r/pulls/1/merge -f merge_method=squash", DENY),
    ("devenv shell --quiet -- gh-app api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"X\"}){clientMutationId}}'", DENY),
    ("gh-app api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"X\"}){clientMutationId}}'", DENY),
    ("gh-app api repos/o/r/pulls/1/merge", NONE),
    ("gh-app pr merge --auto --squash 12", NONE),
    ("gh-app pr view 12 --json mergeable,mergeStateStatus", ALLOW),
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
    # A script fed to an interpreter is left to the sandbox, unless a string
    # in it names a secrets file.
    ("python3 <<'EOF'\nimport os\nEOF", NONE),
    ("python3 - <<'EOF'\nopen('src/a.rs').read()\nEOF\ndevenv shell --quiet -- cargo test", NONE),
    ("python3 - <<'EOF'\nopen('.env').read()\nEOF", DENY),
    ("devenv shell --quiet -- python3 - <<EOF\nopen(\"config/secrets/key\")\nEOF", DENY),
    ("python3 <<'EOF'\nprint('x')\nEOF\ngit push --force", DENY),
    ("python3 - <<EOF\n$(git push --force)\nEOF", DENY),
    ("python3 - <<EOF\nx = `git reset --hard`\nEOF", DENY),
    ("python3 - <<'EOF'\n$(git push --force)\nEOF", NONE),
    ("python3 - <<'EOF'\nprint('secrets', \"no .env here\")\nEOF", NONE),
    ("python3 - <<'EOF'\nprint('see ./config/secrets/ docs')\nEOF", NONE),
    ("cat <<'EOF'\nopen('.env').read()\nEOF", NONE),
    # A quoted argument spanning lines is still one plain argument.
    ("git commit -m 'fix: x\n\nThe body.'", ALLOW),
    ("git commit -m \"fix: x\n\nThe body.\"", ALLOW),
    ("git commit -m \"fix: x\n$(rm -rf build)\"", NONE),
    ("git push \"origin\nmain\"", ASK),
    ("git status\n'x'", NONE),
    ("git commit -m 'a\n' && git push --force", DENY),
    ("git commit -m 'a\n' && rm -rf build", NONE),
    ("git commit -m 'a\n'\nrm -rf build", NONE),
    ("git commit -m 'a\r\nb'", ALLOW),
    ("git commit -m 'a\n'; rm x '\n'", NONE),
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
    ("git -p log", NONE),
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
    ("cat <<'EOF'\n$(rm -rf build)\nEOF", NONE),
    ("git diff --no-index /dev/null $(printf .dev.%s vars)", NONE),
    ("git commit --allow-empty -F \"$(printf x)\"", NONE),
    ("git push $(echo --force)", ASK),
    ("git commit --allow-empty --file=.dev.vars", DENY),
    ("wc --files0-from=.dev.vars", DENY),
    ("wc --files0-from=list.txt", ASK),
    ("git diff --output=out.patch", ASK),
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
    ("gh --repo o/r api repos/o/r/pulls/1/merge", NONE),
    ("gh --repo o/r api -X PUT repos/o/r/pulls/1/merge", DENY),
    ("node node_modules/wrangler/bin/wrangler.js deploy", DENY),
    ("git -C /tmp/evil status", NONE),
    ("npx -p evil-pkg wrangler dev", NONE),
    ("npx wrangler dev", NONE),
    ("npm run deploy:prod", ASK),
    ("cat {a,b}{c,d}{e,f}{g,h}{i,j}{k,l}{m,n}", ASK),
    ("git --a --b --c --d --e --f push --force", DENY),
    ("git commit -aF.dev.vars", DENY),
    ("gh -R o/r --hostname h.com x api repos/o/r/pulls/1/merge", NONE),
    # From the fourth review.
    ("npx -c 'git status && touch pwned'", NONE),
    ("pnpm exec -c 'git push --force'", DENY),
    ("\"git status x/evil\"", NONE),
    ("git log -m \"$(printf x)\"", NONE),
    ("git commit -m \"$(printf x)\"", NONE),
    ("git commit -F/etc/passwd", ASK),
    ("grep -f/etc/passwd README.md", NONE),
    ("cargo test --config 'build.rustc-wrapper=\"./evil\"'", ASK),
    ("cargo +nightly test", NONE),
    ("jq -n env", NONE),
    ("cat =ssh", NONE),
    ("echo hi >&2x", DENY),
    ("echo hi >&2", NONE),
    ("ls *", NONE),
    ("cat .e*", DENY),
    ("env FOO=1 timeout 5 git push -f", DENY),
    ("pnpm exec wrangler deploy -c wrangler.toml", DENY),
    ("devenv shell -- npx wrangler versions deploy -c x.toml", DENY),
    ("gh-app alias set r 'pr review --approve'", DENY),
    ("gh-app api graphql --input q.json", ASK),
    ("cat *(D)", DENY),
    ("cat *(.)", NONE),
    ("cat *($(git push --force))", DENY),
    ("gh-app api repos/o/r/pulls/1/reviews --input x.json", ASK),
    ("npx wrangler -c 'git push --force'", DENY),
    # From the sixth review.
    ("devenv shell rm -rf src", ASK),
    ("devenv shell bash -c 'rm -rf src'", ASK),
    ("devenv shell --quiet -- devenv shell --quiet -- rm -rf src", ASK),
    ("git commit -m \"$(cat <<'EOF'\nfix: don't let a session read .env\n\n1) stop git reset --hard paths\nEOF\n)\"", ALLOW),
    ("git add -f ':(glob).dev.var*'", DENY),
    ("git log -p -- ':(icase).DEV.VARS'", DENY),
    ("npx -c 'echo hi' wrangler -c 'git push --force'", DENY),
    ("npx --call='git push --force' wrangler", DENY),
    ("pnpm dlx wrangler -c 'git reset --hard'", DENY),
    ("cat *(e:'git push --force':)", ASK),
    ("npx --cal='git push --force' wrangler", DENY),
    ("cat *(/D)", ASK),
    ("git commit -m \"$(cat <<'EOF'\nline\nEOF)\n$(touch pwned1)\nEOF\n)\"", NONE),
    ("grep -5r TOKEN .", NONE),
    ("wc --files0=list", ASK),
    ("git commit -m \"$(cat <<'EOF'\n)\n\"; touch pwned; echo \"\nEOF\n)\"", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix (#12)\nEOF\n)\"", ALLOW),
    ("cat $'.dev.var\\u017f'", DENY),
    ("cat 'ſecrets/key'", DENY),
    ("wc --f=list2", ASK),
    ("git commit --file=msg.txt", ALLOW),
    ("git diff HEAD:.dev.vars HEAD:README.md", DENY),
    ("wrangler dev -c other.toml", ASK),
    ("wrangler dev --config=other.toml", ASK),
    ("git log --output=x", ASK),
    ("gh-app pr view 1 --json number --jq env.GH_TOKEN", ASK),
    ("gh-app pr view 1 -q env", ASK),
    ("gh-app pr view 1 --json title", ALLOW),
    ("git add -f :.dev.vars", DENY),
    ("git add -f ::.dev.vars", DENY),
    ("git add -f :/:.dev.vars", DENY),
    ("git add -f :0:.dev.vars", DENY),
    ("cat <<EOF\n\tEOF\ncat <<X\nEOF\ngit push --force\nX", DENY),
    ("wrangler dev -jc other.toml", ASK),
    ("node_modules/.bin/wrangler dev --config=x.toml", NONE),
    ("git log --follow README.md", ALLOW),
    ("@d/wrangler dev -c x.toml", NONE),
    ("npx @cloudflare/wrangler@3 deploy", DENY),
    ("git commit -Fm \"$(cat <<'EOF'\n--pathspec-from-file=.env.preview\nEOF\n)\"", NONE),
    ("git commit -am \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("git commit --amend -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("wrangler dev --c other.toml", ASK),
    ("cat .env-production", DENY),
    ("cat .env_local", DENY),
    ("cat .envrc", ALLOW),
    ("cd sub && git status", NONE),
    ("git commit -F /private/tmp/claude-501/scratch/msg.txt", ALLOW),
    ("git diff --no-index /tmp/a /tmp/b", ALLOW),
    ("git diff --no-index /etc/a /tmp/b", ASK),
    # Mentioning a secrets file without reading it.
    ("echo .dev.vars >> .gitignore", DENY),
    ("echo .dev.vars >> \"$TMPDIR/ignore\"", NONE),
    ("git check-ignore -v .dev.vars", NONE),
    ("git rm --cached .env", NONE),
    ("ls -la .dev.vars", ALLOW),
    ("test -f .dev.vars && echo yes", NONE),
    ("grep -n '.dev.vars' .gitignore", ALLOW),
    ("grep -n .gitignore -e .dev.vars", DENY),
    ("devenv shell --quiet -- wrangler dev --env-file .dev.vars", ALLOW),
    ("gh-app pr create --title \"fix: stop reading config/.dev.vars\" --body x", NONE),
    ("git commit -m \"chore: ignore apps/api/.env\"", ALLOW),
    ("git add -f .dev.vars", DENY),
    ("gh-app pr merge 12 --squash", NONE),
    ("gh pr merge 12 --squash", DENY),
    ("git grep -n '.dev.vars'", NONE),
    ("git log -p rm -- .dev.vars", DENY),
    ("devenv shell --quiet -- wrangler deploy --env dev --env-file .dev.vars", DENY),
    # From the productivity review.
    ("gh-app pr create --title x --body \"$(cat <<'EOF'\nThis doesn't touch .env or git push --force.\nEOF\n)\"", NONE),
    ("devenv shell --quiet -- cargo test 2>&1", ALLOW),
    ("devenv shell --quiet -- cargo test 2>&1 | tail -20", ALLOW),
    ("devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW),
    ("git log --oneline | head -3", ALLOW),
    ("git log | rm -rf x", NONE),
    ("devenv shell --quiet -- wrangler deploy --dry-run --outdir dist", ASK),
    ("gh-app api repos/o/r/pulls/12/reviews", NONE),
    ("gh api repos/o/r/pulls/12 --jq .mergeable", NONE),
    ("gh pr list --search \"merge\"", NONE),
    ("gh-app api repos/o/r/pulls/12/reviews -f event=APPROVE", DENY),
    # Answering a review thread isn't reviewing.
    ("gh-app api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{url}}}' -f t=X -f b=done", NONE),
    ("gh-app api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t=X", NONE),
    ("gh api graphql -f query='mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{url}}}' -f t=X -f b=done", NONE),
    ("gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t=X", NONE),
    # Creating a review still is, whatever its event.
    ("gh-app api graphql -f query='mutation{addPullRequestReview(input:{pullRequestId:\"X\",event:APPROVE}){clientMutationId}}'", DENY),
    ("gh api graphql -f query='mutation{addPullRequestReview(input:{pullRequestId:\"X\"}){clientMutationId}}'", DENY),
    ("gh-app pr create -t \"fix: x\" -b \"body\"", NONE),
    ("gh-app pr view 12 --json reviews --jq '.reviews[].state'", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix(guard): handle x\nEOF\n)\"", ALLOW),
    ("git diff main...HEAD -- '*.py'", ALLOW),
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
    ("ls secrets/", ALLOW),
    ("cat .env.example", ALLOW),
    ("cat .dev.vars.example", ALLOW),
    # Allowed when every command inside matches.
    ("git status", ALLOW),
    ("git log --oneline -3 | head -5", ALLOW),
    ("devenv shell --quiet -- scripts/check.sh", ALLOW),
    ("cd sub && git diff", NONE),
    ("git diff HEAD~1", NONE),
    ("devenv shell --quiet -- cargo test --workspace", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\"; touch x", NONE),
    ("git commit -qm \"$(cat <<'EOF'\nfix: x\n\ngit push --force is mentioned here\nEOF\n)\"", ALLOW),
    # A wrapper's own allow rule doesn't reach inside it.
    ("devenv shell --quiet -- rm -rf build", ASK),
    ("devenv shell -- cargo publish", DENY),
    # Writing a file isn't auto-allowed.
    ("git log > \"$TMPDIR/log.txt\"", NONE),
    # Changing a project file from Bash is turned to the Edit and Write tools.
    ("git log > out.txt", DENY),
    ("sed -i 's/a/b/' src/main.rs", DENY),
    ("sed -i '' 's/a/b/' src/main.rs", DENY),
    ("sed -i.bak -e 's/a/b/' a.txt", DENY),
    ("sed -E -i 's/a/b/' a.txt b.txt", DENY),
    ("sed --in-place 's/a/b/' a.txt", DENY),
    ("devenv shell --quiet -- sed -i 's/a/b/' src/main.rs", DENY),
    ("perl -pi -e 's/a/b/' src/main.rs", DENY),
    ("perl -i -pe 's/a/b/' src/main.rs", DENY),
    ("grep -rl x src | xargs sed -i 's/a/b/'", DENY),
    ("find src -name '*.rs' -exec sed -i 's/a/b/' {} +", DENY),
    ("echo x | tee src/out.txt", DENY),
    ("echo x | tee -a notes.md", DENY),
    ("echo x > src/a.rs", DENY),
    ("printf x >> README.md", DENY),
    ("cat > src/a.rs <<'EOF'\nfn main() {}\nEOF", DENY),
    ("cat <<'EOF' > src/a.rs\nfn main() {}\nEOF", DENY),
    ("devenv shell --quiet -- cargo test 2> err.log", DENY),
    ("devenv shell --quiet -- cargo test &> build.log", DENY),
    ("bash -c 'echo x > src/a.rs'", DENY),
    ("echo $(echo x > src/a.rs)", DENY),
    ("python3 - <<'EOF'\nfrom pathlib import Path\np = Path('src/a.rs')\np.write_text(p.read_text().replace('a', 'b'))\nEOF\ndevenv shell --quiet -- cargo test", DENY),
    ("python3 - <<'EOF'\nwith open('src/a.rs', 'w') as f:\n    f.write('x')\nEOF", DENY),
    ("python3 <<EOF\nopen(\"src/a.rs\", mode=\"a\").write(\"x\")\nEOF", DENY),
    ("python3 -c \"open('a.txt', 'w').write('x')\"", DENY),
    ("python -c 'import pathlib; pathlib.Path(\"x\").open(\"w\")'", DENY),
    ("node -e \"require('fs').writeFileSync('a.json', '{}')\"", DENY),
    ("devenv shell --quiet -- node <<'EOF'\nconst fs = require('fs');\nfs.writeFileSync('a', 'b');\nEOF", DENY),
    ("perl -e 'open(my $f, \">\", \"x.txt\")'", DENY),
    ("ruby -e 'File.write(\"x.txt\", \"y\")'", DENY),
    # Reading, and writing to a device or a scratch file, still pass.
    ("cargo build >/dev/null 2>&1", NONE),
    ("cargo build 2>/dev/null", NONE),
    ("devenv shell --quiet -- cargo test 2>/dev/null", ASK),
    ("echo x > \"$TMPDIR/body.md\"", NONE),
    ("echo x > ${TMPDIR}/body.md", NONE),
    ("echo x > /tmp/claude-501/scratch/x", NONE),
    ("echo x >> /private/tmp/claude-501/scratch/log", NONE),
    ("echo x > /dev/stderr", NONE),
    ("echo x > ~/notes.txt", NONE),
    ("cat <<'EOF'\nopen(f, 'w') and sed -i are mentioned here\nEOF", NONE),
    ("gh-app pr create --title x --body-file - <<'EOF'\nNo more `sed -i` or `> file`; open(f, 'w') neither.\nEOF", NONE),
    ("gh-app issue comment 3 --body-file \"$TMPDIR/body.md\"", NONE),
    ("sed 's/a/b/' src/a.rs", NONE),
    ("sed -n '1,20p' src/a.rs", NONE),
    ("sed -e 's/a/b/' -n src/a.rs | head", NONE),
    ("sed -i 's/a/b/' \"$TMPDIR/x\"", NONE),
    ("sed -i '' 's/a/b/' /tmp/claude-501/x", NONE),
    ("perl -ne 'print if /x/' src/a.rs", NONE),
    ("echo x | tee /dev/null", NONE),
    ("echo x | tee -a \"$TMPDIR/log\"", NONE),
    ("cargo build 2>&1 | tee", NONE),
    ("python3 - <<'EOF'\nprint(open('src/a.rs').read())\nEOF", NONE),
    ("python3 -c 'import json; print(json.load(open(\"a.json\", \"rb\")))'", NONE),
    ("node -e \"console.log(require('fs').readFileSync('a', 'utf8'))\"", NONE),
    # From the review: reads that only look like writes, scratch writes from a
    # script, a script's arguments, and paths spelled through the project.
    ("python3 -c \"print(open('a').read(), 'which')\"", NONE),
    ("python3 -c \"open(os.path.join('a', 'b'), 'w').write('x')\"", DENY),
    ("python3 -c \"open('/tmp/claude-501/x', 'w').write('y')\"", NONE),
    ("node -e \"require('fs').writeFileSync(process.env.TMPDIR + '/x', 'y')\"", NONE),
    ("node script.js \"fs.writeFile(x)\"", NONE),
    ("python3 tool.py --out \"open(x, 'w')\"", NONE),
    ("echo x > \"$CLAUDE_PROJECT_DIR/src/a.rs\"", DENY),
    ("echo x > \"$PWD/src/a.rs\"", DENY),
    ("echo x > \"${PWD}/src/a.rs\"", DENY),
    ("echo x > \"$OUT/a.rs\"", NONE),
    ("echo x > .git/hooks/pre-commit", NONE),
    ("python3.12 <<'EOF'\nopen('src/a.rs', 'w').write('x')\nEOF", DENY),
    ("uv run python -c \"open('a.txt', 'w').write('x')\"", DENY),
    ("python3 tool.py -c \"open(x, 'w')\"", NONE),
    ("python3 -W ignore -c \"open('f', 'w').write('x')\"", DENY),
    ("echo x >! out.txt", DENY),
    ("echo x >! \"$TMPDIR/out.txt\"", NONE),
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
    ("Write", {"file_path": "/p/nested/.git/config"}, DENY),
    ("Read", {"file_path": "/p/.git/config"}, NONE),
    ("Read", {"file_path": "/p/.DEV.VARS"}, DENY),
    ("Grep", {"path": "/p", "glob": ".dev.vars"}, DENY),
    ("Glob", {"pattern": "**/.env*"}, NONE),
    ("Read", {"file_path": "/p/.envrc"}, NONE),
    ("Read", {"file_path": "/p/.env.sample"}, NONE),
    ("Read", {"file_path": "/p/.env.local.example"}, NONE),
    ("Edit", {"file_path": "/p/.dev.vars.local.example"}, NONE),
    ("Read", {"file_path": "/p/.env.dist"}, NONE),
    ("Read", {"file_path": "/p/.env.local"}, DENY),
]

failures = 0
checks = 0
for command, expected in BASH:
    got = guard.decide("Bash", {"command": command}, POLICY)
    checks += 1
    got = got[0] if got else None
    if got != expected:
        failures += 1
        print(f"FAIL Bash {command!r}: expected {expected}, got {got}")
for tool, tool_input, expected in FILES:
    got = guard.decide(tool, tool_input, POLICY)
    checks += 1
    got = got[0] if got else None
    if got != expected:
        failures += 1
        print(f"FAIL {tool} {tool_input}: expected {expected}, got {got}")
# Rules seen against the command as written, and a bare `Bash` rule.
for policy, command, expected in [
    ({"allow": ["git status *"], "ask": ["devenv shell:*"]}, "devenv shell --quiet -- git status", ASK),
    ({"allow": ["git status *"], "ask": ["*"]}, "git status", ASK),
    ({"allow": [], "deny": ["git push *"]}, "git --literal-pathspecs push origin x", DENY),
    ({"allow": [], "deny": ["git push *"]}, "/usr/bin/git --literal-pathspecs push origin x", DENY),
]:
    got = guard.decide("Bash", {"command": command}, policy)
    checks += 1
    got = got[0] if got else None
    if got != expected:
        failures += 1
        print(f"FAIL policy {policy} {command!r}: expected {expected}, got {got}")

# A project inside a directory named secrets.
with tempfile.TemporaryDirectory() as top:
    root = os.path.join(top, "secrets", "proj")
    os.makedirs(root)
    open(os.path.join(root, "README.md"), "w").close()
    guard.WORKING.update(cwd=root, root=root)
    checks += 1
    got = guard.decide("Bash", {"command": "cat README.md"}, POLICY)
    guard.WORKING.update(cwd=None, root=None)
    if got is None or got[0] != "allow":
        failures += 1
        print(f"FAIL a project under secrets/: expected allow, got {got}")

# A symlink inside the project that leads out of it.
with tempfile.TemporaryDirectory() as root:
    os.symlink("/etc", os.path.join(root, "link"))
    guard.WORKING.update(cwd=root, root=root)
    checks += 1
    got = guard.decide("Bash", {"command": "cat link/hosts"}, POLICY)
    guard.WORKING.update(cwd=None, root=None)
    if got is not None:
        failures += 1
        print(f"FAIL symlink out of the project: expected None, got {got}")

# The seventh review: repositories git could find besides the project's.
with tempfile.TemporaryDirectory() as root:
    os.makedirs(os.path.join(root, "sub", "objects"))
    os.makedirs(os.path.join(root, "sub", "refs"))
    open(os.path.join(root, "sub", "HEAD"), "w").close()
    open(os.path.join(root, ".env.preview"), "w").close()
    os.makedirs(os.path.join(root, "nested", ".git"))
    os.makedirs(os.path.join(root, "secrets"))
    open(os.path.join(root, "secrets", "key"), "w").close()
    os.symlink("secrets", os.path.join(root, "s"))
    # One of the project's own worktrees, and a directory that only claims to
    # be one.
    wt = os.path.join(root, ".claude", "worktrees", "x")
    os.makedirs(wt)
    os.makedirs(os.path.join(root, ".git", "worktrees", "x"))
    with open(os.path.join(wt, ".git"), "w") as f:
        f.write(f"gitdir: {os.path.join(root, '.git', 'worktrees', 'x')}\n")
    with open(os.path.join(root, ".git", "worktrees", "x", "gitdir"), "w") as f:
        f.write(os.path.join(wt, ".git") + "\n")
    with open(os.path.join(root, ".git", "worktrees", "x", "commondir"), "w") as f:
        f.write("../..\n")
    fake = os.path.join(root, "fake")
    os.makedirs(fake)
    with open(os.path.join(fake, ".git"), "w") as f:
        f.write(f"gitdir: {os.path.join(root, '.git', 'worktrees', 'x')}\n")
    os.symlink(".env.preview", os.path.join(root, "notes.txt"))
    os.symlink("/tmp", os.path.join(root, "outlink"))
    for cwd, command, expected in [
        (root, "git --bare diff a b", None),
        (os.path.join(root, "sub"), "git diff --no-index a b", "allow"),
        (os.path.join(root, "sub"), "scripts/check.sh", "ask"),
        (os.path.join(root, "sub"), "gh-app pr view 1", "allow"),
        (root, "git add --pathspec-from=list.txt", "ask"),
        (root, "cat s/key", "deny"),
        (root, "touch s/newkey", "deny"),
        (root, f"cat {root}/notes.txt", "deny"),
        (root, "wc --outp=x", "ask"),
        (wt, "devenv shell --quiet -- scripts/check.sh", "allow"),
        (fake, "devenv shell --quiet -- scripts/check.sh", "ask"),
        (root, "git diff --no-index a b", "allow"),
        (root, "cat notes.txt", "deny"),
        (root, "git worktree add outlink/newwt", "ask"),
        (root, "git log -p -- '*env'", "allow"),
        (os.path.join(root, "nested"), "git status", None),
        (root, "git add --pathspec-from-file=list.txt", "ask"),
        (root, "git log --format=x -- '--x=*env'", "allow"),
    ]:
        guard.WORKING.update(cwd=cwd, root=root)
        got = guard.decide("Bash", {"command": command}, POLICY)
        checks += 1
        got = got[0] if got else None
        if got != expected:
            failures += 1
            print(f"FAIL {command!r} in {cwd}: expected {expected}, got {got}")
    guard.WORKING.update(cwd=None, root=None)

# Shell edits by absolute path: inside the project they're turned to the
# Edit and Write tools, outside it they're left to the rules.
with tempfile.TemporaryDirectory() as root:
    root = os.path.realpath(root)
    os.makedirs(os.path.join(root, "src"))
    guard.WORKING.update(cwd=root, root=root)
    for command, expected in [
        (f"echo x > {root}/src/a.rs", "deny"),
        (f"sed -i '' 's/a/b/' {root}/src/a.rs", "deny"),
        (f"echo x | tee {root}/notes.md", "deny"),
        ("echo x > src/a.rs", "deny"),
        ("echo x > ../elsewhere.txt", None),
        ("echo x > /etc/elsewhere", None),
        (f"echo x > {os.path.dirname(root)}/elsewhere.txt", None),
    ]:
        guard.WORKING.update(cwd=root, root=root)
        got = guard.decide("Bash", {"command": command}, POLICY)
        checks += 1
        got = got[0] if got else None
        if got != expected:
            failures += 1
            print(f"FAIL {command!r} in a project: expected {expected}, got {got}")
    guard.WORKING.update(cwd=None, root=None)

# A session in a worktree beside the project, outside its root. Both live in
# a temporary directory here, which would otherwise count as scratch.
with tempfile.TemporaryDirectory() as top:
    top = os.path.realpath(top)
    root, sibling = os.path.join(top, "proj"), os.path.join(top, "proj.worktrees", "x")
    os.makedirs(root)
    os.makedirs(sibling)
    real_scratch = guard.scratch
    guard.scratch = lambda path: False
    try:
        for command, expected in [
            ("sed -i '' 's/a/b/' src/a.rs", "deny"),
            ("echo x > src/a.rs", "deny"),
            (f"echo x | tee {sibling}/notes.md", "deny"),
            ("echo x > \"$TMPDIR/x\"", None),
            (f"echo x > {top}/elsewhere.txt", None),
        ]:
            guard.WORKING.update(cwd=sibling, root=root)
            got = guard.decide("Bash", {"command": command}, POLICY)
            checks += 1
            got = got[0] if got else None
            if got != expected:
                failures += 1
                print(f"FAIL {command!r} in a sibling worktree: expected {expected}, got {got}")
    finally:
        guard.scratch = real_scratch
        guard.WORKING.update(cwd=None, root=None)

# File tools on the project's Claude Code configuration ask; files in its
# worktrees, and anywhere else, are left to the Edit allow rule.
with tempfile.TemporaryDirectory() as root:
    root = os.path.realpath(root)
    guard.WORKING.update(cwd=root, root=root)
    for tool, path, expected in [
        ("Edit", f"{root}/.claude/settings.json", "ask"),
        ("Write", f"{root}/.claude/skills/x/SKILL.md", "ask"),
        ("Edit", f"{root}/.CLAUDE/hooks/x.sh", "ask"),
        ("Edit", ".claude/agents/x.md", "ask"),
        ("Write", f"{root}/.claude/worktrees/x/src/main.rs", None),
        ("Edit", f"{root}/.claude/worktrees/x/.claude/settings.json", "ask"),
        ("Write", f"{root}/.claude/worktrees/x", "ask"),
        ("Write", f"{root}/src/main.rs", None),
        ("Write", "/elsewhere/.claude/projects/p/memory/x.md", None),
        ("Read", f"{root}/.claude/settings.json", None),
    ]:
        got = guard.decide(tool, {"file_path": path}, POLICY)
        checks += 1
        got = got[0] if got else None
        if got != expected:
            failures += 1
            print(f"FAIL {tool} {path}: expected {expected}, got {got}")
    guard.WORKING.update(cwd=None, root=None)

# The project's own worktrees, wherever they sit (agent worktrees).
with tempfile.TemporaryDirectory() as top:
    top = os.path.realpath(top)

    def linked(root, wt, name):
        gitdir = os.path.join(root, ".git", "worktrees", name)
        os.makedirs(gitdir, exist_ok=True)
        os.makedirs(wt, exist_ok=True)
        with open(os.path.join(wt, ".git"), "w") as f:
            f.write(f"gitdir: {gitdir}\n")
        with open(os.path.join(gitdir, "gitdir"), "w") as f:
            f.write(os.path.join(wt, ".git") + "\n")
        with open(os.path.join(gitdir, "commondir"), "w") as f:
            f.write("../..\n")

    root = os.path.join(top, "proj")
    os.makedirs(os.path.join(root, ".git", "worktrees"))
    os.makedirs(os.path.join(root, "sub"))
    sib = os.path.join(top, "proj.worktrees", "x")
    linked(root, sib, "x")
    for d in ("packages", "src", os.path.join("vendor", "lib", ".git")):
        os.makedirs(os.path.join(sib, d))
    os.makedirs(os.path.join(sib, ".claude", "skills", "y"))
    open(os.path.join(sib, ".claude", "skills", "y", "SKILL.md"), "w").close()
    nested = os.path.join(root, ".claude", "worktrees", "n")
    linked(root, nested, "n")
    os.makedirs(os.path.join(nested, "src"))
    fake = os.path.join(top, "proj.worktrees", "fake")
    os.makedirs(fake)
    with open(os.path.join(fake, ".git"), "w") as f:
        f.write(f"gitdir: {os.path.join(root, '.git', 'worktrees', 'x')}\n")
    bc = os.path.join(top, "proj.worktrees", "bc")
    linked(root, bc, "bc")
    with open(os.path.join(root, ".git", "worktrees", "bc", "commondir"), "w") as f:
        f.write(os.path.join(top, "other", ".git") + "\n")
    other = os.path.join(top, "other")
    os.makedirs(os.path.join(other, ".git", "worktrees"))
    ow = os.path.join(top, "other.worktrees", "w")
    linked(other, ow, "w")
    policy = {**POLICY, "allow": POLICY["allow"] + ["git switch *"], "ask": POLICY["ask"] + ["git switch -f *"]}
    try:
        for cwd, command, expected in [
            (sib, "git status", "allow"),
            (sib, "git log --oneline -5", "allow"),
            (sib, "git switch -c feat/y", "allow"),
            (sib, "git switch -f main", "ask"),
            (sib, "git add packages/a.py", "allow"),
            (os.path.join(sib, "packages"), "git add a.py", "allow"),
            (os.path.join(sib, "packages"), "scripts/check.sh", "ask"),
            (sib, "devenv shell --quiet -- scripts/check.sh", "allow"),
            (sib, "git push --force", "deny"),
            (os.path.join(sib, "vendor", "lib"), "git status", "ask"),
            (sib, "cat ../y/README.md", None),
            (os.path.join(nested, "src"), "git log", "allow"),
            (fake, "git status", "ask"),
            (bc, "git status", "ask"),
            (ow, "git status", "ask"),
            (sib, f"git -C {sib} status", "allow"),
            (root, f"git -C {sib} log --oneline", "allow"),
            (sib, f"git -C {root} status", "allow"),
            (root, f"git -C {nested} status", "allow"),
            (sib, "git -C . status", "allow"),
            (os.path.join(root, "sub"), f"git -C {sib} status", None),
            (sib, f"git -C {sib}/packages status", None),
            (sib, f"git -C {fake} status", None),
            (sib, f"git -C {other} status", None),
            (sib, f"git -C {sib} push --force", "deny"),
        ]:
            guard.WORKING.update(cwd=cwd, root=root)
            got = guard.decide("Bash", {"command": command}, policy)
            checks += 1
            got = got[0] if got else None
            if got != expected:
                failures += 1
                print(f"FAIL {command!r} in {cwd}: expected {expected}, got {got}")
        for cwd, tool, path, expected in [
            (sib, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask"),
            (root, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask"),
            (sib, "Edit", f"{root}/.claude/settings.local.json", "ask"),
            (sib, "Write", f"{sib}/src/main.rs", None),
            (sib, "Write", f"{sib}/.git", "deny"),
            (sib, "Edit", f"{ow}/.claude/settings.json", None),
        ]:
            guard.WORKING.update(cwd=cwd, root=root)
            got = guard.decide(tool, {"file_path": path}, policy)
            checks += 1
            got = got[0] if got else None
            if got != expected:
                failures += 1
                print(f"FAIL {tool} {path} in {cwd}: expected {expected}, got {got}")
        real_scratch = guard.scratch
        guard.scratch = lambda path: False
        try:
            for cwd, command, expected in [
                (os.path.join(sib, "packages"), "echo x > ../src/b.rs", "deny"),
                (sib, "echo x > src/a.rs", "deny"),
                (sib, f"echo x > {top}/elsewhere.txt", None),
            ]:
                guard.WORKING.update(cwd=cwd, root=root)
                got = guard.decide("Bash", {"command": command}, policy)
                checks += 1
                got = got[0] if got else None
                if got != expected:
                    failures += 1
                    print(f"FAIL {command!r} in {cwd}: expected {expected}, got {got}")
        finally:
            guard.scratch = real_scratch
    finally:
        guard.WORKING.update(cwd=None, root=None)

total = checks
print(f"{total - failures}/{total} passed")
sys.exit(1 if failures else 0)
