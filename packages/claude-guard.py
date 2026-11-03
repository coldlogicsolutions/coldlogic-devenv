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
lets it. The policy file holds the session's Bash allow and deny rules, as
`{"allow": [...], "deny": [...]}`.
"""

import json
import os
import re
import shlex
import sys

# Programs that run their arguments as a command. A value is the number of
# leading arguments to skip, or a function returning the command's index.
SHELLS = {"bash", "sh", "zsh", "dash"}
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

# Commands that only read, allowed anywhere in a pipeline. A secrets file
# named as an argument is still denied.
READ_ONLY = {"cd", "pwd", "ls", "cat", "head", "tail", "grep", "rg", "wc",
             "sort", "uniq", "cut", "tr", "jq", "echo", "printf", "true",
             "diff", "column", "basename", "dirname", "realpath"}

OPERATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", "\n", ";;"}
REDIRECTS = re.compile(r"^\d*(>>?|<|<<<?|>&|<&|&>>?)$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


class Unparsable(Exception):
    pass


def split_commands(text):
    """Split shell text into simple commands, each a list of words.

    Command substitutions are split out as commands of their own. Anything
    this can't follow (an unclosed quote, a heredoc) raises Unparsable.
    """
    text = drop_heredoc_bodies(text)
    # Duplicating a descriptor, or discarding output, writes no file.
    text = re.sub(r"\d*>&\d+|&?\d*>\s*/dev/null", " ", text)
    commands = []
    for inner in substitutions(text):
        commands.extend(split_commands(inner))
    lexer = shlex.shlex(text.replace("\\\n", " "), posix=True,
                        punctuation_chars=";&|()<>")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = "#"
    words = []
    try:
        for token in lexer:
            if token in OPERATORS or token == "\n":
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


def drop_heredoc_bodies(text):
    """Text with each heredoc's body removed: it is data, not commands."""
    lines = text.split("\n")
    out, delimiter = [], None
    for line in lines:
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m:
            delimiter = m.group(2)
            # The operator goes too, so a substitution holding the heredoc
            # parses on its own.
            line = line[:m.start()] + line[m.end():]
        out.append(line)
    if delimiter is not None:
        raise Unparsable("unterminated heredoc")
    return "\n".join(out)


def substitutions(text):
    """The bodies of $(...) and `...` in text, outermost first."""
    found = []
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
            i = j
        elif text[i] == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            found.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1
    return found


def strip_redirects(words):
    """Words with redirections split off. The targets are kept separately,
    as files the command touches."""
    out, i = [], 0
    while i < len(words):
        if REDIRECTS.match(words[i]):
            out.append(">" + (words[i + 1] if i + 1 < len(words) else ""))
            i += 2
        else:
            out.append(words[i])
            i += 1
    return out


def unwrap(words):
    """The commands a simple command runs, with wrappers removed.

    Returns (commands, wrapped): commands is a list of word lists, and
    wrapped says whether anything was removed that changes how a rule should
    see it (an environment assignment, a wrapper, a shell's -c).
    """
    wrapped = False
    while words:
        head = os.path.basename(words[0])
        if ASSIGNMENT.match(words[0]):
            words, wrapped = words[1:], True
        elif head == "env":
            i = 1
            while i < len(words) and (words[i].startswith("-") or ASSIGNMENT.match(words[i])):
                i += 1
            words, wrapped = words[i:], True
        elif head in NO_ARG_WRAPPERS:
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 1
            words, wrapped = words[i:], True
        elif head == "nice":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] == "-n" else 1
            words, wrapped = words[i:], True
        elif head == "timeout":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-s", "-k", "--signal", "--kill-after") else 1
            words, wrapped = words[i + 1:], True
        elif head in SHELLS:
            script = shell_script(words)
            if script is None:
                return [words], wrapped
            commands = []
            for c in split_commands(script):
                inner, _ = unwrap(c)
                commands.extend(inner)
            return commands, True
        elif head == "eval":
            commands = []
            for c in split_commands(" ".join(words[1:])):
                inner, _ = unwrap(c)
                commands.extend(inner)
            return commands, True
        elif head == "devenv":
            inner = devenv_command(words)
            if inner is None:
                return [words], wrapped
            words, wrapped = inner, True
        elif head in ("npx", "bunx", "pnpx"):
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-p", "--package") else 1
            words, wrapped = words[i:], True
        elif head in ("pnpm", "yarn", "npm") and len(words) > 1 and words[1] in ("exec", "dlx", "x"):
            i = 2
            while i < len(words) and words[i].startswith("-"):
                i += 1
            words, wrapped = words[i:], True
        else:
            return [normalize_git(words)], wrapped
    return [], wrapped


def shell_script(words):
    """The script a shell runs with -c, or None if it runs a file or stdin."""
    for i, w in enumerate(words[1:], 1):
        if w == "-c" or (re.match(r"^-[a-z]*c[a-z]*$", w)):
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
        if w in GIT_VALUE_FLAGS:
            i += 2
        elif "=" in w and w.split("=", 1)[0] in GIT_VALUE_FLAGS:
            i += 1
        elif w in GIT_FLAGS:
            i += 1
        else:
            # An unknown global option: keep it, so nothing below mistakes
            # it for a subcommand.
            return words
    return ["git"] + words[i:]


def forbidden(words):
    """Why no session may run this command, or None."""
    if not words:
        return None
    head = os.path.basename(words[0])
    args = words[1:]
    if head == "git" and args:
        sub, rest = args[0], args[1:]
        if sub == "push":
            for a in rest:
                if a in ("--force", "--mirror", "--force-if-includes") or a.startswith("--force-with-lease"):
                    return "force push"
                if re.match(r"^-[A-Za-z]*f[A-Za-z]*$", a):
                    return "force push"
                if a.startswith("+") or (":" in a and a.split(":", 1)[0].startswith("+")):
                    return "force push (+refspec)"
        if sub == "reset" and "--hard" in rest:
            return "git reset --hard"
    if head == "wrangler" and args:
        if args[0] in ("deploy", "publish", "rollback"):
            return "wrangler " + args[0]
        if args[0] == "versions" and len(args) > 1 and args[1] == "deploy":
            return "wrangler versions deploy"
    if head == "nix" and args[:1] == ["develop"]:
        return "nix develop: tools come from the devenv shell"
    if head in ("nix-shell",):
        return "nix-shell: tools come from the devenv shell"
    # Merging with the user's own credentials bypasses the review the
    # organization ruleset requires. The App's merges don't.
    if head == "gh" and args[:2] == ["pr", "merge"]:
        return "gh pr merge with your credentials skips review; the App merges approved PRs"
    if head == "gh" and args[:1] == ["api"] and any(re.search(r"/pulls/[^/]+/merge\b", a) for a in args):
        return "merging through gh api with your credentials skips review"
    return None


def secret_path(path):
    """Whether a path names a secrets file."""
    path = path.lstrip(">")
    if not path:
        return False
    name = os.path.basename(path.rstrip("/"))
    if name in (".env", ".dev.vars"):
        return True
    for prefix in (".env.", ".dev.vars."):
        if name.startswith(prefix) and name != prefix + "example":
            return True
    parts = path.replace("\\", "/").split("/")
    return "secrets" in parts[:-1] or name == "secrets"


def rule_regex(rule):
    """A Bash permission rule as a regex. `*` matches anything; a trailing
    ` *` is optional when it's the rule's only wildcard."""
    if rule.count("*") == 1 and rule.endswith(" *"):
        return re.compile(re.escape(rule[:-2]) + r"( .*)?\Z", re.S)
    return re.compile(".*".join(re.escape(p) for p in rule.split("*")) + r"\Z", re.S)


def matches(rules, words):
    text = " ".join(words)
    return any(r.match(text) for r in rules)


def allowed(rules, words):
    if any(w.startswith(">") for w in words):
        return False
    return os.path.basename(words[0]) in READ_ONLY or matches(rules, words)


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
        commands = []
        wrapped = False
        for words in split_commands(command):
            inner, w = unwrap(words)
            commands.extend(inner)
            wrapped = wrapped or w
    except Unparsable as e:
        # A command this can't follow gets no automatic allow, and a user
        # decides it.
        return "ask", f"coldlogic guard can't parse this command ({e})."

    for words in commands:
        reason = forbidden(words)
        if reason:
            return "deny", f"Not allowed in a session: {reason}."
        for w in words[1:]:
            if secret_path(w):
                return "deny", f"{w.lstrip('>')} is a secrets file. Change .env.example instead, and say what the real file needs."

    deny = [rule_regex(r) for r in policy.get("deny", [])]
    for words in commands:
        if matches(deny, words):
            return "deny", f"Denied by this project's rules: {' '.join(words)}"

    allow = [rule_regex(r) for r in policy.get("allow", [])]
    if commands and all(allowed(allow, w) for w in commands):
        return "allow", "coldlogic guard: every command matches an allow rule."
    if wrapped and matches(allow, command.split()):
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
