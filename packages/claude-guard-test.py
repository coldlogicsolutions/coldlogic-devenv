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
              "git diff:*", "git worktree *", "gh-app issue create *",
              "gh-app issue view *", "git branch *", "git fetch *",
              "git rev-list *"],
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
    # An interpreter isn't a known data consumer: its body is checked for
    # denies as if it were a script.
    ("python3 - <<'EOF'\n$(git push --force)\nEOF", DENY),
    ("python3 - <<'EOF'\nprint('secrets', \"no .env here\")\nEOF", NONE),
    ("python3 - <<'EOF'\nprint('see ./config/secrets/ docs')\nEOF", NONE),
    ("cat <<'EOF'\nopen('.env').read()\nEOF", ALLOW),
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
    ("cat <<'EOF'\n$(rm -rf build)\nEOF", ALLOW),
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
    ("echo hi >&2", ALLOW),
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
    ("echo .dev.vars >> \"$TMPDIR/ignore\"", ALLOW),
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
    ("devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", DENY),
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
    ("git diff HEAD~1", ALLOW),
    ("devenv shell --quiet -- cargo test --workspace", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\"; touch x", NONE),
    ("git commit -qm \"$(cat <<'EOF'\nfix: x\n\ngit push --force is mentioned here\nEOF\n)\"", ALLOW),
    # A wrapper's own allow rule doesn't reach inside it.
    ("devenv shell --quiet -- rm -rf build", ASK),
    ("devenv shell -- cargo publish", DENY),
    # Writing a scratch file is fine.
    ("git log > \"$TMPDIR/log.txt\"", ALLOW),
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
    ("devenv shell --quiet -- cargo test 2>/dev/null", ALLOW),
    ("echo x > \"$TMPDIR/body.md\"", ALLOW),
    ("echo x > ${TMPDIR}/body.md", ALLOW),
    ("echo x > /tmp/claude-501/scratch/x", ALLOW),
    ("echo x >> /private/tmp/claude-501/scratch/log", ALLOW),
    ("echo x > /dev/stderr", ALLOW),
    ("echo x > ~/notes.txt", NONE),
    ("cat <<'EOF'\nopen(f, 'w') and sed -i are mentioned here\nEOF", ALLOW),
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
    # Heredocs.
    ("devenv shell --quiet -- gh-app issue create --title x --body-file - <<'EOF' 2>&1 | grep 'https://'\nRun gh pr merge 55.\nEOF", ALLOW),
    ("git status <<'EOF' && git push --force\nx\nEOF", DENY),
    ("git -c core.x=y commit -F - <<'EOF'\ngit push --force\nEOF", ASK),
    ("git -c core.x=y status; bash <<'EOF'\ngit push --force\nEOF", DENY),
    ("git -c core.x=y status; cat <<'EOF' | sh\ngit push --force\nEOF", DENY),
    ("git commit -F - <<'EOF'\nfix\nEOF\ngit push --force", DENY),
    ("git commit -F - <<'EOF'\nfix\nEOF\nrm -rf build", NONE),
    ("git commit -F - <<'EOF'\nfix", ASK),
    ("bash <<'EOF'\ngit status\nEOF", NONE),
    ("python3 - <<'EOF'\nprint(1)\nEOF", NONE),
    ("git commit -F - <<'EOF'\nfix: x\n\ngit push --force is quoted here\nEOF", ALLOW),
    ("devenv shell --quiet -- gh-app issue create --title x --body-file - <<'EOF'\nRun gh pr merge 55 --auto --squash.\nEOF", ALLOW),
    ("gh-app issue create --title x --body-file - <<'EOF' | grep https\nUse `rm -rf` and $(x) and don't\nEOF", ALLOW),
    ("gh-app issue create --title x --body-file - <<\"EOF\"\nbody $(x)\nEOF", ALLOW),
    ("git commit -F - <<-'EOF'\n\tfix\n\tEOF", ALLOW),
    # The attached and `=` spellings read stdin too.
    ("git commit -F- <<'EOF'\nfix: then git push --force\nEOF", ALLOW),
    ("git commit -qF- <<'EOF'\nfix: then git push --force\nEOF", ALLOW),
    ("git commit --file=- <<'EOF'\nfix: then git push --force\nEOF", ALLOW),
    ("gh-app issue create --title x -F- <<'EOF'\nRun git push --force.\nEOF", ALLOW),
    ("gh-app issue create --title x --body-file=- <<'EOF'\nRun git push --force.\nEOF", ALLOW),
    ("git commit -F-x <<'EOF'\ngit push --force\nEOF", DENY),
    ("git commit -F - <<'EOF' && git log -1\nfix\nEOF", ALLOW),
    ("cat <<'A' <<'B'\nx\nA\ny\nB", ALLOW),
    ("git commit -F - <<EOF\nfix: x\nEOF", NONE),
    ("cat <<'EOF' | sh\ngit status\nEOF", NONE),
    # Shell functions.
    ("gh() { devenv shell --quiet -- gh-app \"$@\"; }\ngh pr merge 55 --auto --squash", ASK),
    ("gh() { devenv shell --quiet -- gh-app \"$@\"; }; gh pr view 1", ASK),
    ("function gh { gh-app \"$@\"; }; gh pr merge 1", ASK),
    ("gh () { gh-app \"$@\"; }; gh pr merge 1", ASK),
    ("f() { git push --force; }; f", DENY),
    ("f() { cat .env; }; f", DENY),
    ("f() { :; }; gh pr merge 1", DENY),
    ("gh() { gh-app \"$@\"; }; gh pr merge 1; echo 'unclosed", ASK),
    ("gh() { :; }; command gh pr merge 1", DENY),
    ("gh() { :; }; find . -exec gh pr merge 1 \\;", DENY),
    # Sequences and pipelines.
    ("git status && git log -1", ALLOW),
    ("git worktree list; git branch -vv", ALLOW),
    ("git status\ngit log -1", ALLOW),
    ("git status || git log -1", ALLOW),
    ("git status;", ALLOW),
    ("git status &&\ngit log -1", ALLOW),
    ("ls -la && git status", ALLOW),
    ("git fetch origin && git log --oneline origin/main -3", ALLOW),
    ("git status && devenv shell --quiet -- scripts/check.sh", ALLOW),
    ("devenv shell --quiet -- gh-app issue view 36; devenv shell --quiet -- gh-app issue view 21", ALLOW),
    ("git status && rm -rf build", NONE),
    ("git status; git push -u origin feat", ASK),
    ("git status && devenv shell --quiet -- rm -rf build", ASK),
    ("git status && devenv shell -- cargo publish", DENY),
    ("git status && cat .env", DENY),
    ("git status && cat ~/.ssh/id_rsa", NONE),
    ("git branch -r | grep -v HEAD", ALLOW),
    ("git log --oneline | sort | uniq -c", ALLOW),
    ("git log | cut -d' ' -f1 | head", ALLOW),
    ("gh-app pr view 1 --json title | jq -r .title", ALLOW),
    ("git diff | gh-app issue create --title x --body-file -", ALLOW),
    ("git log | jq -n env", NONE),
    ("git log | jq '$ENV.GH_TOKEN'", NONE),
    ("git log | jq -f prog.jq", NONE),
    ("git log | jq -L lib 'import \"x\" as x; .'", NONE),
    ("git log | jq --rawfile x .dev.vars .", DENY),
    ("git log | sort -o out.txt", NONE),
    ("git log | sort -uoout.txt", NONE),
    ("git log | sort --compress-program=./evil", NONE),
    ("git log | uniq - out.txt", NONE),
    ("git log | grep -r x .", NONE),
    ("git log | python3", NONE),
    ("git log | sh", NONE),
    ("printf -v PATH /tmp/x; git status", NONE),
    ("set -o pipefail; devenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW),
    ("set -euo pipefail; git status", ALLOW),
    ("set -- a b; git status", NONE),
    ("set -o noclobber; git status", NONE),
    ("git status 2>&1 >/dev/null", ALLOW),
    ("git log &>/dev/null", ALLOW),
    ("git status && git log -1 | ;", NONE),
    ("git status &&", NONE),
    ("git status ;; git log", NONE),
    # The gate's status.
    ("scripts/check.sh | tail -40", DENY),
    ("git status && devenv shell --quiet -- scripts/check.sh 2>&1 | grep FAIL", DENY),
    ("./scripts/check.sh 2>&1 | tail", DENY),
    ("set -euo pipefail; scripts/check.sh 2>&1 | tail -40", ALLOW),
    ("set -o pipefail\ndevenv shell --quiet -- scripts/check.sh 2>&1 | tail -40", ALLOW),
    ("scripts/check.sh | tail; set -o pipefail", DENY),
    ("devenv shell --quiet -- scripts/check.sh > \"$TMPDIR/check.log\" 2>&1", ALLOW),
    ("devenv shell --quiet -- scripts/check.sh 2>&1", ALLOW),
    ("git log | grep check.sh", ALLOW),
    # Still not followed.
    ("git status & git log", NONE),
    ("git status |& grep x", NONE),
    ("(git status; git log)", NONE),
    ("{ git status; git log; }", NONE),
    ("! git status", NONE),
    ("if git status; then git log; fi", NONE),
    ("git status && git log $(git rev-parse HEAD)", NONE),
    ("git status && git log `git rev-parse HEAD`", NONE),
    ("git status && git log <(git diff)", NONE),
    ("git status && eval git log", NONE),
    ("git status && cd sub && git log", NONE),
    ("FOO=1 git status && git log", NONE),
    ("git status && git log -1 # note", NONE),
    ("git status && \\\ngit log", NONE),
    ("git status && git log $HOME", NONE),
    ("for i in 36 21; do devenv shell --quiet -- gh-app issue view $i; done", NONE),
    ("for b in a; do git status; done", NONE),
    ("for b in a; do git status; done && git log -1", NONE),
    ("while true; do git status; done", NONE),
    ("case x in x) git status;; esac", NONE),
    # Redirects.
    ("git log > \"$TMPDIR/log.txt\" 2>&1", ALLOW),
    ("git log >\"$TMPDIR/log.txt\"", ALLOW),
    ("git log 2>/dev/null | head -5", ALLOW),
    ("git log > $TMPDIR/x", ALLOW),
    ("git log >> ${TMPDIR}/x", ALLOW),
    ("git log > /private/tmp/claude-501/scratch/x", ALLOW),
    ("git log > \"$TMPDIR/../../../../../../../../etc/x\"", NONE),
    ("git log > \"$TMPDIR/x\" > out.txt", DENY),
    ("git log > ~/x", NONE),
    ("git log > \"$HOME/x\"", NONE),
    ("git log > \"$TMPDIRX/y\"", NONE),
    ("git log < README.md", NONE),
    ("git log <<< x", NONE),
    ("TMPDIR=. git log > \"$TMPDIR/x\"", NONE),
    ("git log >| \"$TMPDIR/x\"", NONE),
    ("gh-app issue create --title x --body-file \"$TMPDIR/body.md\"", ALLOW),
    ("git log>\"$TMPDIR/x\"", NONE),
    # Options that run a program, or wait for a user who isn't there.
    ("git fetch --upload-pack=evil origin", ASK),
    ("git fetch --upl=evil origin", ASK),
    ("git fetch --upload-pack evil origin", ASK),
    ("git fetch -u evil origin", ASK),
    ("git fetch -qu evil origin", ASK),
    ("git fetch --receive-pack=evil origin", ASK),
    ("git fetch --exec=evil origin", ASK),
    ("git fetch 'ext::sh -c evil' main", ASK),
    ("git -c core.sshCommand=evil fetch origin", ASK),
    ("git --config-env=core.sshCommand=X fetch origin", ASK),
    ("git fetch --update-head-ok origin", ASK),
    ("git rev-list --count HEAD", ALLOW),
    ("git rev-list --exec=evil HEAD", ASK),
    ("git branch --edit-description", ASK),
    ("git branch --edit-desc feat", ASK),
    ("git commit -e -m x", ASK),
    ("git commit --edit -m x", ASK),
    ("git commit -c HEAD", ASK),
    ("git commit --reedit-message=HEAD", ASK),
    ("git commit -p -m x", ASK),
    ("git commit --interactive", ASK),
    ("git commit --amend --no-edit", ALLOW),
    ("git add -p", ASK),
    ("git add -i", ASK),
    ("git add -e", ASK),
    ("git add --patch", ASK),
    ("gh-app issue create --title x --editor", ASK),
    ("gh-app issue create --title x --edit", ASK),
    ("gh-app issue create --title x -e", ASK),
    ("gh-app issue create --title x -we", ASK),
    ("git log | tail -f", NONE),
    ("tail -F log.txt", NONE),
    ("tail --follow=name log.txt", NONE),
    ("tail -n5 -f log.txt", NONE),
    ("git log | tail -40", ALLOW),
    ("git log | uniq -- -x y", NONE),
    ("git log | uniq -c", ALLOW),
    # sort and uniq take only listed options: any other may read a file
    # named indirectly.
    ("git log | sort --files0-from=list.txt", NONE),
    ("git log | sort --random-source=.env", DENY),
    ("git log | sort --random-source .env", DENY),
    ("git log | sort --random-source=seed", NONE),
    ("git log | sort --files0", NONE),
    ("git log | sort -R", NONE),
    ("git log | sort -m a b", NONE),
    ("git log | sort -nru", ALLOW),
    ("git log | sort -k2,2 -t: -n", ALLOW),
    ("git log | sort -k 2 -t , -rn", ALLOW),
    ("git log | sort --key=2 --field-separator=: --version-sort -s", ALLOW),
    ("git log | sort -hVzfb", ALLOW),
    ("sort -u -- notes.txt", ALLOW),
    ("git log | uniq -f 1 -c", ALLOW),
    ("git log | uniq --skip-fields=1 --all-repeated=separate", ALLOW),
    ("git log | uniq -cd", ALLOW),
    ("git log | uniq -x", NONE),
    ("git log | uniq --count=x", NONE),
    # grep -f reads its patterns from a file.
    ("git log | grep -f .env", DENY),
    ("git log | grep -f patterns.txt", NONE),
    ("git log | grep -if patterns.txt", NONE),
    ("git log | grep --file=patterns.txt", NONE),
    ("git log | grep --file patterns.txt", NONE),
    ("git log | grep --exclude-from=list x", NONE),
    ("git log | grep -F foo", ALLOW),
    # pipefail counts only where the calling shell is sure to set it first.
    ("true || set -o pipefail; scripts/check.sh | tail", DENY),
    ("echo | set -o pipefail; scripts/check.sh | tail", DENY),
    ("set -o pipefail | cat; scripts/check.sh | tail", DENY),
    ("devenv shell -- set -o pipefail; scripts/check.sh | tail", DENY),
    ("set -o pipefail; set +o pipefail; scripts/check.sh | tail", DENY),
    ("(set -o pipefail); scripts/check.sh | tail", DENY),
    ("set -o pipefail & scripts/check.sh | tail", DENY),
    ("if true; then set -o pipefail; fi; scripts/check.sh | tail", DENY),
    # The gate piped in a call the strict reader doesn't read.
    ("scripts/check.sh 2>&1 | tail -3 # gate", DENY),
    ("scripts/check.sh \"$@\" | tail", DENY),
    ("scripts/check.sh |& tail", DENY),
    ("echo $(scripts/check.sh | tail)", DENY),
    ("bash -c 'scripts/check.sh | tail'", DENY),
    ("{ scripts/check.sh; } | tail", DENY),
    ("(scripts/check.sh) | tail", DENY),
    ("for i in 1; do scripts/check.sh; done | tail", DENY),
    ("set -o pipefail; scripts/check.sh 2>&1 | tail -3 # gate", NONE),
    # Only a pipeline the gate, or a group or subshell holding it, is a
    # stage of counts.
    ("(git status; scripts/check.sh) | tail", DENY),
    ("(scripts/check.sh;) | tail", DENY),
    ("(scripts/check.sh\n) | tail", DENY),
    ("{ scripts/check.sh; echo a; } | tail", DENY),
    ("if true; then scripts/check.sh; fi | tail", DENY),
    ("( (scripts/check.sh) ) | tail", DENY),
    ("scripts/check.sh && { echo a; } | cat", NONE),
    ("{ git log -1; } | head -3\nscripts/check.sh > \"$TMPDIR/c.log\" 2>&1", NONE),
    ("git log | head -3; scripts/check.sh", ALLOW),
    ("(scripts/check.sh;) && echo ok", NONE),
    # An opener after a reserved word or another opener nests too.
    ("{ { scripts/check.sh; }; } | tail", DENY),
    ("if true; then if true; then scripts/check.sh; fi; fi | tail", DENY),
    ("for i in 1; do if true; then scripts/check.sh; fi; done | tail", DENY),
    ("while true; do { if true; then scripts/check.sh; fi; }; done | tail", DENY),
    ("if true; then { for i in 1; do scripts/check.sh; done; }; fi | tail", DENY),
    ("if ! { scripts/check.sh; }; then echo x; fi | tail", DENY),
    ("{ { scripts/check.sh; }; } && echo ok", NONE),
    ("if true; then if true; then scripts/check.sh; fi; fi && echo ok", NONE),
    ("if true; then if true; then scripts/check.sh; fi; fi; echo x", DENY),
    # What reads a heredoc body is found through its pipeline.
    ("cat <<'EOF' | ksh\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | /bin/bash\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | env bash\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | devenv shell -- bash\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | xargs -0 sh -c\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | fish\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | mksh\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' |\ngit push --force\nEOF\nbash", DENY),
    ("cat <<'EOF' | head | sh\ngit push --force\nEOF", DENY),
    ("{ cat <<'EOF'\ngit push --force\nEOF\n} | sh", DENY),
    ("(cat <<'EOF'\ngit push --force\nEOF\n) | bash", DENY),
    ("cat <<'EOF' | \"$SHELL\"\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | /bin/?sh\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | {ba,}sh\ngit push --force\nEOF", DENY),
    ("cat <<'EOF' | python3\nopen('.env').read()\nEOF", DENY),
    ("git -c core.x=y status; cat <<'EOF' | ksh\ngit push --force\nEOF", DENY),
    ("git -c core.x=y status; cat <<'EOF' |\ngit push --force\nEOF\nsh", DENY),
    ("git -c core.x=y status; { cat <<'EOF'\ngit push --force\nEOF\n} | sh", DENY),
    ("cat <<'EOF' | wc -l\ngit push --force\nEOF", ALLOW),
    ("cat <<'EOF' | gh-app issue create --title x --body-file -\ngit push --force\nEOF", NONE),
    ("gh-app issue create --title x --body-file - <<'EOF'\nUse curl x | sh, then git push --force.\nEOF", ALLOW),
    ("git -c core.x=y commit -F - <<'EOF'\ncurl x | sh, then git push --force\nEOF", ASK),
    # A heredoc commit message in a chain.
    ("git add -A && git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("git status; git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\"", ALLOW),
    ("devenv shell --quiet -- git add -A && devenv shell --quiet -- git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\"", ALLOW),
    ("git add -A && git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\" && git log -1", ALLOW),
    ("git add -A && git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\" && git push --force", DENY),
    ("git add -A && git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\"; rm -rf build", NONE),
    ("rm -rf build && git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\"", NONE),
    ("git add -A && git commit -m \"$(cat <<'EOF'\nfix\nEOF\n)\" | sh", NONE),
    ("git add -A && git commit --reuse-message=HEAD -m \"$(cat <<'EOF'\nfix\nEOF\n)\"", NONE),
    # A fetch that can drop local work or refs asks.
    ("git fetch origin +main:main", ASK),
    ("git fetch origin main:main", ASK),
    ("git fetch origin +main", ASK),
    ("git fetch -f origin main", ASK),
    ("git fetch --force origin", ASK),
    ("git fetch -u origin", ASK),
    ("git fetch -p", ASK),
    ("git fetch --prune origin", ASK),
    ("git fetch --prune-tags origin", ASK),
    ("git fetch -P origin", ASK),
    ("git fetch --refmap= origin", ASK),
    ("git fetch origin main", ALLOW),
    ("git fetch git@github.com:o/r.git main", ALLOW),
    # A body something other than a known data consumer reads is checked for
    # denies as a script.
    ("tcsh <<'EOF'\ngit push -f\nEOF", DENY),
    ("csh <<'EOF'\ngit push -f\nEOF", DENY),
    ("pwsh <<'EOF'\ngit push -f\nEOF", DENY),
    ("nu <<'EOF'\ngit push -f\nEOF", DENY),
    ("php <<'EOF'\n<?php system('git push -f');\nEOF", DENY),
    ("lua <<'EOF'\nos.execute('git push -f')\nEOF", DENY),
    ("awk -f - <<'EOF'\nBEGIN { system(\"git push -f\") }\nEOF", DENY),
    ("osascript <<'EOF'\ndo shell script \"git push -f\"\nEOF", DENY),
    ("ssh host <<'EOF'\ngit push -f\nEOF", DENY),
    ("sqlite3 db <<'EOF'\n.shell git push -f\nEOF", DENY),
    ("ssh host <<'EOF'\necho x > README.md\nEOF", DENY),
    ("cat <<'EOF' | tcsh\ngit push -f\nEOF", DENY),
    ("git commit -F - <<'EOF'\nfix: then git push -f\nEOF", ALLOW),
    ("cat <<'EOF'\ngit push -f\nEOF", ALLOW),
    # Here-strings are bodies too.
    ("bash <<< 'git push -f'", DENY),
    ("git status && sh <<<'git reset --hard'", DENY),
    ("cat <<<'git push -f' | sh", DENY),
    ("tcsh <<< 'git push -f'", DENY),
    ("cat <<< 'git push -f'", NONE),
    # The same in a call only the rough reading reads.
    ("tcsh <<'EOF'\ngit push -f\nEOF\necho 'unclosed", DENY),
    ("ssh host <<'EOF'\ngit push -f\nEOF\necho 'unclosed", DENY),
    ("cat <<'EOF'\ngit push -f\nEOF\necho 'unclosed", ASK),
    ("git commit -F - <<'EOF'\ngit push -f\nEOF\necho 'unclosed", ASK),
    ("sh <<<'git push -f'; echo 'unclosed", DENY),
    ("tee \"$TMPDIR/b.md\" <<'EOF'\nNever run git push --force\nEOF\necho 'unclosed", ASK),
    ("tee ${TMPDIR}/b.md <<'EOF'\nNever run git push --force\nEOF\necho 'unclosed", ASK),
    ("tee /etc/b.md <<'EOF'\ngit push --force\nEOF\necho 'unclosed", DENY),
    # Only `&& ...` may follow the gate.
    ("scripts/check.sh || true", DENY),
    ("scripts/check.sh; echo done", DENY),
    ("scripts/check.sh\necho x", DENY),
    ("scripts/check.sh & wait", DENY),
    ("scripts/check.sh && git status; echo x", DENY),
    ("devenv shell --quiet -- scripts/check.sh || true", DENY),
    ("scripts/check.sh && git status", ALLOW),
    ("git status; scripts/check.sh", ALLOW),
    ("bash scripts/check.sh | tail", DENY),
    ("sh scripts/check.sh | tail", DENY),
    ("devenv shell -- sh scripts/check.sh | tail", DENY),
    ("bash -x scripts/check.sh | tail", DENY),
    # What follows a subshell's `)` follows the gate inside it, and a
    # substitution's status is never the call's.
    ("(scripts/check.sh) || echo failed", DENY),
    ("(scripts/check.sh); echo done", DENY),
    ("(scripts/check.sh)\necho done", DENY),
    ("((scripts/check.sh)) || true", DENY),
    ("(git status; scripts/check.sh) & wait", DENY),
    ("x=$(scripts/check.sh); echo done", DENY),
    ("x=$(scripts/check.sh)", DENY),
    ("echo \"$(scripts/check.sh)\"", DENY),
    ("echo `scripts/check.sh`", DENY),
    ("cat <(scripts/check.sh)", DENY),
    ("(scripts/check.sh) && git status", NONE),
    ("(scripts/check.sh)", NONE),
    ("x=$(git status); scripts/check.sh", NONE),
    # Operators inside a compound command `&&` leads to, or inside the
    # gate's own group before it closes, don't count.
    ("scripts/check.sh && { echo a; echo b; }", NONE),
    ("{ scripts/check.sh; } && echo ok", NONE),
    ("scripts/check.sh && if git diff --quiet; then echo clean; fi", NONE),
    ("{ git status; scripts/check.sh; }", NONE),
    ("{ scripts/check.sh; }; echo x", DENY),
    ("scripts/check.sh && { echo a; }; echo x", DENY),
    ("scripts/check.sh || { echo a; }", DENY),
    ("{ scripts/check.sh; echo a; } && echo ok", DENY),
    ("if true; then scripts/check.sh; fi; echo x", DENY),
    # A trailing `&` at the gate's level backgrounds it: the status is 0.
    ("scripts/check.sh &", DENY),
    ("scripts/check.sh && git status &", DENY),
    ("{ scripts/check.sh; } &", DENY),
    ("(scripts/check.sh) &", DENY),
    ("scripts/check.sh && { git status & }", NONE),
    # A `&` ending the gate backgrounds it at any depth, whatever follows
    # the subshell.
    ("(scripts/check.sh &) && echo started", DENY),
    ("{ ( scripts/check.sh & ); }", DENY),
    ("echo x |& ( scripts/check.sh & );", DENY),
    ("(scripts/check.sh &)", DENY),
    ("{ scripts/check.sh & } && echo ok", DENY),
    ("(scripts/check.sh;) && echo ok", NONE),
    # Editors gh and git open for a message they aren't given.
    ("gh-app issue create --title x", ASK),
    ("gh-app issue create --title x --body-file=-", ALLOW),
    ("git commit", ASK),
    ("git commit --amend", ASK),
    ("git commit -a", ASK),
    ("git commit --fixup=reword:HEAD", ASK),
    ("git commit --fixup=amend:HEAD", ASK),
    ("git commit --fixup amend:HEAD", ASK),
    ("git commit --fixup=HEAD", ALLOW),
    ("git commit -am x", ALLOW),
    ("git commit -C HEAD", ALLOW),
    # -o is refused except where it is known to name no file or program.
    ("git log | grep -o foo", ALLOW),
    ("git log | grep -c -o foo", ALLOW),
    ("git log | grep -co foo", ALLOW),
    ("wc -o x", ASK),
    ("cargo test -o x", ASK),
    # git's short options take their value in the word: only `-o...` is -o.
    ("git status -uno", ALLOW),
    ("git log -Sfoo", ALLOW),
    ("git log -Gfoo", ALLOW),
    ("git commit -mdocs:x", ALLOW),
    ("git status -o", ASK),
    ("git commit -Smykey", ASK),
    ("git commit -qmc", ALLOW),
    ("git commit -mc -e", ASK),
    # A message, title or body is text, whatever it starts with.
    ("git commit -m \"-o is refused\"", ALLOW),
    ("git commit -m \"-e\"", ALLOW),
    ("git commit --message -e", ALLOW),
    ("git commit -m -m -e", ASK),
    ("git commit -m x -o", ASK),
    ("git fetch \"--upload-pack=a b\" origin", ASK),
    # Only where the option takes text: `git fetch -t` is `--tags`. A word
    # that names a program for git to run is checked even as text.
    ("git fetch -t --upload-pack=x origin", ASK),
    ("git fetch -m --upload-pack=x origin", ASK),
    ("git push -t --receive-pack=x origin", ASK),
    ("git commit -m --upload-pack=x", ASK),
    ("git commit -m -cfoo", ASK),
    ("git tag -m \"-o x\" v1", NONE),
    ("git log -m -o x", ASK),
    # An empty word is kept, as the shell keeps it.
    ("git status; echo \"\"; git log -1", ALLOW),
    ("echo ''", ALLOW),
    ("git commit -m ''", ALLOW),
    ("grep -n '' f", ALLOW),
    ("git push --force ''", DENY),
    ("git fetch -j4 origin", ALLOW),
    ("git fetch -qf origin", ASK),
    # A revision's `~` is plain; `^`, a `~` opening a word, or one in
    # anything but a revision isn't.
    ("git log HEAD~3..HEAD", ALLOW),
    ("git log origin/main~2...feat~", ALLOW),
    ("git diff HEAD^", NONE),
    ("git diff ~/x", ASK),
    ("git diff a~b", NONE),
    ("git diff 'HEAD^'", ALLOW),
    # A quoted `~` is just a character.
    ("devenv shell --quiet -- gh-app issue create --title \"Handle ~ in paths\" --body \"x\"", ALLOW),
    ("git commit -m \"use ~/.cache\"", ALLOW),
    ("git log --grep='a~b'", ALLOW),
    ("git diff HEAD~1 -- 'src/a~b.rs'", ALLOW),
    ("echo 'a~b'", ALLOW),
    # As on main: the word `~` alone is a path outside the project.
    ("echo '~'", NONE),
    ("git diff 'a'~b", NONE),
    # A fetch option's value in the next word isn't a refspec; a refspec
    # after it still is, and an abbreviation's next word stays an operand.
    ("git fetch origin --filter blob:none", ALLOW),
    ("git fetch origin --server-option foo:bar", ALLOW),
    ("git fetch origin --shallow-since 2026-01-01 --jobs 4 main", ALLOW),
    ("git fetch origin --depth 1 main:x", ASK),
    ("git fetch origin --filt blob:none", ASK),
    # git takes any unique prefix of a long option, and fails on an
    # ambiguous one: every prefix of a refused option is refused.
    ("git fetch --fo origin", ASK),
    ("git fetch --f origin", ASK),
    ("git fetch --forc origin", ASK),
    ("git fetch --up origin", ASK),
    ("git fetch --pru origin", ASK),
    ("git fetch --prune-t origin", ASK),
    ("git fetch --refm=x origin", ASK),
    ("git fetch --upl=evil origin", ASK),
    ("git fetch --progress origin", ALLOW),
    ("git fetch --tags origin", ALLOW),
    ("git push --fo", DENY),
    ("git push --m origin", DENY),
    ("git reset --h", DENY),
    ("git reset --ha HEAD~1", DENY),
    ("git commit --e -m x", ASK),
    ("git commit --ree=HEAD", ASK),
    ("git commit --pa -m x", ASK),
    ("git add --pa", ASK),
    ("git add --inter", ASK),
    ("git branch --ed", ASK),
    ("tail --r log.txt", NONE),
    # A tee whose every target is scratch takes its body as data.
    ("tee \"$TMPDIR/b.md\" <<'EOF'\nNever run git push --force\nEOF", NONE),
    ("tee -a \"$TMPDIR/b.md\" \"$TMPDIR/c.md\" <<'EOF'\nNever run git push --force\nEOF", NONE),
    ("tee \"$TMPDIR/b.md\" <<< 'never git push --force'", NONE),
    ("tee /etc/b.md <<'EOF'\ngit push --force\nEOF", DENY),
    ("tee --weird \"$TMPDIR/b.md\" <<'EOF'\ngit push --force\nEOF", DENY),
    ("tee \"$TMPDIR/b.md\" <<'EOF' | sh\ngit push --force\nEOF", DENY),
    ("tee notes.md <<'EOF'\nprose\nEOF", DENY),
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
    # A rule written with the wrapper, for any command of a chain, in both
    # spellings.
    ({"allow": ["git status *", "devenv shell *", "gh-app issue create *"],
      "ask": ["devenv shell --quiet -- gh-app issue create *"]},
     "git status && devenv shell --quiet -- gh-app issue create --title x --body y", ASK),
    ({"allow": ["git status *", "devenv shell *", "gh-app issue create *"],
      "ask": ["devenv shell --quiet -- gh-app issue create *"]},
     "git status && gh-app issue create --title x --body y", ASK),
    ({"allow": ["git status *", "devenv shell *"],
      "deny": ["devenv shell --quiet -- cargo publish *"]},
     "git status && devenv shell -- cargo publish", DENY),
    ({"allow": ["git status *", "devenv shell --quiet -- cargo test *"]},
     "git status && devenv shell --quiet -- cargo test", ALLOW),
    ({"allow": ["git status *", "devenv shell --quiet -- cargo test *"]},
     "git status && cargo test", NONE),
    ({"allow": ["git status *", "devenv shell *"]},
     "git status && devenv shell --quiet -- rm -rf x", ASK),
    # gh opens an editor for a body it isn't given.
    ({"allow": ["gh-app pr create *"]}, "gh-app pr create --title x", ASK),
    ({"allow": ["gh-app pr create *"]}, "gh-app pr create --fill", ALLOW),
    ({"allow": ["gh-app pr create *"]}, "gh-app pr create --title x -b y", ALLOW),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 1 --edit-last", ASK),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 1 --edit-last --body x", ASK),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 1", ASK),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 1 --body x", ALLOW),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 3 --body \"-e is nice\"", ALLOW),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 3 -b -e", ALLOW),
    ({"allow": ["gh-app issue comment *"]}, "gh-app issue comment 3 --body x -e", ASK),
    ({"allow": ["gh-app pr checks *"]}, "gh-app pr checks -t -e", ASK),
    ({"allow": ["gh-app pr create *"]}, "gh-app pr create -t \"-e x\" -b y", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -m \"-o x\" v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag --message -o v1", ASK),
    # stash's -m is a message only for push, save or a bare stash, and
    # notes' only for add and append; list and show take log options, where
    # -m takes no value.
    ({"allow": ["git stash *"]}, "git stash list -m --output=x", ASK),
    ({"allow": ["git stash *"]}, "git stash show -m -o x", ASK),
    ({"allow": ["git notes *"]}, "git notes show -m --output=x", ASK),
    ({"allow": ["git notes *"]}, "git notes list -m -o x", ASK),
    ({"allow": ["git stash *"]}, "git stash push -m \"-o x\"", ALLOW),
    ({"allow": ["git stash *"]}, "git stash save -m \"-o x\"", ALLOW),
    ({"allow": ["git stash *"]}, "git stash -m \"-o x\"", ALLOW),
    ({"allow": ["git notes *"]}, "git notes add -m \"-o x\" HEAD", ALLOW),
    ({"allow": ["git notes *"]}, "git notes append -m \"-o x\" HEAD", ALLOW),
    # A word that could name an output file is checked even as text, unless
    # it holds whitespace as a sentence does.
    ({"allow": ["git stash *"]}, "git stash push -m -ox", ASK),
    ({"allow": ["git stash *"]}, "git stash push -m --output=x", ASK),
    ({"allow": ["git commit *"]}, "git commit -m -ofoo", ASK),
    ({"allow": ["git commit *"]}, "git commit -m \"-o is refused\"", ALLOW),
    # A tag opens an editor with -e, or when annotated or signed without -m
    # or -F, as a commit does.
    ({"allow": ["git tag *"]}, "git tag v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -l", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -d v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -e -m x v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --edit -m x v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --ed -m x v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -ae -m x v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --message -e v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -m -e v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -a v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -s v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -ukey v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -u key v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --annotate v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --sign v1", ASK),
    ({"allow": ["git tag *"]}, "git tag --local-user=key v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -f -a v1", ASK),
    ({"allow": ["git tag *"]}, "git tag -a -m x v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -am x v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -s --message=x v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -a -F notes.md v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -a --file=notes.md v1", ALLOW),
    ({"allow": ["git tag *"]}, "git tag -ma v1", ALLOW),
    # -o is refused by default: ssh's options run programs, unzip's
    # overwrites, 7z's names an output directory.
    ({"allow": ["ssh *"]}, "ssh -o ProxyCommand=sh host", ASK),
    ({"allow": ["ssh *"]}, "ssh -oProxyCommand=sh host", ASK),
    ({"allow": ["unzip *"]}, "unzip -o a.zip", ASK),
    ({"allow": ["unzip *"]}, "unzip -qo a.zip", ASK),
    ({"allow": ["unzip *"]}, "unzip -l a.zip", ALLOW),
    ({"allow": ["7z *"]}, "7z x -oout a.7z", ASK),
    ({"allow": ["7z *"]}, "7z l a.7z", ALLOW),
    # Elsewhere an `o` later in the word is another flag or a single-dash
    # long option; a word starting `-o` is still refused.
    ({"allow": ["ls *"]}, "ls -lo", ALLOW),
    ({"allow": ["wc *"]}, "wc -lo README.md", ALLOW),
    ({"allow": ["go test *"]}, "go test -count=1 -timeout 30s ./...", ALLOW),
    ({"allow": ["go build *"]}, "go build -o out .", ASK),
    ({"allow": ["ls *"]}, "ls -o", ASK),
    ({"allow": ["ssh *"]}, "ssh -4oProxyCommand=sh h", ASK),
    ({"allow": ["curl *"]}, "curl -sLo x https://example.com", ASK),
    ({"allow": ["sort *"]}, "sort -ro out.txt in.txt", ASK),
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
        (os.path.join(root, "sub"), "scripts/check.sh | tail", "deny"),
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
        # The project's parent here is the temp directory: scratch.
        (f"echo x > {os.path.dirname(root)}/elsewhere.txt", "allow"),
        (f"echo x > {root}/src/a.rs 2>&1", "deny"),
        (f"git log > {root}/../elsewhere.txt", None),
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
    # Linked worktrees of the project in neither place they are made.
    away = os.path.join(top, "elsewhere", "wt")
    linked(root, away, "away")
    under_sub = os.path.join(root, "sub", "wt")
    linked(root, under_sub, "us")
    # A worktree whose `.git` file and back-pointer are relative (git's
    # worktree.useRelativePaths), and one without a commondir.
    rel = os.path.join(top, "proj.worktrees", "rel")
    linked(root, rel, "rel")
    rel_gitdir = os.path.join(root, ".git", "worktrees", "rel")
    with open(os.path.join(rel, ".git"), "w") as f:
        f.write(f"gitdir: {os.path.relpath(rel_gitdir, rel)}\n")
    with open(os.path.join(rel_gitdir, "gitdir"), "w") as f:
        f.write(os.path.relpath(os.path.join(rel, ".git"), rel_gitdir) + "\n")
    nocd = os.path.join(top, "proj.worktrees", "nocd")
    linked(root, nocd, "nocd")
    os.remove(os.path.join(root, ".git", "worktrees", "nocd", "commondir"))
    policy ={**POLICY, "allow": POLICY["allow"] + ["git switch *"], "ask": POLICY["ask"] + ["git switch -f *"]}
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
            (away, "git status", "ask"),
            (under_sub, "git status", None),
            (rel, "git status", "allow"),
            (nocd, "git status", "ask"),
            (sib, f"git -C {sib} status", "allow"),
            # Another checkout's top: git would read `packages/a.py` from
            # there, the guard from the cwd.
            (root, f"git -C {sib} log --oneline", None),
            (sib, f"git -C {root} status", None),
            (root, f"git -C {nested} status", None),
            (root, f"git -C {sib} add packages/a.py", None),
            (sib, "git -C . status", "allow"),
            (sib, "git -C ../x status", "allow"),
            (sib, "git -C packages status", None),
            (sib, "git -C ../rel status", None),
            (sib, "git -C . -C . status", None),
            (sib, f"git -C {sib} -C packages status", None),
            (sib, "git -C . -C . push --force", "deny"),
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
