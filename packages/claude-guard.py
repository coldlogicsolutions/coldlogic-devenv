"""A Claude Code PreToolUse hook: decides a tool call from what it would run.

Permission rules match a command's text, so a wrapper (`devenv shell --
...`), a global option (`git -C . push -f`) or `bash -c` gets past them. This
unwraps each command first, then:

- denies the commands no session may run, however they are spelled;
- denies reading or writing a secrets file, from a file tool or a command
  that names one;
- allows a command when every part of it, unwrapped, matches the session's
  Bash allow rules and none matches its deny rules;
- otherwise leaves the call to Claude Code's own rules, which prompt.

It is a backstop, not a boundary: a script can still do anything the sandbox
lets it. Anything it can't follow gets no allow. The policy file holds the
session's Bash allow and deny rules, as `{"allow": [...], "deny": [...]}`.
"""

import fnmatch
import json
import os
import re
import shlex
import sys

SHELLS = {"bash", "sh", "zsh", "dash"}
# Interpreters whose script this can't read.
INTERPRETERS = {"python", "python3", "node", "perl", "ruby", "deno", "bun"}
NO_ARG_WRAPPERS = {"command", "exec", "nohup", "time", "builtin"}

# Option flags of `devenv` and `devenv shell` that a command may come after.
DEVENV_FLAGS = {"-q", "--quiet", "-v", "--verbose", "--impure", "--offline",
                "--refresh-eval-cache", "--no-eval-cache"}
DEVENV_VALUE_FLAGS = {"-P", "--profile", "--log-format"}

# git's global options, and those that take a value.
GIT_FLAGS = {"--no-pager", "-p", "--paginate", "--bare", "--no-replace-objects",
             "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
             "--icase-pathspecs", "--no-optional-locks", "--no-advice"}
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                   "--exec-path", "--config-env", "--super-prefix",
                   "--attr-source", "--list-cmds"}

# Commands that only read what they're given, allowed anywhere in a
# pipeline without a rule, as long as every argument stays in the project
# (see read_only).
READ_ONLY = {"cd", "pwd", "ls", "cat", "head", "tail", "grep", "wc", "sort",
             "uniq", "cut", "tr", "jq", "echo", "printf", "true", "column",
             "basename", "dirname"}

OPERATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", ";;"}
REDIRECTS = re.compile(r"^\d*(>>?|<|<<<?|>&|<&|&>>?)$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# A word the shell would expand: what it names can't be known here.
EXPANDS = re.compile(r"[$`*?\[\]{}]|^~")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

SUBSTITUTED = "SUBSTITUTED"

SECRET_NAMES = (".env", ".dev.vars")
# Names a glob is tested against, to catch `cat .e*`.
SECRET_EXAMPLES = (".env", ".env.local", ".env.production", ".dev.vars")


class Unparsable(Exception):
    pass


def split_commands(text):
    """Split shell text into simple commands, each a list of words.

    Command substitutions, and heredocs fed to a shell, are split out as
    commands of their own. Anything this can't follow raises Unparsable.
    """
    text, scripts = take_heredocs(text)
    # Duplicating a descriptor, or discarding output, writes no file.
    text = re.sub(r"\d*>&\d+|&?\d*>\s*/dev/null", " ", text)
    commands = []
    inners, text = substitutions(text)
    for inner in scripts + inners:
        commands.extend(split_commands(inner))
    # A newline separates commands as `;` does. Inside quotes this changes
    # only the words being looked at, not what runs.
    text = text.replace("\\\n", " ").replace("\n", " ; ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    words = []
    try:
        for token in lexer:
            if token in OPERATORS:
                if words:
                    commands.append(words)
                words = []
            else:
                words.append(token)
    except ValueError as e:
        raise Unparsable(str(e))
    if words:
        commands.append(words)
    return [strip_redirects(c) for c in commands if c]


def take_heredocs(text):
    """(text without heredoc bodies, bodies a shell will run).

    A heredoc's body is data unless a shell reads it, as in `bash <<EOF` or
    `cat <<EOF | sh`. An interpreter reading one can't be followed.
    """
    out, scripts = [], []
    delimiter, body, is_script = None, [], False
    for line in text.split("\n"):
        if delimiter is not None:
            if line.strip() == delimiter:
                if is_script:
                    scripts.append("\n".join(body))
                delimiter, body = None, []
            else:
                body.append(line)
            continue
        m = HEREDOC.search(line)
        if m:
            words = re.findall(r"[A-Za-z0-9_.-]+", line)
            if INTERPRETERS & set(words):
                raise Unparsable("a heredoc fed to an interpreter")
            delimiter, is_script = m.group(2), bool(SHELLS & set(words))
            line = line[:m.start()] + line[m.end():]
        out.append(line)
    if delimiter is not None:
        raise Unparsable("unterminated heredoc")
    return "\n".join(out), scripts


def substitutions(text):
    """(the bodies of $(...) and `...` in text, text with each replaced by a
    placeholder). The bodies are checked as commands of their own, so the
    word holding one needn't count as an expansion."""
    found, out = [], []
    i = 0
    while i < len(text):
        if text.startswith("$(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            if depth:
                raise Unparsable("unclosed $(")
            found.append(text[i + 2:j - 1])
            out.append(SUBSTITUTED)
            i = j
        elif text[i] == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            found.append(text[i + 1:j])
            out.append(SUBSTITUTED)
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return found, "".join(out)


def strip_redirects(words):
    """Words with each redirection folded into one `>target` word."""
    out, i = [], 0
    while i < len(words):
        if REDIRECTS.match(words[i]):
            out.append(">" + (words[i + 1] if i + 1 < len(words) else ""))
            i += 2
        else:
            out.append(words[i])
            i += 1
    return out


class Unwrapped:
    """The commands a simple command runs, with wrappers removed."""

    def __init__(self):
        self.commands = []
        # Something was removed: a rule allowing the whole text shouldn't
        # stand for what's inside.
        self.wrapped = False
        # An environment variable is set, which can change what any command
        # does (PATH, GIT_SSH_COMMAND, LD_PRELOAD...): nothing is allowed.
        self.environment = False

    def add(self, other):
        self.commands.extend(other.commands)
        self.wrapped |= other.wrapped
        self.environment |= other.environment


def unwrap(words):
    result = Unwrapped()
    while words:
        head = os.path.basename(words[0])
        if ASSIGNMENT.match(words[0]):
            words, result.wrapped, result.environment = words[1:], True, True
        elif head == "env":
            i = 1
            while i < len(words) and (words[i].startswith("-") or ASSIGNMENT.match(words[i])):
                i += 1
            words, result.wrapped, result.environment = words[i:], True, True
        elif head in NO_ARG_WRAPPERS:
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 1
            words, result.wrapped = words[i:], True
        elif head == "nice":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] == "-n" else 1
            words, result.wrapped = words[i:], True
        elif head == "timeout":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-s", "-k", "--signal", "--kill-after") else 1
            words, result.wrapped = words[i + 1:], True
        elif head in SHELLS or head == "eval":
            script = " ".join(words[1:]) if head == "eval" else shell_script(words)
            if script is None:
                break
            result.wrapped = True
            for c in split_commands(script):
                result.add(unwrap(c))
            return result
        elif head == "devenv":
            inner = devenv_command(words)
            if inner is None:
                break
            words, result.wrapped = inner, True
        elif head in ("npx", "bunx", "pnpx"):
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-p", "--package") else 1
            words, result.wrapped = words[i:], True
        elif head in ("pnpm", "yarn", "npm") and len(words) > 1 and words[1] in ("exec", "dlx", "x"):
            i = 2
            while i < len(words) and words[i].startswith("-"):
                i += 1
            words, result.wrapped = words[i:], True
        else:
            break
    if words:
        result.commands.append(normalize_git(words))
    return result


def shell_script(words):
    """The script a shell runs with -c, or None if it runs a file or stdin."""
    for i, w in enumerate(words[1:], 1):
        if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", w):
            return words[i + 1] if i + 1 < len(words) else ""
        if not w.startswith("-"):
            return None
    return None


def devenv_command(words):
    """The command `devenv [flags] shell [flags] [--] command` runs, or None
    if this is another devenv subcommand or an interactive shell."""
    i = 1
    seen_shell = False
    while i < len(words):
        w = words[i]
        if w == "--":
            return words[i + 1:] if seen_shell and i + 1 < len(words) else None
        if w in DEVENV_FLAGS:
            i += 1
        elif w in DEVENV_VALUE_FLAGS:
            i += 2
        elif w.startswith("-"):
            # An option this doesn't know may take a value: don't guess.
            raise Unparsable(f"devenv option {w}")
        elif not seen_shell and w == "shell":
            seen_shell = True
            i += 1
        else:
            return words[i:] if seen_shell else None
    return None


def normalize_git(words):
    """git with its global options removed."""
    if os.path.basename(words[0]) != "git":
        return words
    i = 1
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        name, _, inline = w.partition("=")
        if name in GIT_VALUE_FLAGS:
            value = inline if inline else (words[i + 1] if i + 1 < len(words) else "")
            if name in ("-c", "--config-env") and re.match(r"(?i)^(alias\.|core\.)", value):
                # An alias or core setting can make any subcommand anything.
                raise Unparsable(f"git {name} {value}")
            i += 1 if inline else 2
        elif w in GIT_FLAGS:
            i += 1
        else:
            # An unknown global option: keep it, so nothing below mistakes
            # it for a subcommand.
            return words
    return ["git"] + words[i:]


def long_option(arg, option, shortest):
    """Whether arg is option or an abbreviation git would accept for it."""
    name = arg.split("=", 1)[0]
    return len(name) >= shortest and option.startswith(name)


def forbidden(words):
    """Why no session may run this command, or None."""
    head = os.path.basename(words[0])
    args = words[1:]
    if head == "git" and args:
        sub, rest = args[0], args[1:]
        if sub == "push":
            for a in rest:
                if a.startswith("--force") or long_option(a, "--force", 4):
                    return "force push"
                if long_option(a, "--mirror", 4):
                    return "push --mirror"
                if re.match(r"^-[A-Za-z0-9]*f[A-Za-z0-9]*$", a):
                    return "force push"
                if a.startswith("+") or ":+" in a:
                    return "force push (+refspec)"
        if sub == "reset" and any(long_option(a, "--hard", 4) for a in rest):
            return "git reset --hard"
    if head == "wrangler" and args:
        if args[0] in ("deploy", "publish", "rollback"):
            return "wrangler " + args[0]
        if args[0] == "versions" and len(args) > 1 and args[1] == "deploy":
            return "wrangler versions deploy"
    if head == "nix" and args[:1] == ["develop"]:
        return "nix develop: tools come from the devenv shell"
    if head == "nix-shell":
        return "nix-shell: tools come from the devenv shell"
    if head == "gh":
        # The user's own credentials: merging skips the review the
        # organization ruleset requires, and approving counts as that review.
        # The App's (gh-app) don't.
        if args[:2] == ["pr", "merge"]:
            return "gh pr merge with your credentials skips review; the App merges approved PRs"
        if args[:2] == ["pr", "review"] and any(a in ("-a", "--approve") for a in args):
            return "approving with your credentials stands in for your review"
        if args[:1] == ["alias"]:
            return "gh aliases could hide a merge or an approval"
        if args[:1] == ["api"]:
            text = " ".join(args).lower()
            if "merge" in text or "approve" in text or "/reviews" in text:
                return "merging or reviewing through gh api with your credentials"
            if "--input" in args or any(a.startswith("--input=") for a in args):
                raise Unparsable("gh api --input")
    return None


def secret_path(word):
    """Whether a word names, or could expand to, a secrets file."""
    path = word.lstrip(">")
    if not path:
        return False
    name = os.path.basename(path.rstrip("/"))
    for secret in SECRET_NAMES:
        if name == secret or (name.startswith(secret + ".") and name != secret + ".example"):
            return True
    if EXPANDS.search(name) and any(fnmatch.fnmatchcase(s, name) for s in SECRET_EXAMPLES):
        return True
    parts = path.replace("\\", "/").split("/")
    return "secrets" in parts[:-1] or name == "secrets"


def rule_regex(rule):
    """A Bash permission rule as a regex. `*` matches anything but a
    newline; a trailing ` *` is optional when it's the rule's only wildcard."""
    if rule.count("*") == 1 and rule.endswith(" *"):
        return re.compile(re.escape(rule[:-2]) + r"( [^\n]*)?\Z")
    return re.compile("[^\n]*".join(re.escape(p) for p in rule.split("*")) + r"\Z")


def matches(rules, words):
    text = " ".join(words)
    return any(r.match(text) for r in rules)


def read_only(words):
    """Whether this is a READ_ONLY command reading only inside the project."""
    if words[0] not in READ_ONLY:
        return False
    for a in words[1:]:
        if a.startswith("/") or a.startswith("~") or ".." in a.split("/"):
            return False
    head = words[0]
    if head == "sort" and any(a.startswith("-o") or a.startswith("--output") for a in words[1:]):
        return False
    if head == "grep" and any(re.match(r"^-[A-Za-z]*[rRd]", a) or a.startswith("--recursive")
                              or a.startswith("--dereference-recursive") or a.startswith("--directories")
                              for a in words[1:]):
        return False
    return True


def allowed(rules, words):
    if any(w.startswith(">") for w in words):
        return False
    if any(EXPANDS.search(w) for w in words):
        return False
    return read_only(words) or matches(rules, words)


def decide(tool, tool_input, policy):
    """(decision, reason), or None to leave the call to Claude Code."""
    if tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if secret_path(path):
            return "deny", f"{path} is a secrets file. Change .env.example instead, and say what the real file needs."
        return None
    if tool in ("Grep", "Glob"):
        path = tool_input.get("path") or ""
        if secret_path(path):
            return "deny", f"{path} is a secrets file."
        return None
    if tool != "Bash":
        return None

    command = tool_input.get("command", "")
    try:
        result = Unwrapped()
        for words in split_commands(command):
            result.add(unwrap(words))
        for words in result.commands:
            reason = forbidden(words)
            if reason:
                return "deny", f"Not allowed in a session: {reason}."
            for w in words[1:]:
                if secret_path(w):
                    return "deny", f"{w.lstrip('>')} is a secrets file. Change .env.example instead, and say what the real file needs."
    except Unparsable as e:
        # A command this can't follow gets no automatic allow, and a user
        # decides it.
        return "ask", f"coldlogic guard can't follow this command ({e})."

    deny = [rule_regex(r) for r in policy.get("deny", [])]
    for words in result.commands:
        if matches(deny, words):
            return "deny", f"Denied by this project's rules: {' '.join(words)}"

    allow = [rule_regex(r) for r in policy.get("allow", [])]
    if (result.commands and not result.environment
            and all(allowed(allow, w) for w in result.commands)):
        return "allow", "coldlogic guard: every command matches an allow rule."
    if result.wrapped and matches(allow, command.split()):
        # A rule allowing the wrapper itself would let anything through it.
        return "ask", "coldlogic guard: a rule allows the wrapper, not the command inside it."
    return None


def main():
    policy = {}
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            policy = json.load(f)
    try:
        event = json.load(sys.stdin)
        result = decide(event.get("tool_name", ""), event.get("tool_input") or {}, policy)
    except Exception as e:  # noqa: BLE001 — a broken hook must not allow.
        result = ("ask", f"coldlogic guard failed: {e}")
    if result:
        decision, reason = result
        json.dump({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }}, sys.stdout)


if __name__ == "__main__":
    main()
