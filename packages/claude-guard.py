"""A Claude Code PreToolUse hook: decides a tool call from what it would run.

Permission rules match a command's text, so a wrapper (`devenv shell --
...`), a global option (`git -C . push -f`) or `bash -c` gets past them. This
lexes each command as bash would, unwraps it, then:

- denies the commands no session may run, however they are spelled;
- denies reading or writing a secrets file, from a file tool or a command
  that names one;
- asks when a command inside matches an ask rule;
- allows a command only when it is plain (no expansion, cd, redirect to a
  file, config override or construct this doesn't follow) and every part of
  it, unwrapped, matches the session's Bash allow rules;
- otherwise leaves the call to Claude Code's own rules.

The deny side is a backstop, not a boundary: a script can still do anything
the sandbox lets it. The allow side is strict, since what it allows runs
without a prompt. The policy file holds the session's Bash rules, as
`{"allow": [...], "ask": [...], "deny": [...]}`.
"""

import fnmatch
import unicodedata
import json
import os
import re
import sys

SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "mksh", "ash", "fish"}
# Interpreters whose script this can't read.
INTERPRETERS = {"python", "python3", "node", "perl", "ruby", "deno", "bun"}
RESERVED = {"!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done",
            "while", "until", "time", "coproc"}
# Constructs whose words aren't plain commands; nothing using them is allowed.
UNFOLLOWED = {"for", "case", "esac", "select", "function", "in"}

# Option flags of `devenv` and `devenv shell` that a command may come after.
DEVENV_FLAGS = {"-q", "--quiet", "-v", "--verbose", "--impure", "--offline",
                "--refresh-eval-cache", "--no-eval-cache"}
DEVENV_VALUE_FLAGS = {"-P", "--profile", "--log-format"}

# The only global options stripped before rules match. Any other (--bare,
# --literal-pathspecs...) stays, so `git <option> <sub>` matches no rule.
GIT_FLAGS = {"--no-pager", "--no-optional-locks"}
GIT_VALUE_FLAGS = {"-C"}
# Options that change which programs git runs or which repository it acts
# on: a rule allowing the subcommand no longer means what it says.
GIT_RELOCATING = {"--git-dir", "--work-tree", "--namespace", "--exec-path",
                  "--super-prefix", "--attr-source", "--list-cmds"}

# Commands that only read what they're given, allowed in a pipeline without a
# rule as long as every argument stays inside the project (see read_only).
READ_ONLY = {"pwd", "ls", "cat", "head", "tail", "grep", "wc", "cut",
             "tr", "echo", "printf", "true", "column", "basename",
             "dirname"}

SECRET_NAMES = (".env", ".dev.vars")
# Names a glob is tested against, to catch `cat .e*`.
SECRET_EXAMPLES = (".env", ".env.local", ".env.production", ".dev.vars")

# Stand-in for a substitution's output in a word. A command holding one
# gets no allow: the canonical commit message is handled before lexing.
PLACEHOLDER = "SUBSTITUTED"


class Unparsable(Exception):
    pass


class Command:
    """A simple command: its words, and what about it rules out an allow."""

    def __init__(self):
        self.words = []
        # Something the shell expands unquoted ($VAR, a glob, ~), so the
        # words aren't what runs.
        self.expands = False
        # A file it reads from or writes to by redirection.
        self.redirects = []
        self.heredocs = []

    def __bool__(self):
        return bool(self.words or self.redirects)


def find_close(text, i, opener="(", closer=")"):
    """The index just past the bracket closing the one opened before i,
    skipping quoted text."""
    depth = 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise Unparsable("unclosed '")
            i = j + 1
            continue
        if c == '"':
            i = skip_double(text, i + 1)
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise Unparsable(f"unclosed {opener}")


def skip_double(text, i):
    """The index just past the `"` closing a string that starts at i."""
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
        elif c == '"':
            return i + 1
        elif text.startswith("$(", i):
            i = find_close(text, i + 2)
        elif c == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            i = j + 1
        else:
            i += 1
    raise Unparsable('unclosed "')


def lex(text):
    """(commands, inner scripts): the simple commands in text, and the
    bodies of substitutions and of heredocs fed to a shell, to be lexed and
    checked on their own."""
    commands, inner = [], []
    cmd, word = Command(), None
    pending_redirect = None
    quoted = False
    i = 0

    def end_word():
        nonlocal word, pending_redirect, quoted
        if word is None:
            return
        was_quoted, quoted = quoted, False
        if pending_redirect is not None:
            op, pending_redirect = pending_redirect, None
            if op.startswith("<<") and not op.startswith("<<<"):
                cmd.heredocs.append((word, was_quoted))
            elif word != "/dev/null":
                cmd.redirects.append(word)
        else:
            cmd.words.append(word)
        word = None

    def end_command():
        nonlocal cmd
        end_word()
        if pending_redirect is not None:
            raise Unparsable("redirection without a target")
        if cmd:
            commands.append(cmd)
        cmd = Command()

    def append(s):
        nonlocal word
        word = (word or "") + s

    while i < len(text):
        c = text[i]
        if c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            ended = cmd
            end_command()
            i += 1
            for delimiter, delimiter_quoted in ended.heredocs:
                body, i = take_body(text, i, delimiter)
                programs = {os.path.basename(w) for w in ended.words}
                if SHELLS & programs or pipes_to_shell(text):
                    inner.append(body)
                elif INTERPRETERS & programs:
                    raise Unparsable("a heredoc fed to an interpreter")
                elif not delimiter_quoted:
                    # An unquoted delimiter: bash still expands the body.
                    quoted_text(body, inner, ended)
        elif c == "#" and word is None:
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
        elif c == "\\":
            if text.startswith("\\\n", i):
                i += 2
            else:
                append(text[i + 1:i + 2])
                i += 2
        elif text.startswith("$'", i):
            # ANSI-C quoting: escapes decoded, nothing expanded.
            j = i + 2
            while j < len(text) and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            if j >= len(text):
                raise Unparsable("unclosed $'")
            try:
                append(text[i + 2:j].encode("latin-1", "backslashreplace").decode("unicode_escape"))
            except UnicodeDecodeError:
                raise Unparsable("bad $'' escape")
            quoted = True
            i = j + 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise Unparsable("unclosed '")
            append(text[i + 1:j])
            quoted = True
            i = j + 1
        elif c == '"':
            quoted = True
            j = skip_double(text, i + 1)
            body = text[i + 1:j - 1]
            append(quoted_text(body, inner, cmd))
            i = j
        elif text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            j = find_close(text, i + 2)
            inner.append(text[i + 2:j - 1])
            cmd.expands = True
            append(PLACEHOLDER)
            i = j
        elif c == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            inner.append(text[i + 1:j])
            cmd.expands = True
            append(PLACEHOLDER)
            i = j + 1
        elif c == "$":
            cmd.expands = True
            append("$")
            i += 1
        elif c in "*?[]{}" or (c in "~=" and word is None):
            # `=cmd` is zsh's path expansion: Claude Code runs zsh here.
            cmd.expands = True
            append(c)
            i += 1
        elif c == "(" and word is not None and re.search(r"[*?\]]$", word):
            # A zsh glob qualifier, `*(D)`: part of the word.
            j = text.find(")", i)
            if j < 0:
                raise Unparsable("unclosed glob qualifier")
            if not re.fullmatch(r"\([A-Za-z.,^\-0-9]*\)", text[i:j + 1]) or re.search(r"[eE+]", text[i:j]):
                # Only inert qualifiers: e and + run code.
                raise Unparsable("a glob qualifier this can't read")
            cmd.expands = True
            append(text[i:j + 1])
            i = j + 1
        elif c in ";&|()":
            op = text[i:i + 2] if text[i:i + 2] in ("&&", "||", "|&", ";;", "&>") else c
            if op == "&>":
                end_word()
                pending_redirect = ">"
                i += 3 if text.startswith("&>>", i) else 2
                continue
            if op in ("(", ")"):
                cmd.expands = True
            end_command()
            i += len(op)
        elif c in "<>":
            fd = word if word is not None and word.isdigit() else None
            if fd is not None:
                word = None
            end_word()
            m = re.match(r"<<<|<<-|<<|>>|>&|<&|>\||<>|<|>", text[i:])
            op = m.group(0)
            i += len(op)
            if op in (">&", "<&"):
                # A descriptor only if nothing follows it in the word: zsh
                # writes `>&2x` to a file named 2x.
                m2 = re.match(r"\s*(\d+|-)(?=$|[\s;&|()<>])", text[i:])
                if m2:
                    i += len(m2.group(0))
                    continue
            pending_redirect = op
        else:
            append(c)
            i += 1
    end_command()
    return commands, inner


def pipes_to_shell(text):
    return bool(re.search(r"\|\s*(bash|sh|zsh|dash)\b", text))


def take_body(text, i, delimiter):
    """(a heredoc's body, the index after its closing line)."""
    lines = []
    while i <= len(text):
        j = text.find("\n", i)
        line = text[i:] if j < 0 else text[i:j]
        if line.lstrip("\t") == delimiter:
            return "\n".join(lines), (len(text) if j < 0 else j + 1)
        lines.append(line)
        if j < 0:
            break
        i = j + 1
    raise Unparsable("unterminated heredoc")


def quoted_text(body, inner, cmd):
    """A double-quoted string's text, its substitutions taken out."""
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            out.append(body[i + 1])
            i += 2
        elif body.startswith("$(", i):
            j = find_close(body, i + 2)
            inner.append(body[i + 2:j - 1])
            cmd.expands = True
            out.append(PLACEHOLDER)
            i = j
        elif c == "`":
            j = body.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            inner.append(body[i + 1:j])
            cmd.expands = True
            out.append(PLACEHOLDER)
            i = j + 1
        elif c == "$":
            cmd.expands = True
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


class Unwrapped:
    """The commands a command line runs, with wrappers removed."""

    def __init__(self):
        self.commands = []
        # Something rules out an allow: an environment variable set (PATH,
        # GIT_SSH_COMMAND...), an expansion, a cd, a construct not followed.
        self.opaque = False
        self.wrapped = False

    def add(self, other):
        self.commands.extend(other.commands)
        self.opaque |= other.opaque
        self.wrapped |= other.wrapped


def analyse(text):
    """Every command text runs, unwrapped, as an Unwrapped."""
    result = Unwrapped()
    commands, inner = lex(text)
    for script in inner:
        result.add(analyse(script))
    for cmd in commands:
        if cmd.expands or cmd.redirects:
            result.opaque = True
        for target in cmd.redirects:
            # Kept as words for the secrets check.
            result.commands.append([">" + target])
        if cmd.words:
            words = [v for w in cmd.words for v in expand_braces(w)]
            if words:
                result.add(unwrap(words))
    return result


def expand_braces(word, limit=64):
    """A word's brace expansions (`{--force,}` is `--force`), as bash makes
    them; empty results dropped. More than limit can't be followed."""
    out = []
    todo = [word]
    while todo:
        w = todo.pop()
        m = re.search(r"\{([^{}]*,[^{}]*)\}", w)
        if not m:
            if w:
                out.append(w)
        else:
            todo.extend(w[:m.start()] + part + w[m.end():] for part in reversed(m.group(1).split(",")))
        if len(out) + len(todo) > limit:
            raise Unparsable("too many brace expansions")
    return out


def unwrap(words):
    result = Unwrapped()
    while words:
        head = os.path.basename(words[0])
        if head in RESERVED:
            i = 1
            while head == "time" and i < len(words) and words[i].startswith("-"):
                i += 1
            words, result.opaque = words[i:], True
        elif head in UNFOLLOWED:
            # The words after these aren't one command; check each word as
            # the start of one, so a forbidden command is still found.
            result.opaque = True
            for k in range(1, len(words)):
                result.commands.append(normalize_git(words[k:]))
            return result
        elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words, result.wrapped, result.opaque = words[1:], True, True
        elif head == "env":
            i = 1
            while i < len(words):
                w = words[i]
                if w in ("-u", "--unset", "-C", "--chdir", "-P"):
                    i += 2
                elif w in ("-S", "--split-string") or w.startswith("--split-string=") or (
                        w.startswith("-S") and len(w) > 2):
                    script = (w.split("=", 1)[1] if w.startswith("--split-string=")
                              else w[2:] if w.startswith("-S") and len(w) > 2 else "")
                    rest = words[i + 1:]
                    result.wrapped = result.opaque = True
                    result.add(analyse(" ".join(([script] if script else []) + rest)))
                    return result
                elif w.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
                    i += 1
                else:
                    break
            words, result.wrapped, result.opaque = words[i:], True, True
        elif head in ("command", "builtin", "nohup", "time"):
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 1
            words, result.wrapped = words[i:], True
        elif head == "sudo":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U") else 1
            words, result.wrapped, result.opaque = words[i:], True, True
        elif head == "busybox":
            words, result.wrapped, result.opaque = words[1:], True, True
        elif head == "find":
            result.opaque = True
            for k, w in enumerate(words):
                if w in ("-exec", "-execdir", "-ok", "-okdir"):
                    end = next((e for e in range(k + 1, len(words)) if words[e] in (";", "+", "\\;")), len(words))
                    if end > k + 1:
                        result.add(unwrap(words[k + 1:end]))
            break
        elif head == "exec":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] == "-a" else 1
            words, result.wrapped, result.opaque = words[i:], True, True
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
        elif head == "xargs":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-n", "-I", "-L", "-P", "-d", "-E", "-s", "-a") else 1
            words, result.wrapped, result.opaque = words[i:], True, True
        elif head in SHELLS or head == "eval":
            script = " ".join(words[1:]) if head == "eval" else shell_script(words)
            if script is None:
                break
            result.wrapped = True
            result.add(analyse(script))
            return result
        elif head == "devenv":
            inner = devenv_command(words)
            if inner is None:
                break
            words, result.wrapped = inner, True
        elif head in ("npx", "bunx", "pnpx") or (
                head in ("pnpm", "yarn", "npm") and len(words) > 1 and words[1] in ("exec", "dlx", "x")):
            # The runner's own options come first; the command follows them.
            i = 1 if head in ("npx", "bunx", "pnpx") else 2
            while i < len(words) and words[i].startswith("-"):
                w = words[i]
                if w in ("-c", "--call", "--shell-mode"):
                    i += 2
                    continue
                if w in ("-p", "--package") or w.startswith("--package="):
                    # Another package's binary: the rule names a different one.
                    result.opaque = True
                i += 2 if w in ("-p", "--package") else 1
            # Runners differ on where they read -c, and the last one may win:
            # check every value given anywhere, in any spelling, as a script.
            scripts = []
            for k in range(1 if head in ("npx", "bunx", "pnpx") else 2, len(words)):
                name, eq, inline = words[k].partition("=")
                if name == "-c" or (name.startswith("--") and len(name) > 3 and (
                        "--call".startswith(name) or "--shell-mode".startswith(name))):
                    scripts.append(inline if eq else (words[k + 1] if k + 1 < len(words) else ""))
            for value in scripts:
                result.opaque = True
                result.add(analyse(value))
            words, result.wrapped = words[i:], True
        elif head == "cd" or head == "pushd" or head == "popd":
            # Later commands run somewhere else, so their rules and paths
            # no longer mean what they say.
            result.opaque = True
            return result
        else:
            break
    if words:
        result.commands.append(normalize_git(words))
    return result


def shell_script(words):
    """The script a shell runs with -c, or None if it runs a file or stdin."""
    i = 1
    while i < len(words):
        w = words[i]
        if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", w):
            return words[i + 1] if i + 1 < len(words) else ""
        if w in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            i += 2
        elif w.startswith("-") or w.startswith("+"):
            i += 1
        else:
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
        if name in ("-c", "--config-env") or w.startswith("-c") or name in GIT_RELOCATING:
            # Configuration can make any subcommand run anything (aliases,
            # pagers, diff drivers, includes, push.mirror...).
            raise Unparsable(f"git {w}")
        if name in GIT_VALUE_FLAGS:
            value = inline or (words[i + 1] if i + 1 < len(words) else "")
            if value not in (".", "./"):
                # Possibly another repository, whose own configuration (a
                # pager, an fsmonitor) runs: no rule covers that.
                return words
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


def program(word):
    """A command word's program name: `wrangler@4` is wrangler."""
    if word.startswith("@"):
        return word
    name = os.path.basename(word).split("@", 1)[0]
    return re.sub(r"\.(js|mjs|cjs|exe)$", "", name)


def forbidden(words):
    """Why no session may run this command, or None. Each word is tried as
    the program, since package runners (`pnpm wrangler`) and global flags
    (`wrangler --env prod deploy`) move it."""
    for k, word in enumerate(words):
        reason = forbidden_from(program(word), words[k + 1:])
        if reason:
            return reason
    return None


def forbidden_from(head, args):
    if head == "git" and args:
        # The subcommand, past global options this may not know and their
        # values.
        k = next((k for k, a in enumerate(args) if a in ("push", "reset")), None)
        if k is None:
            return None
        sub, rest = args[k], args[k + 1:]
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
    if head == "wrangler":
        for a in args:
            if a in ("deploy", "publish", "rollback"):
                return "wrangler " + a
    if head == "nix" and "develop" in args:
        return "nix develop: tools come from the devenv shell"
    if head == "nix-shell":
        return "nix-shell: tools come from the devenv shell"
    if head == "gh":
        # The user's own credentials: merging skips the review the
        # organization ruleset requires, and approving counts as that review.
        # The App's (gh-app) don't.
        lowered = [a.lower() for a in args]
        if "pr" in lowered and "merge" in lowered:
            return "gh pr merge with your credentials skips review; the App merges approved PRs"
        if "pr" in lowered and "review" in lowered and any(
                a.startswith("--approve") or re.match(r"^-[A-Za-z]*a[A-Za-z]*$", a) for a in args):
            return "approving with your credentials stands in for your review"
        # The subcommand may follow global flags (`gh --repo o/r api ...`).
        if "alias" in lowered:
            return "gh aliases could hide a merge or an approval"
        if "api" in lowered:
            text = " ".join(lowered)
            if "merge" in text or "approve" in text or "/reviews" in text:
                return "merging or reviewing through gh api with your credentials"
            if "--input" in text or "=@" in text or re.search(r"(^| )@", text):
                raise Unparsable("gh api reading its request from a file")
    if head == "gh-app":
        # The App may merge a PR the developer team approved, but it must not
        # approve one: where the ruleset's file patterns miss a path, its
        # approval would count.
        lowered = [a.lower() for a in args]
        if "alias" in lowered:
            return "gh-app aliases could hide an approval"
        if "review" in lowered and any(
                a.startswith("--approve") or re.match(r"^-[A-Za-z]*a[A-Za-z]*$", a) for a in args):
            return "the App approving a PR"
        if "api" in lowered:
            text = " ".join(lowered)
            if "approve" in text or "/reviews" in text:
                return "the App reviewing a PR through gh-app api"
            if "--input" in text or "=@" in text or re.search(r"(^| )@", text):
                raise Unparsable("gh-app api reading its request from a file")
    return None


def option_values(word):
    """The word, and any value an option carries in it: `--file=x`, and a
    value attached to a cluster of short options, `-Fx`, `-aFx`."""
    candidates = [word]
    if word.startswith("-"):
        if "=" in word:
            candidates.append(word.split("=", 1)[1])
        elif re.match(r"^-[A-Za-z].", word):
            candidates.extend(word[k:] for k in range(2, len(word)))
    return candidates


def secret_path(word):
    """Whether a word, or an option value in it, names or could expand to a
    secrets file, directly or through a symlink."""
    for c in option_values(word.lstrip("<>")):
        if names_secret(c):
            return True
        where = resolve(c)
        if where is not None:
            # Through a link anywhere in the path (`s/key` with s -> secrets),
            # judged by the part inside the project, or the whole path if it
            # leads out of it.
            resolved, inside = where
            if names_secret(inside if inside is not None else resolved):
                return True
    return False


def resolve(path):
    """(the real path, its part inside the project or None) for a relative
    path from the cwd, or None when there is no cwd. realpath resolves
    whatever prefix exists, so a link on the way to a path not yet created
    counts too."""
    cwd = WORKING["cwd"]
    if not cwd or path.startswith("-"):
        return None
    path = os.path.expanduser(path)
    resolved = os.path.realpath(path if os.path.isabs(path) else os.path.join(cwd, path))
    base = os.path.realpath(WORKING["root"] or cwd)
    if resolved == base:
        return resolved, "."
    if resolved.startswith(base + os.sep):
        return resolved, os.path.relpath(resolved, base)
    return resolved, None


# Set by decide: where the command runs, and the project it may stay in.
WORKING = {"cwd": None, "root": None}


def outside(path):
    """Whether a path points outside the project, by its text or, through a
    symlink, by where it resolves."""
    if path in ("/dev/null", "-"):
        return False
    if path.startswith("/") or path.startswith("~") or ".." in path.split("/"):
        return True
    where = resolve(path) if WORKING["root"] else None
    return where is not None and where[1] is None


def away_from_root():
    """Whether the command runs anywhere but the project root. Elsewhere a
    relative program is another file, and git or gh-app may find another
    repository, with its own config, in ways too many to list (a nested
    .git, a bare layout, a worktree's commondir)."""
    cwd, root = WORKING["cwd"], WORKING["root"]
    if not cwd or not root:
        return False
    here, base = os.path.realpath(cwd), os.path.realpath(root)
    return here != base and not (here.startswith(base + os.sep) and own_worktree(here, base))


def own_worktree(here, base):
    """Whether here is the top of one of the project's own git worktrees
    (EnterWorktree's `.claude/worktrees/<name>`): its `.git` file names a
    directory under the project's `.git/worktrees`, which names it back."""
    try:
        with open(os.path.join(here, ".git")) as f:
            m = re.match(r"gitdir: (.+)", f.read().strip())
        if not m:
            return False
        gitdir = os.path.realpath(os.path.join(here, m.group(1)))
        if os.path.dirname(gitdir) != os.path.realpath(os.path.join(base, ".git", "worktrees")):
            return False
        with open(os.path.join(gitdir, "gitdir")) as f:
            return os.path.realpath(os.path.dirname(f.read().strip())) == here
    except OSError:
        return False


def plain_args(words):
    """Whether no argument, or option value, points outside the project or
    names an output file, and the program isn't a path out of it."""
    if "/" in words[0] and outside(words[0]):
        return False
    for w in words[1:]:
        program = os.path.basename(words[0])
        # Per program, since each abbreviates options its own way: git's
        # --output writes a file, wc's --files0-from reads a list of paths
        # (any unique prefix, `--f=`), cargo's --config can name a program.
        if (w == "-o" or (program == "git" and long_option(w, "--output", 5))
                or (program == "wc" and long_option(w, "--files0-from", 3))
                or (program == "cargo" and long_option(w, "--config", 4))):
            return False
        if os.path.basename(words[0]) == "cargo" and (w.startswith("-Z") or w.startswith("+")):
            return False
        if any(outside(c) for c in option_values(w)):
            return False
        if os.path.basename(words[0]) == "git" and (
                long_option(w, "--pathspec-from-file", 7) or
                any(re.search(r"[*?\[]", c) for c in option_values(w) if not c.startswith("-"))):
            # A pathspec glob, or a file of pathspecs: git's `*` crosses `/`
            # and matches dotfiles.
            return False
    return True


def names_secret(path):
    """Whether a path names a secrets file. Case is folded as macOS's
    filesystem folds it (`ſ` is `s`). git pathspec magic (`:(glob)x`, `:/x`,
    `:!x`) and a revision (`HEAD:x`) are looked through."""
    if ":" in path and not path.startswith(":") and names_secret(path.split(":", 1)[1]):
        return True
    path = unicodedata.normalize("NFKC", re.sub(r"^:(\([^)]*\)|[/!^]+)", "", path)).casefold()
    if not path:
        return False
    name = os.path.basename(path.rstrip("/"))
    for secret in SECRET_NAMES:
        if name == secret or (name.startswith(secret + ".") and name != secret + ".example"):
            return True
    # A glob reaches a dotfile only if it starts with a dot itself, or a zsh
    # qualifier (`*(D)`) says so.
    qualifier = re.search(r"\(([^)]*)\)$", name)
    if qualifier:
        pattern = name[:qualifier.start()]
        if "d" in qualifier.group(1) and any(fnmatch.fnmatchcase(s, pattern) or
                                              fnmatch.fnmatchcase(s, "." + pattern) for s in SECRET_EXAMPLES):
            return True
        name = pattern
    if name.startswith(".") and re.search(r"[*?\[]", name) and any(
            fnmatch.fnmatchcase(s, name) for s in SECRET_EXAMPLES):
        return True
    parts = path.replace("\\", "/").split("/")
    return "secrets" in parts[:-1] or name == "secrets"


def rule_regex(rule, widen=False):
    if rule == "*":
        return re.compile(r"[\s\S]*\Z")
    return _rule_regex(rule, widen)


def _rule_regex(rule, widen=False):
    """A Bash permission rule as a regex. `*` matches anything but a
    newline; a trailing ` *` is optional when it's the rule's only wildcard.
    The older `cmd:*` form means `cmd *`, or, for an ask or deny rule
    (widen), any command starting with `cmd`."""
    if rule.endswith(":*"):
        if widen:
            return re.compile(re.escape(rule[:-2]) + r"[^\n]*\Z")
        rule = rule[:-2] + " *"
    if rule.count("*") == 1 and rule.endswith(" *"):
        return re.compile(re.escape(rule[:-2]) + r"( [^\n]*)?\Z")
    return re.compile("[^\n]*".join(re.escape(p) for p in rule.split("*")) + r"\Z")


def matches(rules, words):
    """Whether a rule matches the words. A program word holding whitespace
    (`"git status x/evil"` runs a file of that name) matches nothing."""
    if re.search(r"\s", words[0]):
        return False
    text = " ".join(words)
    return any(r.match(text) for r in rules)


def read_only(words):
    """Whether this is a READ_ONLY command reading only inside the project."""
    if words[0] not in READ_ONLY:
        return False
    if any(PLACEHOLDER in a for a in words[1:]):
        # Its arguments are another command's output.
        return False
    if words[0] == "grep" and any(re.match(r"^-[A-Za-z0-9]*[rRd]", a) or a.startswith("--r")
                                  or a.startswith("--d") for a in words[1:]):
        return False
    return True


def rough_deny(command):
    """A deny reason from reading the text without parsing it: each run of
    words between operators and newlines, quotes dropped. Used only when the
    real parse fails, so an unparsable part can't hide a forbidden one."""
    for segment in re.split(r"[;&|()\n`]+|\$\(", command):
        words = [w.strip("'\"") for w in segment.split()]
        words = [w for w in words if w]
        if not words:
            continue
        try:
            reason = forbidden(normalize_git_loosely(words))
        except Unparsable:
            reason = None
        if reason:
            return f"Not allowed in a session: {reason}."
        for w in words:
            if secret_path(w):
                return f"{w.lstrip('<>')} is a secrets file."
    return None


def normalize_git_loosely(words):
    """git with every global option dropped, for rough_deny."""
    if os.path.basename(words[0]) != "git":
        return words
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                               "--super-prefix", "--attr-source", "--config-env") else 1
    return ["git"] + words[i:]


def decide(tool, tool_input, policy):
    """(decision, reason), or None to leave the call to Claude Code."""
    if tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if secret_path(path):
            return "deny", f"{path} is a secrets file. Change .env.example instead, and say what the real file needs."
        return None
    if tool in ("Grep", "Glob"):
        for key in ("path", "glob", "pattern" if tool == "Glob" else "path"):
            value = tool_input.get(key) or ""
            if secret_path(value):
                return "deny", f"{value} is a secrets file."
        return None
    if tool != "Bash":
        return None

    command = tool_input.get("command", "")
    # The canonical commit message is data: check the command with a stand-in.
    checked = command
    m_wrapper = WRAPPER.match(command)
    inner_text = command[m_wrapper.end():] if m_wrapper else command
    m_commit = COMMIT_MESSAGE.match(inner_text)
    if m_commit:
        checked = (m_wrapper.group(0) if m_wrapper else "") + m_commit.group(1) + " -" + m_commit.group(2) + "m message"
    try:
        result = analyse(checked)
        for words in result.commands:
            reason = forbidden(words)
            if reason:
                return "deny", f"Not allowed in a session: {reason}."
            for w in words:
                if secret_path(w):
                    return "deny", f"{w.lstrip('>')} is a secrets file. Change .env.example instead, and say what the real file needs."
    except Unparsable as e:
        # A command this can't follow gets no automatic allow, and a user
        # decides it, unless a rough reading finds something to deny.
        reason = rough_deny(command)
        if reason:
            return "deny", reason
        return "ask", f"coldlogic guard can't follow this command ({e})."

    commands = [w for w in result.commands if not w[0].startswith(">")]
    deny = [rule_regex(r, widen=True) for r in policy.get("deny", [])]
    ask = [rule_regex(r, widen=True) for r in policy.get("ask", [])]
    # Rules see both what runs and what was written (`devenv shell:*`).
    if any(r.match(checked) for r in deny):
        return "deny", "Denied by a deny rule."
    # Rules also see git with every global option dropped, so an inert one
    # (`git --literal-pathspecs push`) doesn't dodge them.
    ruled = commands + [normalize_git_loosely(w) for w in commands if os.path.basename(w[0]) == "git"]
    for words in ruled:
        if matches(deny, words):
            return "deny", f"Denied by this project's rules: {' '.join(words)}"
    if any(r.match(checked) for r in ask):
        return "ask", "An ask rule covers this command."
    for words in ruled:
        if matches(ask, words):
            return "ask", f"An ask rule covers: {' '.join(words)}"

    allow = [rule_regex(r) for r in policy.get("allow", [])]
    # `checked` has the commit message's stand-in already.
    words = simple_command(checked) if not away_from_root() else None
    # The plain reading and the full analysis must agree on one command.
    if (words is not None and commands == [words] and len(result.commands) == 1
            and not result.opaque and plain_args(words)
            and (read_only(words) or matches(allow, words))):
        return "allow", "coldlogic guard: a plain command an allow rule names."
    if result.wrapped and matches(allow, command.split()):
        # A rule allowing the wrapper itself would let anything through it.
        return "ask", "coldlogic guard: a rule allows the wrapper, not the command inside it."
    return None


# The one compound form allowed: a commit whose message is a quoted heredoc.
# Its body may hold no `)` or `"`: macOS's bash 3.2 ends the substitution at
# the first `)`, even inside the heredoc.
COMMIT_MESSAGE = re.compile(
    r"""(git commit(?: -[A-Za-z]+| --[a-z-]+)*) -([A-Za-z]*)m "\$\(cat <<'EOF'\n(?:(?!EOF)[^\n)"]*\n)*EOF\n\)"\Z""")
WRAPPER = re.compile(r"devenv shell(?: --quiet| -q)? -- ")
# Characters that mean nothing to the shell outside quotes.
PLAIN = re.compile(r"[A-Za-z0-9 _./:@%+,=-]")


def simple_command(command):
    """The words of command if it is one plain command, optionally behind
    `devenv shell [--quiet] --`, that the shell runs as written: no operator,
    expansion, redirect, comment or escape outside quotes, nothing but text
    inside them. Anything else gets no allow from this hook."""
    text = command[len(m.group(0)):] if (m := WRAPPER.match(command)) else command
    words, word, i = [], None, 0
    while i < len(text):
        c = text[i]
        if c == " ":
            if word is not None:
                words.append(word)
            word = None
            i += 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0 or "\n" in text[i:j]:
                return None
            word = (word or "") + text[i + 1:j]
            i = j + 1
        elif c == '"':
            j = text.find('"', i + 1)
            if j < 0 or re.search(r'[$`\\\n]', text[i + 1:j]):
                return None
            word = (word or "") + text[i + 1:j]
            i = j + 1
        elif PLAIN.match(c) and not (c in "=" and word is None):
            word = (word or "") + c
            i += 1
        else:
            return None
    if word is not None:
        words.append(word)
    if not words or "=" in words[0] or os.path.basename(words[0]) in (
            "npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "env", "sudo", "xargs", "find", "exec",
            "command", "builtin", "eval", "timeout", "nice", "nohup", "time", "devenv",
            "busybox") or os.path.basename(words[0]) in SHELLS:
        # A runner or wrapper: the rule names what it runs, not it.
        return None
    return normalize_git(words) if words[0] == "git" else words


def settings_rules():
    """Bash ask and deny rules from the user's and the checkout's own
    settings, which the policy file can't know."""
    rules = {"ask": [], "deny": []}
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    paths = [os.path.join(config, "settings.json"),
             "/Library/Application Support/ClaudeCode/managed-settings.json",
             "/etc/claude-code/managed-settings.json"]
    project = os.environ.get("CLAUDE_PROJECT_DIR")
    if project:
        paths += [os.path.join(project, ".claude", "settings.json"),
                  os.path.join(project, ".claude", "settings.local.json")]
    for path in paths:
        try:
            with open(path) as f:
                permissions = json.load(f).get("permissions") or {}
        except (OSError, ValueError, AttributeError):
            continue
        for kind in rules:
            for rule in permissions.get(kind) or []:
                if rule == "Bash":
                    rules[kind].append("*")
                m = re.match(r"^Bash\((.*)\)$", str(rule), re.S)
                if m:
                    rules[kind].append(m.group(1))
    return rules


def main():
    try:
        policy = {}
        if len(sys.argv) > 1:
            with open(sys.argv[1]) as f:
                policy = json.load(f)
        event = json.load(sys.stdin)
        tool = event.get("tool_name", "")
        if tool == "Bash":
            for kind, rules in settings_rules().items():
                policy[kind] = policy.get(kind, []) + rules
        WORKING["cwd"] = event.get("cwd") or os.getcwd()
        WORKING["root"] = os.environ.get("CLAUDE_PROJECT_DIR") or WORKING["cwd"]
        result = decide(tool, event.get("tool_input") or {}, policy)
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
