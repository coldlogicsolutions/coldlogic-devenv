"""A Claude Code PreToolUse hook: decides a tool call from what it would run.

Permission rules match a command's text, so a wrapper (`devenv shell --
...`), a global option (`git -C . push -f`) or `bash -c` gets past them. This
lexes each command as bash would, unwraps it, then:

- denies the commands no session may run, however they are spelled;
- denies reading or writing a secrets file, from a file tool or a command
  that names one;
- denies changing a project file from Bash in the common ways (`sed -i`,
  `perl -i`, `tee`, a `>` redirect, a script that opens a file for
  writing), pointing to the Edit and Write tools, which the project's rules
  allow without a prompt;
- denies a `git switch` or `git checkout` that would take the project's
  main checkout off its default branch (creating a branch, detaching,
  checking out anything else; file restores are fine), pointing to a
  worktree, following a literal cd; asks, after every other deny, when
  it can't tell which checkout one runs in (see main_checkout_switch);
- denies a `git switch` or `git checkout` in the project's repository that
  would set up tracking (`--track`, `-t`, or a new branch from a
  remote-tracking start point without `--no-track`), which writes the
  shared `.git/config` the sandbox protects, pointing to `--no-track` (see
  tracking_create);
- asks when a command inside matches an ask rule, or when the call defines
  a shell function (a call to it can't be followed). Every rule is matched
  against each command of the call as written, wrapper included, and
  unwrapped; a rule written with the wrapper also stands for its inner
  command;
- checks for denies, as a script, a heredoc or here-string body read by
  anything not known to take it as data (a read-only filter, `git commit
  -F -`, `gh-app ... --body-file -`, a tee to scratch files only);
- denies hiding scripts/check.sh's exit status, in any call it can lex:
  piping it (directly or through a shell) unless a plain top-level `set`
  turns on pipefail first, following it with anything but `&& ...` at its
  own nesting level (the operator after its subshell's `)` or group's `}`
  counts; what a `&&` leads to may hold any), backgrounding it with `&`,
  or running it inside a
  command or process substitution (`$( )`, backticks, `<( )`, `>( )`);
- allows a call only when its sequences (`&&`, `||`, `;`, newlines) and
  pipelines are plain (no expansion but $TMPDIR, cd, loop, subshell, config
  override or other construct this doesn't follow) and every command and
  stage in them, optionally behind `devenv shell --`, is one an allow rule
  names or one that only reads, with no option that opens an editor or
  drops refs (a commit without a message, a forced fetch), no word
  starting `-o` outside a few programs where it names no file, and no `o`
  in a short cluster for the programs where it writes or runs one
  (`unzip -qo`). Quoted heredoc
  bodies are data, and redirects to a device or a scratch file outside the
  project are fine;
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
# Programs that run another program: unwrap() looks inside them, and none of
# them is ever allowed itself.
WRAPPERS = {"npx", "bunx", "pnpx", "pnpm", "yarn", "npm", "env", "sudo", "xargs", "find",
            "exec", "command", "builtin", "eval", "timeout", "nice", "nohup", "time",
            "devenv", "busybox"}
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

# Commands that only read what they're given, allowed alone without a rule
# as long as every argument stays inside the project (see read_only).
READ_ONLY = {"pwd", "ls", "cat", "head", "tail", "grep", "wc", "cut",
             "tr", "echo", "printf", "true", "column", "basename",
             "dirname", "sort", "uniq", "jq", "set"}

SECRET_NAMES = (".env", ".dev.vars")
# Names a glob is tested against, to catch `cat .e*`.
SECRET_EXAMPLES = (".env", ".env.local", ".env.production", ".dev.vars")

# Stand-in for a substitution's output in a word. A command holding one
# gets no allow: the canonical commit message is handled before lexing.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
PLACEHOLDER = "SUBSTITUTED"
# `$TMPDIR` or `${TMPDIR}` at the start of a word: the only expansion an
# allowed command may hold (see tmpdir).
TMPDIR_WORD = re.compile(r"\$(?:TMPDIR(?![A-Za-z0-9_])|\{TMPDIR\})")
# A shell function's name, where a definition can start.
FUNCTION_NAME = r"[A-Za-z_][A-Za-z0-9_.:-]*"
# Where the bytes written to these go is no file of the project's.
DEVICES = ("/dev/stdout", "/dev/stderr")


def tmpdir(quoted):
    """What `$TMPDIR` stands for in a word: the hook's own TMPDIR, else
    /tmp. Both are scratch roots (see scratch), and the sandbox gives a
    session a TMPDIR under one of them. None, so the word counts as an
    expansion, when an unquoted value would be split or globbed."""
    value = os.environ.get("TMPDIR") or "/tmp"
    if not quoted and not re.fullmatch(r"[A-Za-z0-9_./-]+", value):
        return None
    return value


class Unparsable(Exception):
    pass


class Substitution(str):
    """The text of a command or process substitution (`$(...)`, a backtick,
    `<(...)`, `>(...)`), as lex hands it on among the inner scripts: its
    status never becomes the call's."""


class Command:
    """A simple command: its words, and what about it rules out an allow."""

    def __init__(self):
        self.words = []
        # Something the shell expands unquoted ($VAR, a glob, ~), so the
        # words aren't what runs.
        self.expands = False
        # Each redirect to or from a file as (operator, target); /dev/null
        # and descriptor duplication aren't kept.
        self.redirect_ops = []
        # The operator before it and the one that ended it (None at either
        # end of the text), and how many `(` it sits inside.
        self.after = None
        self.ended_by = None
        # When `)` ended it, the operator after that `)` (and any further
        # closers): what leads on from the subshell it ends.
        self.closed_by = None
        # How many `(` that operator sits inside.
        self.closed_depth = 0
        self.depth = 0
        # The next stage of its pipeline: the command its output goes to.
        self.next = None
        # Heredoc bodies fed to an interpreter.
        self.scripts = []
        # Quoted strings in a script fed to an interpreter, checked as paths
        # for the secrets check only.
        self.mentions = []
        # It runs a script this can't read.
        self.unread = False

    @property
    def redirects(self):
        """The files it reads from or writes to by redirection."""
        return [target for _, target in self.redirect_ops]

    @property
    def writes(self):
        """The files among those it writes to."""
        return [target for op, target in self.redirect_ops if op in WRITE_OPS]

    def __bool__(self):
        return bool(self.words or self.redirect_ops)


# Redirect operators that write to their target.
WRITE_OPS = (">", ">>", ">|", ">!", ">>!", ">&", "<>")
# Words that close a compound command (`{ ...; } | sh`, `done | sh`): what
# such a command pipes on is the output of every command inside it.
GROUP_CLOSERS = ("}", "done", "fi", "esac")
# Programs that run what they're given or read as commands.
RUNS_INPUT = {"eval", "source", ".", "xargs", "exec"}


def find_close(text, i, opener="(", closer=")"):
    """The index just past the bracket closing the one opened before i,
    skipping quoted text."""
    depth = 1
    pending = []
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "\n" and pending:
            # Heredoc bodies are data: an apostrophe or `)` in one means
            # nothing.
            i += 1
            for delimiter, strip_tabs in pending:
                _, i = take_body(text, i, delimiter, strip_tabs)
            pending = []
            continue
        if text.startswith("<<", i) and not text.startswith("<<<", i):
            m = HEREDOC.match(text, i)
            if m:
                pending.append((m.group(2), text.startswith("<<-", i)))
                i = m.end()
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
    """(commands, inner scripts, function names, scanned bodies): the simple
    commands in text, the bodies of substitutions and of heredocs and
    here-strings fed to a shell, to be lexed and checked on their own, the
    shell functions text defines, and the bodies something other than a
    known data consumer reads, to be checked for denies only."""
    commands, inner, functions = [], [], set()
    cmd, word = Command(), None
    pending_redirect = None
    quoted = False
    # The heredocs opened on the current line, in order, each with the
    # command that opened it: their bodies follow the line's newline.
    heredocs = []
    # Every heredoc body read, with what it needs to judge it once the
    # pipeline it feeds is known: (body, delimiter quoted, opening command).
    bodies = []
    # Pipelines: the command whose output the next command reads (GROUP for
    # a compound command, `(...) |`), and the first stages fed by compound
    # commands, which may hold any command of the text.
    after, pipe_from, depth = None, None, 0
    # The last command a `)` ended, until the operator after the closers.
    closing = None
    group_stages = []
    i = 0

    def end_word():
        nonlocal word, pending_redirect, quoted
        if word is None:
            return
        was_quoted, quoted = quoted, False
        if pending_redirect is not None:
            op, pending_redirect = pending_redirect, None
            if op.startswith("<<") and not op.startswith("<<<"):
                heredocs.append((word, was_quoted, op == "<<-", cmd))
            else:
                if op == "<<<":
                    # A here-string is a one-line body: judged by what reads
                    # it, as a heredoc's is.
                    bodies.append((word, True, cmd))
                if word != "/dev/null":
                    cmd.redirect_ops.append((op, word))
        else:
            cmd.words.append(word)
        word = None

    def end_command(op=None):
        """Ends the current command at operator op. Returns it."""
        nonlocal cmd, after, pipe_from, closing
        end_word()
        if pending_redirect is not None:
            raise Unparsable("redirection without a target")
        ended = cmd
        if cmd:
            closing = cmd if op == ")" else None
        elif (op == ")" and closing is None and commands and commands[-1].depth == depth
              and commands[-1].ended_by in (";", "\n")):
            # `(a;)`: the `)` closes what the last command, ended by `;` or
            # a newline, was in. One a `&` ended keeps it: `(a &) && b`
            # backgrounds a whatever follows.
            closing = commands[-1]
        elif op != ")" and closing is not None:
            if op != "(":
                closing.closed_by, closing.closed_depth = op, depth
            closing = None
        if cmd:
            cmd.after, cmd.ended_by, cmd.depth = after, op, depth
            if pipe_from is not None:
                if pipe_from is GROUP:
                    group_stages.append(cmd)
                else:
                    pipe_from.next = cmd
                pipe_from = None
            commands.append(cmd)
        # A newline after an empty command (`a |` then a newline) keeps the
        # operator before it.
        if cmd or op != "\n":
            after = op
        cmd = Command()
        return ended

    def append(s):
        nonlocal word
        word = (word or "") + s

    while i < len(text):
        c = text[i]
        if c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            end_command("\n")
            i += 1
            # Every heredoc opened on the line, whichever command opened it
            # (`cmd <<'EOF' | grep x` opens it in cmd, not grep), in order.
            # What reads each body is judged at the end, once the rest of
            # its pipeline (`cat <<'EOF' |`, a newline, the body, `sh`) is
            # known.
            opened, heredocs[:] = list(heredocs), []
            for delimiter, delimiter_quoted, strip_tabs, ended in opened:
                body, i = take_body(text, i, delimiter, strip_tabs)
                bodies.append((body, delimiter_quoted, ended))
                if not delimiter_quoted:
                    # An unquoted delimiter: bash expands the body.
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
            at_start = word is None
            quoted = True
            j = skip_double(text, i + 1)
            body = text[i + 1:j - 1]
            append(quoted_text(body, inner, cmd, at_start))
            i = j
        elif text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            j = find_close(text, i + 2)
            inner.append(Substitution(text[i + 2:j - 1]))
            cmd.expands = True
            append(PLACEHOLDER)
            i = j
        elif c == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            inner.append(Substitution(text[i + 1:j]))
            cmd.expands = True
            append(PLACEHOLDER)
            i = j + 1
        elif c == "$":
            m = TMPDIR_WORD.match(text, i) if word is None else None
            value = tmpdir(quoted=False) if m else None
            if value is not None:
                append(value)
                i = m.end()
            else:
                cmd.expands = True
                append("$")
                i += 1
        elif c == "(" and (m := re.match(r"\(\s*\)", text[i:])) and (
                (word is not None and re.fullmatch(FUNCTION_NAME, word) and cmd.words in ([], ["function"]))
                or (word is None and len(cmd.words) in (1, 2) and cmd.words[:-1] in ([], ["function"])
                    and re.fullmatch(FUNCTION_NAME, cmd.words[-1]))):
            # A function definition, `name()` or `name ()`: the call is one
            # the guard can't follow, and a later call to name runs its body,
            # not the program of that name. The body is lexed as commands.
            if word is None:
                word = cmd.words.pop()
            functions.add(word)
            word = None
            cmd.expands = True
            end_command("()")
            i += m.end()
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
            ended = end_command(op)
            depth += {"(": 1, ")": -1}.get(op, 0)
            if op in ("|", "|&"):
                # A compound command's output (`(...) |`, `done |`) is that
                # of every command inside it.
                grouped = not ended or ended.words[:1] in [[w] for w in GROUP_CLOSERS]
                pipe_from = GROUP if grouped else ended
            elif op not in ("(", ")"):
                pipe_from = None
            i += len(op)
        elif c in "<>":
            fd = word if word is not None and word.isdigit() else None
            if fd is not None:
                word = None
            end_word()
            # `>!` and `>>!` are zsh's clobbering redirects.
            m = re.match(r"<<<|<<-|<<|>>!|>>|>&|<&|>\||>!|<>|<|>", text[i:])
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
    if heredocs:
        raise Unparsable("unterminated heredoc")
    for cmd in commands:
        if cmd.words[:1] == ["function"] and len(cmd.words) > 1:
            functions.add(cmd.words[1])
    # What a compound command pipes on may come from any command in it.
    grouped = [s for first in group_stages for s in stages(first)]
    scanned = []
    for body, delimiter_quoted, opener in bodies:
        # The body goes to the command that opened it, and from there down
        # the rest of its pipeline.
        readers = [opener] + stages(opener.next) + grouped
        kinds = [reader_kind(opener)] + [stage_kind(s) for s in readers[1:]]
        if "shell" in kinds:
            # Checked as commands, as the shell will run it.
            inner.append(body)
            continue
        if not all(data_consumer(r) for r in readers):
            # Something reads it that this can't say takes it as data (tcsh,
            # ssh, sqlite3, awk -f -...): its denies are checked as if it
            # were a script. Approval is decided as below.
            scanned.append(body)
        if "interpreter" in kinds:
            # A script this can't read: no allow from here, so the sandbox
            # and Claude Code's rules decide it. A string in it that looks
            # like a path still can't name a secrets file.
            opener.unread = True
            opener.scripts.append(body)
            opener.mentions.extend(
                m.group(2) for m in re.finditer(r"""(['"])([^'"\s]+)\1""", body)
                if "/" in m.group(2) or m.group(2).startswith("."))
        elif "unknown" in kinds:
            # A program this can't say only reads the body: data, but no
            # allow from here.
            opener.unread = True
    return commands, inner, functions, scanned


# Stands for a compound command as the command a pipeline reads from.
GROUP = object()


def stages(first):
    """first and the pipeline stages after it."""
    out = []
    while first is not None:
        out.append(first)
        first = first.next
    return out


def reader_kind(cmd):
    """What a command does with a heredoc body it reads: "shell" (runs it as
    commands, or might: a program named by an expansion), "interpreter",
    "data" (the opener, or a stage that only reads), or "unknown"."""
    if not cmd.words:
        return "data"
    if re.search(r"[$*?\[{~]", cmd.words[0]) or PLACEHOLDER in cmd.words[0]:
        # A program the shell picks by expanding a word (`"$SHELL"`, `/bin/?sh`).
        return "shell"
    words = [v for w in cmd.words for v in expand_braces(w)]
    names = {os.path.basename(w) for w in words}
    if SHELLS & names or RUNS_INPUT & names:
        return "shell"
    if any(interpreter(n) for n in names):
        return "interpreter"
    return "data"


def stage_kind(cmd):
    """reader_kind for a later stage of a pipeline, which must also be a
    program that only reads."""
    kind = reader_kind(cmd)
    if kind != "data" or not cmd.words:
        return kind
    unwrapped = unwrap(cmd.words)
    if unwrapped.opaque or not unwrapped.commands or not all(
            os.path.basename(w[0]) in READ_ONLY for w in unwrapped.commands):
        return "unknown"
    return "data"


def data_consumer(cmd):
    """Whether a command reading a heredoc or here-string body surely takes
    it as data: a read-only filter, a body flag reading stdin (`git commit
    -F -`, `gh-app ... --body-file -`), or a tee to scratch files only.
    Anything else (tcsh, ssh, sqlite3,
    `awk -f -`) might run it."""
    if not cmd.words:
        return True
    try:
        words = [v for w in cmd.words for v in expand_braces(w)]
        unwrapped = unwrap(words)
        commands = unwrapped.commands
    except Unparsable:
        commands = [normalize_git_loosely(cmd.words)]
    return bool(commands) and all(reads_as_data(w) for w in commands)


def reads_as_data(words):
    """data_consumer for one unwrapped command."""
    prog = os.path.basename(words[0]) if words else ""
    if prog in READ_ONLY:
        return True
    args = words[1:]
    pairs = list(zip(args, args[1:] + [None]))
    if prog == "git":
        args = normalize_git_loosely(words)[1:]
        pairs = list(zip(args, args[1:] + [None]))
        return args[:1] in (["commit"], ["tag"]) and any(
            (w == "--file" or re.match(r"^-[A-Za-z]*F\Z", w)) and nxt == "-"
            or w == "--file=-" or re.match(r"^-[A-Za-z]*F-\Z", w)
            for w, nxt in pairs)
    if prog in ("gh", "gh-app"):
        return any((w in ("--body-file", "-F") and nxt == "-") or w in ("--body-file=-", "-F-")
                   for w, nxt in pairs)
    if prog == "tee":
        # A copy to scratch files only, as a `>` redirect there would be
        # (see safe_redirect): `tee "$TMPDIR/notes.md" <<'EOF'`.
        operands = listed_options(args, "aip", "", {"--append": False, "--ignore-interrupts": False,
                                                    "--output-error": True}, set(), True)
        return operands is not None and all(safe_redirect(">", t) for t in operands)
    return False


def take_body(text, i, delimiter, strip_tabs):
    """(a heredoc's body, the index after its closing line). Only `<<-`
    strips leading tabs from the closing line."""
    lines = []
    while i <= len(text):
        j = text.find("\n", i)
        line = text[i:] if j < 0 else text[i:j]
        if (line.lstrip("\t") if strip_tabs else line) == delimiter:
            return "\n".join(lines), (len(text) if j < 0 else j + 1)
        lines.append(line)
        if j < 0:
            break
        i = j + 1
    raise Unparsable("unterminated heredoc")


def quoted_text(body, inner, cmd, at_start=False):
    """A double-quoted string's text, its substitutions taken out. A
    `$TMPDIR` opening the string at the start of a word stands for its value
    (see tmpdir)."""
    out, i = [], 0
    m = TMPDIR_WORD.match(body) if at_start else None
    if m:
        out.append(tmpdir(quoted=True))
        i = m.end()
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            out.append(body[i + 1])
            i += 2
        elif body.startswith("$(", i):
            j = find_close(body, i + 2)
            inner.append(Substitution(body[i + 2:j - 1]))
            cmd.expands = True
            out.append(PLACEHOLDER)
            i = j
        elif c == "`":
            j = body.find("`", i + 1)
            if j < 0:
                raise Unparsable("unclosed `")
            inner.append(Substitution(body[i + 1:j]))
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
        # Files redirected to, and scripts fed to an interpreter on stdin.
        self.writes = []
        self.scripts = []
        # Shell functions the text defines.
        self.functions = set()
        # The ids of the commands among self.commands run by their own name,
        # not through a wrapper (`command gh` runs the program gh): where a
        # function of that name is defined, they call it.
        self.direct = set()
        # Each command that has a wrapper, as (its words as written, wrapper
        # included, the commands it unwraps to, whether something about it
        # rules out an allow): rules are matched against both spellings.
        self.written = []
        # Bodies of heredocs and here-strings read by something not known
        # to take them as data, each analysed (or read roughly) as a script:
        # checked for denies only (see scan, which also sets .rough).
        self.scanned = []
        self.rough = []
        # scripts/check.sh is piped on with pipefail off, hiding its status.
        self.gate_piped = False
        # scripts/check.sh is followed by `||`, `;`, a newline or `&` and
        # another command, so the call's status isn't the gate's.
        self.gate_hidden = False
        # The text runs scripts/check.sh somewhere.
        self.gate = False
        # A cd, pushd or popd runs: False when none does, its literal target
        # (cd_target), or True when where it goes can't be read. And, for
        # the commands among self.commands that don't run in the call's cwd
        # (after a cd, or through `env -C`, `sudo -D`), their ids mapped to
        # the directory they start in, None when that is unknown.
        self.moves = False
        self.moved = {}

    def add(self, other, direct=True):
        """Merge other in. direct=False: other's commands are run by a
        program (find -exec, bash -c), which no shell function reaches."""
        self.commands.extend(other.commands)
        self.writes.extend(other.writes)
        self.scripts.extend(other.scripts)
        self.opaque |= other.opaque
        self.wrapped |= other.wrapped
        self.functions |= other.functions
        self.gate_piped |= other.gate_piped
        self.gate_hidden |= other.gate_hidden
        self.gate |= other.gate
        self.written.extend(other.written)
        self.scanned.extend(other.scanned)
        if other.moves:
            # A cd inside something else: where it leads isn't followed.
            self.moves = True
        self.moved.update(other.moved)
        if direct:
            self.direct |= other.direct


def safe_redirect(op, target):
    """Whether an output redirect writes only where no file of the project's
    is: a device, or a scratch file outside every checkout of the project,
    by its resolved path. A path with `..` in it is never one."""
    if op not in (">", ">>"):
        return False
    if target in DEVICES:
        return True
    return (".." not in target.split("/") and scratch(target)
            and not project_file(target) and not in_checkout(target))


def in_checkout(path):
    """Whether an absolute path resolves inside the project's root or the
    checkout the command runs in, scratch directory or not."""
    cwd, root = WORKING["cwd"], WORKING["root"]
    if not root or not path.startswith("/"):
        return False
    real = os.path.realpath(path)
    bases = {os.path.realpath(root)}
    if cwd:
        bases.add(checkout_of(cwd) or os.path.realpath(cwd))
    return any(real == b or real.startswith(b + os.sep) for b in bases)


def analyse(text):
    """Every command text runs, unwrapped, as an Unwrapped."""
    result = Unwrapped()
    commands, inner, functions, scanned = lex(text)
    result.functions |= functions
    if functions:
        result.opaque = True
    # The commands of subshells and substitutions, which this doesn't place
    # in order among the rest.
    inner_ids = []
    for script in inner:
        sub = analyse(script)
        inner_ids.extend(id(w) for w in sub.commands)
        if isinstance(script, Substitution) and sub.gate:
            # A substitution's status is never the call's: `x=$(gate); ...`,
            # `echo "$(gate)"`.
            result.gate_hidden = True
        result.add(sub)
    for body in scanned:
        sub = scan(body)
        result.scanned.append(sub)
        result.scanned.extend(sub.scanned)
    # The gate check: scripts/check.sh's status must be the call's. A gate
    # piped on with pipefail off (see pipefail_after), directly or in a
    # group or subshell that is (in_pipeline), or run through a shell in a
    # pipe hides it
    # (gate_piped); so does any command after it that `||`, `;`, a newline
    # or `&` leads to, the operator after a subshell's `)` included, or
    # running it in a substitution (gate_hidden). Only `&& ...` may follow it.
    pipefail, followed = False, True
    # Whether a cd ran earlier in the text, and the directory the commands
    # after it run in, None when that can't be read (see cd_target and
    # main_checkout_switch).
    moved, here = False, WORKING["cwd"]
    # A subshell's cd ends with it: where each `(` depth was entered.
    depth, entered = 0, {}
    for k, cmd in enumerate(commands):
        for d in range(depth + 1, cmd.depth + 1):
            entered[d] = (moved, here)
        depth = max(depth, cmd.depth)
        if cmd.expands or cmd.unread or not all(safe_redirect(op, t) for op, t in cmd.redirect_ops):
            result.opaque = True
        result.writes.extend(cmd.writes)
        result.scripts.extend(cmd.scripts)
        for target in cmd.redirects + cmd.mentions:
            # Kept as words for the secrets check.
            result.commands.append([">" + target])
        if cmd.words:
            words = [v for w in cmd.words for v in expand_braces(w)]
            if words:
                unwrapped = unwrap(words)
                if unwrapped.wrapped:
                    result.written.append((words, unwrapped.commands, unwrapped.opaque or cmd.expands
                                           or cmd.unread
                                           or not all(safe_redirect(op, t) for op, t in cmd.redirect_ops)))
                if moved:
                    for w in unwrapped.commands:
                        # One already placed (`env -C`, a cd inside `bash
                        # -c`) was placed from the call's cwd: unknown here.
                        result.moved[id(w)] = None if id(w) in unwrapped.moved else here
                if unwrapped.moves:
                    # A pipeline's stages and a backgrounded command run in
                    # subshells: whether the cd stays isn't followed.
                    piped = leads_on(cmd)[0] in ("|", "|&", "&") or (
                        k > 0 and leads_on(commands[k - 1])[0] in ("|", "|&"))
                    here = None if piped else moved_to(here, unwrapped.moves)
                    moved = True
                result.add(unwrapped)
                if any(is_gate(w) for w in unwrapped.commands + [words]):
                    result.gate = True
                    if in_pipeline(commands, k) and not pipefail:
                        result.gate_piped = True
                    if hides_status(commands, k):
                        result.gate_hidden = True
        pipefail, followed = pipefail_after(cmd, pipefail, followed)
        # Leaving a subshell (`(cd x)`, `(cd x; a)`) restores where its
        # `(` was entered.
        out = max(leads_on(cmd)[1] or 0, 0)
        if out < depth:
            moved, here = entered.get(out + 1, (moved, here))
            depth = out
    if moved:
        for i in inner_ids:
            result.moved[i] = None
    return result


def cd_target(words):
    """Where a cd, pushd or popd goes, as written: its one operand (`~` for a
    bare cd), or True when that can't be read from the words (popd, `cd -`,
    `pushd +1`, a bare pushd, more than one operand)."""
    head = os.path.basename(words[0])
    if head == "popd":
        return True
    args = words[1:]
    while args and args[0] in ("-L", "-P", "-e", "-@", "-n"):
        args = args[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        return "~" if head == "cd" else True
    if len(args) != 1 or args[0] == "-" or (head == "pushd" and re.fullmatch(r"[+-]\d+", args[0])):
        return True
    return args[0]


def moved_to(here, target):
    """The directory a cd to target (cd_target) from here leads to, or None
    when it can't be told: an expansion or glob in it, a relative target
    from an unknown directory or one CDPATH may resolve, or a directory that
    doesn't exist (the cd fails, and after `;` the next command runs where
    it was)."""
    if target is True or "$" in target or PLACEHOLDER in target or re.search(r"[*?\[]", target):
        return None
    target = os.path.expanduser(target)
    if not os.path.isabs(target):
        if here is None or (os.environ.get("CDPATH") and not target.startswith(".")):
            return None
        target = os.path.join(here, target)
    return target if os.path.isdir(target) else None


def hides_status(commands, k):
    """Whether a command after commands[k] that `||`, `;`, a newline or `&`
    leads to runs last, or a `&` backgrounds commands[k]'s list, so the
    call's status may not be commands[k]'s.
    Only operators at the gate's own nesting level count, and, once the
    gate is the last command of its group or subshell, those at the level
    that closes into: what a `&&` leads to may hold any operators inside
    (`gate && { a; b; }`), and `{ gate; } && x` keeps the gate's status.
    For a command a `)` ends, the operator after the closers counts."""
    if commands[k].ended_by == "&":
        # Backgrounded at any depth (`(gate &) && x`): its status is lost.
        return True
    levels, closes, after = nesting(commands)
    current = levels[k]
    for j in range(k, len(commands)):
        op = leads_on(commands[j])[0]
        if after[j] > current:
            # Inside a compound command a `&&` (or the gate's own group) led
            # to: its status is the compound's, decided at its closer.
            continue
        current = after[j]
        if op == "&":
            # Backgrounded at the gate's level, last or not: the call's
            # status is 0 whatever the gate's is.
            return True
        if op not in ("||", ";", "\n") or j + 1 == len(commands):
            continue
        nxt = j + 1
        if closes[nxt] and levels[nxt] == current:
            # The gate's group ends here: its status is the gate's.
            continue
        if any(c.words and not (len(c.words) == 1 and c.words[0] in GROUP_CLOSERS)
               for c in commands[nxt:]):
            return True
    return False


GROUP_OPENERS = ("{", "if", "while", "until", "for", "case", "select")

# Reserved words after which the next word is again in command position, so
# may open a compound command (`then if`, `do {`, `! {`).
COMMAND_PREFIXES = ("then", "do", "else", "elif", "!", "time")


def openers(words):
    """The compound commands a command's words open: each opener in command
    position, at its start or after a reserved word or another opener
    (`then if true`, `{ { a`). A `for`, `case` or `select` is followed by a
    name, not a command."""
    found = []
    for w in words:
        if w in GROUP_OPENERS:
            found.append(w)
            if w in ("for", "case", "select"):
                break
        elif w not in COMMAND_PREFIXES:
            break
    return found


def nesting(commands):
    """For each command: (its nesting level, by `(` and the compound
    commands around it; whether it is a lone `}`, `done`, `fi` or `esac`;
    the level of the operator after it, outside what it closes). Each
    opener in command position is pushed and each closer pops one."""
    levels, closes, after = [], [], []
    stack = []
    for cmd in commands:
        stack.extend(openers(cmd.words))
        closer = len(cmd.words) == 1 and cmd.words[0] in GROUP_CLOSERS
        levels.append(cmd.depth + len(stack))
        closes.append(closer)
        if closer and stack:
            stack.pop()
        after.append(leads_on(cmd)[1] + len(stack))
    return levels, closes, after


def leads_on(cmd):
    """(the operator after cmd, the `(` depth it sits at). For a command a
    `)` closes (`(a)`, `(a;)`), that is the operator after the closers."""
    if cmd.ended_by == ")" or cmd.closed_by is not None:
        return cmd.closed_by, cmd.closed_depth
    return cmd.ended_by, cmd.depth


SEQUENCE_OPS = (";", "\n", "&&", "||", "&")


def in_pipeline(commands, k):
    """Whether commands[k]'s status goes into a pipe: it, or a group or
    subshell around it, is a stage of a pipeline (`gate | tail`,
    `{ gate; } | cat`, `(a; gate) | tail`). After a sequence operator at a
    level, a pipe at that level or inside belongs to another pipeline
    (`gate && { a; } | cat`, `gate; b | c`) until a closer takes it out."""
    _, _, after = nesting(commands)
    blocked = None
    for j in range(k, len(commands)):
        op, level = leads_on(commands[j])[0], after[j]
        if blocked is not None:
            if level >= blocked:
                continue
            blocked = None
        if op in ("|", "|&"):
            return True
        if op in SEQUENCE_OPS:
            blocked = level
    return False


def scan(body):
    """A body something may run, analysed as a script for the deny checks
    (nothing, when it doesn't parse as one). A script in another language
    runs commands from its strings (`system('git push -f')`), so the body
    and each string in it are also read roughly, into .rough, which is
    checked for forbidden commands and deny rules only."""
    try:
        result = analyse(body)
    except (Unparsable, RecursionError):
        result = Unwrapped()
    texts = [body] + [a or b for a, b in re.findall(r"'([^'\n]*)'|\"([^\"\n]*)\"", body)]
    result.rough = [normalize_git_loosely(w) for t in texts for w in rough_words(t)]
    return result


def pipefail_after(cmd, pipefail, followed):
    """(whether pipefail is on in the calling shell after cmd, whether the
    commands after cmd can still be followed for it). A `set` turning it on
    counts only as a plain command the shell is sure to run before what
    follows: first in the text or after `;` or a newline, at the top level,
    not piped or in the background, and before any compound command or
    subshell. Any other mention of pipefail (`set +o pipefail`, a set this
    doesn't count) turns it off."""
    words = cmd.words
    if cmd.depth or (words and (words[0] in RESERVED or words[0] in UNFOLLOWED)) or cmd.after in ("(", ")"):
        followed = False
    if not words:
        return pipefail, followed
    if (followed and words[0] == "set" and turns_on_pipefail(words) and not cmd.expands
            and not any(w.startswith("+") for w in words[1:])
            and cmd.after in (None, ";", "\n") and cmd.ended_by not in ("|", "|&", "&")):
        return True, followed
    if any(re.search(r"pipe_?fail", w, re.I) for w in words):
        return False, followed
    return pipefail, followed


def expand_braces(word, limit=64):
    """A word's brace expansions (`{--force,}` is `--force`), as bash makes
    them; empty results dropped. An empty word (`''`, `""`) is kept, as the
    shell keeps it, so both readers see the same arguments. More than limit
    can't be followed."""
    if word == "":
        return [""]
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
    # Whether the command left is run by its own name, as a function of that
    # name would be: only reserved words and assignments came before it.
    direct, seen_wrapper = True, False
    # A wrapper changed directory first (`env -C`, `sudo -D`).
    chdir = False
    while words:
        head = os.path.basename(words[0])
        if head in RESERVED:
            i = 1
            while head == "time" and i < len(words) and words[i].startswith("-"):
                i += 1
            words, result.opaque = words[i:], True
            continue
        elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words, result.wrapped, result.opaque = words[1:], True, True
            continue
        direct = not seen_wrapper
        if head in UNFOLLOWED:
            # The words after these aren't one command; check each word as
            # the start of one, so a forbidden command is still found.
            result.opaque = True
            for k in range(1, len(words)):
                result.commands.append(normalize_git(words[k:]))
            return result
        elif head == "env":
            i = 1
            while i < len(words):
                w = words[i]
                if w in ("-C", "--chdir") or w.startswith(("--chdir=", "-C")):
                    chdir = True
                if w in ("-u", "--unset", "-C", "--chdir", "-P"):
                    i += 2
                elif w in ("-S", "--split-string") or w.startswith("--split-string=") or (
                        w.startswith("-S") and len(w) > 2):
                    script = (w.split("=", 1)[1] if w.startswith("--split-string=")
                              else w[2:] if w.startswith("-S") and len(w) > 2 else "")
                    rest = words[i + 1:]
                    result.wrapped = result.opaque = True
                    result.add(moved_by(chdir, analyse(" ".join(([script] if script else []) + rest))),
                               direct=False)
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
                if words[i].startswith(("-D", "--chdir")):
                    chdir = True
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
                        result.add(moved_by(chdir, unwrap(words[k + 1:end])), direct=False)
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
            # eval runs in this shell, where its functions are defined.
            result.add(moved_by(chdir, analyse(script)), direct=head == "eval")
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
                result.add(moved_by(chdir, analyse(value)), direct=False)
            words, result.wrapped = words[i:], True
        elif head == "cd" or head == "pushd" or head == "popd":
            # Later commands run somewhere else, so their rules and paths
            # no longer mean what they say.
            result.opaque = True
            # Through a wrapper that changed directory, it starts elsewhere.
            result.moves = True if result.moves or chdir else cd_target(words)
            return result
        else:
            break
        seen_wrapper = True
    if words:
        result.commands.append(normalize_git(words))
        if direct:
            result.direct.add(id(result.commands[-1]))
        if chdir:
            result.moved[id(result.commands[-1])] = None
    return result


def moved_by(chdir, sub):
    """sub, with each of its commands marked as starting in an unknown
    directory when a wrapper (`env -C`, `sudo -D`) changed directory
    before running it."""
    if chdir:
        for w in sub.commands:
            sub.moved[id(w)] = None
    return sub


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


class GitWords(list):
    """git's words with its global options removed, remembering a `-C`
    dropped for naming the cwd (dropped_dir): after a cd it names a
    directory of its own (see git_place)."""
    dropped_dir = None


def normalize_git(words):
    """git with its global options removed."""
    if os.path.basename(words[0]) != "git":
        return words
    i = 1
    seen_dir = False
    dropped = None
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        name, _, inline = w.partition("=")
        if name in ("-c", "--config-env") or w.startswith("-c") or name in GIT_RELOCATING:
            # Configuration can make any subcommand run anything (aliases,
            # pagers, diff drivers, includes, push.mirror...).
            raise Unparsable(f"git {w}")
        if name in GIT_VALUE_FLAGS:
            value = inline or (words[i + 1] if i + 1 < len(words) else "")
            if seen_dir or (value not in (".", "./") and not same_checkout(value)):
                # Possibly another repository, whose own configuration (a
                # pager, an fsmonitor) runs: no rule covers that. Dropped only
                # for `.` or, at the top of a checkout, that checkout's own
                # top, where git reads relative arguments from the same
                # directory the guard does. A second `-C` is relative to the
                # first: none is dropped then.
                return words
            seen_dir, dropped = True, value
            i += 1 if inline else 2
        elif w in GIT_FLAGS:
            i += 1
        else:
            # An unknown global option: keep it, so nothing below mistakes
            # it for a subcommand.
            return words
    out = GitWords(["git"] + words[i:])
    out.dropped_dir = dropped
    return out


def same_checkout(value):
    """Whether a `git -C` value names the directory the command already runs
    in, when that is the top of the project or of one of its own worktrees.
    Another checkout's top is kept: git would read the command's relative
    arguments from there, and the guard reads them from the cwd."""
    cwd = WORKING["cwd"]
    if not cwd or not WORKING["root"] or not at_top():
        return False
    here = os.path.realpath(cwd)
    return os.path.realpath(value if os.path.isabs(value) else os.path.join(cwd, value)) == here


def long_option(arg, option, shortest):
    """Whether arg is option or an abbreviation git would accept for it."""
    name = arg.split("=", 1)[0]
    return len(name) >= shortest and option.startswith(name)


# git commit's short options whose value can take the rest of the word.
COMMIT_VALUED = "mFCctSu"

# git tag's short options whose value can take the rest of the word.
TAG_VALUED = "mFun"

# git fetch's long options whose value can be the next word.
FETCH_SPLIT_VALUED = ("--filter", "--server-option", "--depth", "--deepen", "--shallow-since",
                      "--shallow-exclude", "--negotiation-tip", "--jobs")


def git_short(arg, letters, valued):
    """Whether a git short option cluster holds one of letters before any
    letter in valued, whose value takes the rest of the word (`commit
    -mdocs` is -m with `docs`, not -c)."""
    if not re.match(r"^-[A-Za-z0-9]", arg):
        return False
    for c in arg[1:]:
        if c in letters:
            return True
        if c in valued or not c.isalnum():
            return False
    return False


def git_option(arg, option):
    """Whether arg could be git's long option, for refusing it: git takes
    any unique prefix, one letter after `--` included (`reset --h` is
    `--hard`), and an ambiguous one fails, so every such prefix counts."""
    return long_option(arg, option, 3)


def program(word):
    """A command word's program name: `wrangler@4`, `@scope/wrangler` and
    `node_modules/.bin/wrangler.js` are wrangler."""
    name = os.path.basename(word)
    name = name.split("@", 1)[0] if not name.startswith("@") else name[1:].split("@", 1)[0]
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
                if a.startswith("--force") or git_option(a, "--force"):
                    return "force push"
                if git_option(a, "--mirror"):
                    return "push --mirror"
                if re.match(r"^-[A-Za-z0-9]*f[A-Za-z0-9]*$", a):
                    return "force push"
                if a.startswith("+") or ":+" in a:
                    return "force push (+refspec)"
        if sub == "reset" and any(git_option(a, "--hard") for a in rest):
            return "git reset --hard"
    if head == "wrangler" and "--dry-run" not in args:
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
        sub = gh_subcommand(lowered)
        if sub == ("pr", "merge"):
            return "gh pr merge with your credentials skips review; the App merges approved PRs"
        if sub == ("pr", "review") and approves(args):
            return "approving with your credentials stands in for your review"
        if sub and sub[0] == "alias":
            return "gh aliases could hide a merge or an approval"
        if sub and sub[0] == "api":
            if api_changes_review(lowered):
                return "merging or reviewing through gh api with your credentials"
            text = " ".join(lowered)
            if "--input" in text or "=@" in text or re.search(r"(^| )@", text):
                raise Unparsable("gh api reading its request from a file")
    if head == "gh-app":
        # The App may merge a PR the developer team approved, but it must not
        # approve one: where the ruleset's file patterns miss a path, its
        # approval would count. It merges only through `gh-app pr merge`,
        # whose wrapper checks the PR first (the App's own, not a draft, the
        # ruleset, the head it was asked to merge); the API would skip that.
        lowered = [a.lower() for a in args]
        sub = gh_subcommand(lowered)
        if sub and sub[0] == "alias":
            return "gh-app aliases could hide an approval"
        if sub == ("pr", "review") and approves(args):
            return "the App approving a PR"
        if sub and sub[0] == "api":
            text = " ".join(lowered)
            if api_changes_review(lowered):
                return "the App merging or reviewing through gh-app api; merge with gh-app pr merge, which checks the PR first"
            if "--input" in text or "=@" in text or re.search(r"(^| )@", text):
                raise Unparsable("gh-app api reading its request from a file")
    return None


def gh_subcommand(lowered):
    """gh's command and subcommand, past global flags: ("pr", "merge")."""
    words = []
    k = 0
    while k < len(lowered) and len(words) < 2:
        a = lowered[k]
        if a in ("-r", "-R", "--repo", "--hostname"):
            k += 2
            continue
        if not a.startswith("-"):
            words.append(a)
        k += 1
    return tuple(words) or None


def approves(args):
    return any(a.startswith("--approve") or re.match(r"^-[A-Za-z]*a[A-Za-z]*$", a) for a in args)


def api_changes_review(lowered):
    """Whether a gh api call approves or merges a PR, rather than reading
    one."""
    text = " ".join(lowered)
    # addPullRequestReviewThreadReply only answers a comment thread, so the
    # review prefix doesn't catch it.
    if re.search(r"event=approve|approvepullrequest|addpullrequestreview(?!thread)", text):
        return True
    if re.search(r"mergepullrequest|enablepullrequestautomerge", text):
        return True
    writes = re.search(r"(^| )(-x|--method)[ =]?(post|put|patch)", text) or re.search(r"(^| )-[fF] ", text)
    return bool(writes and (re.search(r"/pulls/[^/ ]+/merge", text) or "/reviews" in text))


def names_file(word):
    """Whether a command word could name a file rather than mention one, as
    a search pattern does (`grep -rn '.env' src`): a redirect, a path, a glob,
    or a name that exists. Where the cwd is unknown, every word counts."""
    cwd = WORKING["cwd"]
    if word.startswith(">"):
        return True
    # A phrase, like a PR title, mentions a file rather than naming one.
    if re.search(r"\s", word):
        return False
    if not cwd or "/" in word or re.search(r"[*?\[{]", word):
        return True
    return any(os.path.lexists(os.path.join(cwd, c)) for c in option_values(word) if c)


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
    path from the cwd, or None when there is no cwd. A path in one of the
    project's own worktrees outside the root is inside the project, relative
    to that worktree. realpath resolves whatever prefix exists, so a link on
    the way to a path not yet created counts too."""
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
    top = checkout_of(resolved)
    if top is not None and top != base:
        return resolved, "." if resolved == top else os.path.relpath(resolved, top)
    return resolved, None


# Set by decide: where the command runs, and the project it may stay in.
WORKING = {"cwd": None, "root": None}


def scratch(path):
    """Whether a path is in a temporary directory, where a session keeps its
    scratch files (a commit message, a diff's other side)."""
    if not path.startswith("/"):
        return False
    real = os.path.realpath(path)
    roots = {"/tmp", "/private/tmp", "/private/var/folders"}
    if os.environ.get("TMPDIR"):
        roots.add(os.path.realpath(os.environ["TMPDIR"]))
    return any(real == r or real.startswith(r.rstrip("/") + "/") for r in roots)


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
    """Whether the command runs outside every checkout of the project: its
    root, one of its own worktrees, or a subdirectory of either with no other
    repository on the way. Elsewhere a relative program is another file, and
    git or gh-app may find another repository, with its own config, in ways
    too many to list (a nested .git, a bare layout, another commondir)."""
    cwd, root = WORKING["cwd"], WORKING["root"]
    if not cwd or not root:
        return False
    return checkout_of(cwd) is None


def at_top():
    """Whether the command runs at the project root or the top of one of its
    own worktrees, wherever that sits, where a relative program is the file
    the rule means."""
    cwd, root = WORKING["cwd"], WORKING["root"]
    if not cwd or not root:
        return True
    return checkout_of(cwd) == os.path.realpath(cwd)


def checkout_of(path):
    """The top of the project's checkout a path is in: the root, or one of
    its own worktrees in either place they sit (see own_worktree). None when
    the first `.git` on the way up belongs to anything else (a nested
    repository, another repository's worktree, a look-alike, a worktree
    elsewhere), or when there is none. When the root is itself one of the
    project's worktrees, the others are found from the main checkout (#65,
    see project_base), and the main checkout is then not one of the
    session's checkouts. Remembered per guard call (decide clears it), by
    real path and root."""
    real = os.path.realpath(path)
    base = os.path.realpath(WORKING["root"] or WORKING["cwd"])
    key = (real, base)
    if key not in CHECKOUTS:
        CHECKOUTS[key] = _checkout_of(real, base, project_base(base))
    return CHECKOUTS[key]


# checkout_of's answers in this guard call, by (real path, root), and
# project_base's under (None, root), a key no path makes.
CHECKOUTS = {}


def _checkout_of(real, base, project):
    while True:
        if real == base:
            return base
        if os.path.lexists(os.path.join(real, ".git")):
            return real if own_worktree(real, project, base) else None
        parent = os.path.dirname(real)
        if parent == real:
            return None
        real = parent


def own_worktree(here, project, root):
    """Whether here is the top of one of the project's own git worktrees,
    in one of the places they are made: `<project>/.claude/worktrees/<name>`
    (EnterWorktree), also `<root>/.claude/worktrees/<name>` when the
    session's root is itself a linked worktree, or beside the project in
    `<project>.worktrees/<name>` (a WorktreeCreate hook). Its `.git` file
    names a directory under the project's `.git/worktrees`, which names it
    back, and whose commondir is the project's `.git`. Paths in those files
    may be relative: git reads the `.git` file's against the worktree, the
    others against the gitdir."""
    here = os.path.realpath(here)
    places = {os.path.realpath(os.path.join(project, ".claude", "worktrees")),
              os.path.realpath(os.path.realpath(project) + ".worktrees"),
              os.path.realpath(os.path.join(root, ".claude", "worktrees"))}
    if os.path.dirname(here) not in places:
        return False
    dirs = linked_git_dirs(here)
    if dirs is None:
        return False
    gitdir, common = dirs
    if os.path.dirname(gitdir) != os.path.realpath(os.path.join(project, ".git", "worktrees")):
        return False
    try:
        with open(os.path.join(gitdir, "gitdir")) as f:
            if os.path.realpath(os.path.dirname(os.path.join(gitdir, f.read().strip()))) != here:
                return False
    except (OSError, ValueError):
        return False
    return common == os.path.realpath(os.path.join(project, ".git"))


def linked_git_dirs(top):
    """(gitdir, common dir), by their real paths, that the `.git` file at
    the top of a linked worktree names: its `gitdir:` line, read against the
    worktree, and that gitdir's `commondir`, read against the gitdir. None
    when top's `.git` is no such file, or one it can't read (not UTF-8, a
    NUL in a path): project_base reads the root's on every call."""
    try:
        with open(os.path.join(top, ".git")) as f:
            m = re.match(r"gitdir: (.+)", f.read().strip())
        if not m:
            return None
        gitdir = os.path.realpath(os.path.join(top, m.group(1)))
        with open(os.path.join(gitdir, "commondir")) as f:
            return gitdir, os.path.realpath(os.path.join(gitdir, f.read().strip()))
    except (OSError, ValueError):
        return None


def linked_main(top):
    """The main checkout that the `.git` file at the top of a linked
    worktree names: the parent of its gitdir's common dir, when that is a
    directory named `.git`. None otherwise (no such file, no commondir, a
    bare repository's worktree)."""
    dirs = linked_git_dirs(top)
    if dirs is None:
        return None
    common = dirs[1]
    if os.path.basename(common) != ".git" or not os.path.isdir(common):
        return None
    return os.path.dirname(common)


def project_base(base):
    """The directory the project's own worktrees are found from: base, the
    real path of the session's root, or the main checkout when base is a
    linked worktree, read from `<base>/.git` and its gitdir's commondir
    (the common dir's parent, when it is a directory named `.git`). The
    root is taken at its word, as git takes it: a root elsewhere, or one
    whose commondir names another repository, finds its siblings from that
    repository's checkout. Each sibling is still checked against the answer
    by own_worktree. Only `<base>/.git` is read, never a directory above,
    as devenv.nix's mainCheckout reads it. For a root that is not a linked
    worktree (the main checkout, a submodule, a worktree with no commondir,
    a bare repository's worktree, no repository) it is base. Remembered in
    CHECKOUTS under (None, base)."""
    key = (None, base)
    if key not in CHECKOUTS:
        CHECKOUTS[key] = linked_main(base) or base
    return CHECKOUTS[key]


# What a branch switch in the project's main checkout is told (#88).
MAIN_CHECKOUT = "Branch work goes in a worktree: EnterWorktree, or isolation: \"worktree\" on a subagent (git.md)."


def repo_top(path):
    """The first directory at or above path, by its real path, that has a
    `.git` entry: the top of the working tree git would use there. None
    when there is none."""
    real = os.path.realpath(path)
    while True:
        if os.path.lexists(os.path.join(real, ".git")):
            return real
        parent = os.path.dirname(real)
        if parent == real:
            return None
        real = parent


def main_checkout():
    """The project's main checkout: the working tree whose `.git` is the
    repository's own directory, not a linked worktree's `.git` file. Found
    from the project root, which is itself a linked worktree when a session
    starts in one (#65): its `.git` file names a gitdir whose commondir is
    `<main>/.git`. Paths in those files may be relative, read as git reads
    them (see own_worktree). None when there is no repository, or its
    common directory isn't a checkout's `.git` (a bare repository)."""
    top = repo_top(WORKING["root"] or WORKING["cwd"])
    if top is None:
        return None
    if os.path.isdir(os.path.join(top, ".git")):
        return top
    return linked_main(top)


def packed_refs(gitdir):
    """The ref names in a repository's packed-refs file."""
    try:
        with open(os.path.join(gitdir, "packed-refs")) as f:
            return {parts[1] for parts in (line.split() for line in f)
                    if len(parts) == 2 and not parts[0].startswith(("#", "^"))}
    except OSError:
        return set()


def has_ref(gitdir, ref, packed):
    """Whether ref (`refs/heads/main`) exists, loose or packed."""
    return os.path.isfile(os.path.join(gitdir, ref)) or ref in packed


def default_branch(main):
    """The repository's default branch: the one `origin/HEAD` names, else
    whichever of main and master exists, else main."""
    gitdir = os.path.join(main, ".git")
    try:
        with open(os.path.join(gitdir, "refs", "remotes", "origin", "HEAD")) as f:
            m = re.fullmatch(r"ref: refs/remotes/origin/(\S+)", f.read().strip())
        if m:
            return m.group(1)
    except OSError:
        pass
    packed = packed_refs(gitdir)
    for name in ("main", "master"):
        if has_ref(gitdir, f"refs/heads/{name}", packed):
            return name
    return "main"


def names_ref(gitdir, name):
    """Whether git would read name as a ref in this repository: a branch, a
    tag, a remote's branch (`origin/x`, or `x` that checkout would make a
    branch from), or a pseudo-ref such as ORIG_HEAD, loose or packed."""
    if not name or ".." in name or re.search(r"[\s~^:?*\[\\]", name):
        return False
    packed = packed_refs(gitdir)
    candidates = [f"refs/{name}", f"refs/tags/{name}", f"refs/heads/{name}",
                  f"refs/remotes/{name}", f"refs/remotes/{name}/HEAD"]
    if re.fullmatch(r"[A-Z_]+", name):
        candidates.append(name)
    if any(has_ref(gitdir, ref, packed) for ref in candidates):
        return True
    try:
        remotes = os.listdir(os.path.join(gitdir, "refs", "remotes"))
    except OSError:
        remotes = []
    if any(os.path.isfile(os.path.join(gitdir, "refs", "remotes", r, name)) for r in remotes):
        return True
    return any(ref.startswith("refs/remotes/") and ref.split("/", 3)[3:] == [name] for ref in packed)


def remote_branch(gitdir, name):
    """Whether name is a remote-tracking branch in this repository, loose or
    packed, in the spellings git takes (`origin/main`, `remotes/origin/main`,
    `refs/remotes/origin/main`, or a remote alone, which is its HEAD). A
    local branch of the same name isn't looked for, so such a name is
    over-reported."""
    if (not name or name.endswith("/") or ".." in name or "@{" in name
            or re.search(r"[\s~^:?*\[\\]", name)):
        return False
    packed = packed_refs(gitdir)
    prefix = "refs/remotes/"
    for ref in (prefix + name, "refs/" + name, name):
        if ref.startswith(prefix) and len(ref) > len(prefix) and (
                has_ref(gitdir, ref, packed) or has_ref(gitdir, ref + "/HEAD", packed)):
            return True
    return False


def git_place(words, start):
    """(the directory a git command runs in, its subcommand, the words after
    it), or None for another program or no subcommand. The directory is
    start (the call's cwd, or where a cd led) with each `-C` applied in
    turn, as git applies them, the one normalize_git dropped first; None
    when that can't be known: a `-C` holding an expansion, a relative one
    from an unknown start, or a global option this doesn't know."""
    if os.path.basename(words[0]) != "git":
        return None
    here = start
    dirs = [d for d in [getattr(words, "dropped_dir", None)] if d is not None]
    i = 1
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        if w in GIT_VALUE_FLAGS:
            dirs.append(words[i + 1] if i + 1 < len(words) else "")
            i += 2
        elif w in GIT_FLAGS:
            i += 1
        else:
            # normalize_git keeps an option it doesn't know, whose value
            # may be the next word.
            here = None
            i += 1
    for value in dirs:
        value = os.path.expanduser(value)
        if "$" in value or PLACEHOLDER in value or not value:
            here = None
        elif os.path.isabs(value):
            here = value
        elif here is not None:
            here = os.path.join(here, value)
    if i >= len(words):
        return None
    return here, words[i], words[i + 1:]


def leaves_branch(sub, args, default, here, gitdir):
    """How a `git switch` or `git checkout` with these arguments would take
    the checkout off its default branch, or None when it doesn't: it names
    no branch, names the default branch, HEAD or `@`, or only restores files
    (checkout with `--` and paths after it, a tree-ish and paths, `-p`, a
    pathspec file, or a single operand that is a glob or names a path in
    here and no ref in gitdir, since git prefers the ref). git takes any
    unique prefix of a long option, so every prefix counts, and short
    options may come in a cluster, where a value takes the rest of the
    word. here is None when where it runs is unknown: then only a glob
    counts as a path."""
    creates = "cC" if sub == "switch" else "bB"
    long_creates = ("--create", "--force-create", "--orphan") if sub == "switch" else ("--orphan",)
    long_valued = long_creates + ("--conflict",) + (("--pathspec-from-file",) if sub == "checkout" else ())
    operands, paths, restores = [], None, False
    k = 0
    while k < len(args):
        w = args[k]
        k += 1
        if paths is not None:
            paths.append(w)
        elif w == "--":
            # switch takes no paths: what follows is still its branch.
            if sub == "checkout":
                paths = []
        elif w.startswith("--"):
            if any(git_option(w, o) for o in long_creates):
                return "creates a branch"
            if git_option(w, "--detach"):
                return "detaches HEAD"
            if sub == "checkout" and (git_option(w, "--patch") or git_option(w, "--pathspec-from-file")):
                restores = True
            if "=" not in w and any(git_option(w, o) for o in long_valued):
                k += 1
        elif w.startswith("-") and w != "-":
            for c in w[1:]:
                if c in creates:
                    return "creates a branch"
                if c == "d":
                    return "detaches HEAD"
                if c == "p" and sub == "checkout":
                    restores = True
                if not c.isalnum():
                    break
        else:
            operands.append(w)
    if restores or paths:
        return None
    if not operands or operands[0] in (default, "HEAD", "@"):
        return None
    if sub == "checkout" and paths is None:
        if len(operands) > 1:
            # A tree-ish and the paths to take from it.
            return None
        target = operands[0]
        if re.search(r"[*?\[]", target) or (here is not None and os.path.lexists(os.path.join(here, target))
                                            and not names_ref(gitdir, target)):
            return None
    return f"checks out {operands[0]}"


def sets_upstream(sub, args, gitdir):
    """(the new branch or None, the start point or None) when a `git switch`
    or `git checkout` with these arguments would write tracking
    configuration, else None. It would when the last tracking option is
    `--track` (any prefix git takes) or `-t`; or, with no tracking option,
    when it creates a branch (`-c`, `-C`, `--create`, `--force-create`; `-b`,
    `-B` for checkout) from a start point that is a remote-tracking branch
    in gitdir. `--no-track` last, `--detach` and `--orphan` write none."""
    creates = "cC" if sub == "switch" else "bB"
    valued = ("--orphan", "--conflict") + (("--pathspec-from-file",) if sub == "checkout" else ())
    track, none_made, new, operands = None, False, None, []
    k = 0
    while k < len(args):
        w = args[k]
        k += 1
        if w == "--":
            # checkout's paths follow; switch takes none, so its branch does.
            if sub == "checkout":
                break
            continue
        if w.startswith("--"):
            name, eq, value = w.partition("=")
            if long_option(name, "--no-track", 6):
                track = False
            elif git_option(name, "--track"):
                track = True
            if git_option(name, "--detach") or git_option(name, "--orphan"):
                none_made = True
            if sub == "switch" and (git_option(name, "--create") or git_option(name, "--force-create")):
                if eq:
                    new = value
                elif k < len(args):
                    new = args[k]
                    k += 1
                continue
            if not eq and any(git_option(name, o) for o in valued):
                k += 1
        elif w.startswith("-") and w != "-":
            for i, c in enumerate(w[1:], 1):
                if c in creates:
                    # The new branch's name is the rest of the word, or the
                    # next word.
                    if w[i + 1:]:
                        new = w[i + 1:]
                    elif k < len(args):
                        new = args[k]
                        k += 1
                    break
                if c == "t":
                    track = True
                elif c == "d":
                    none_made = True
                elif not c.isalnum():
                    break
        else:
            operands.append(w)
    if none_made or track is False:
        return None
    start = operands[0] if operands else None
    if track:
        return new, start
    if new is not None and start is not None and remote_branch(gitdir, start):
        return new, start
    return None


def main_checkout_switch(result):
    """("deny", reason) when a `git switch` or `git checkout` in the call
    would take the project's main checkout off its default branch (#88):
    the directory it runs in, after any `-C`, is in the main checkout, not
    in a linked worktree or a nested repository. ("ask", reason) when such
    command runs where the guard can't tell (after a cd it can't follow, or
    through `env -C`), when no command of the call is denied. None
    otherwise, and when the cwd is unknown."""
    if not WORKING["cwd"]:
        return None
    main, unsure = None, None
    for words in result.commands:
        if not words or (id(words) in result.direct and words[0] in result.functions):
            continue
        start = result.moved.get(id(words), WORKING["cwd"])
        place = git_place(words, start)
        if place is None or place[1] not in ("switch", "checkout"):
            continue
        here, sub, args = place
        if main is None:
            main = main_checkout()
            if main is None:
                return None
            default = default_branch(main)
        change = leaves_branch(sub, args, default, here, os.path.join(main, ".git"))
        if change is None:
            continue
        if here is None:
            unsure = unsure or ("ask", (f"coldlogic guard: can't tell which checkout this git {sub} runs in. "
                                        f"Run it as its own call, from the directory it's for. {MAIN_CHECKOUT}"))
        elif repo_top(here) == main:
            hint = (" To restore a file, use `git checkout -- <path>` or `git restore`."
                    if change.startswith("checks out") and sub == "checkout" else "")
            return "deny", (f"{MAIN_CHECKOUT} The main checkout stays on {default}, and "
                            f"`git {sub}` here {change}.{hint}")
    return unsure


def tracking_create(result):
    """("deny", reason) when a `git switch` or `git checkout` in the call
    would set up tracking (sets_upstream) in the project's repository: in
    the main checkout, or in a linked worktree whose common directory is
    the main checkout's `.git`. Tracking is written to the shared
    `.git/config`, which the sandbox protects, so the command would fail
    after creating the branch and before checking it out (#45). Nested and
    foreign repositories, and commands whose directory is unknown, are left
    alone. A deny-side check: it may over-report (a shadowing local branch,
    `branch.autoSetupMerge=false`), and only ever returns a deny or None."""
    if not WORKING["cwd"]:
        return None
    main = None
    for words in result.commands:
        if not words or (id(words) in result.direct and words[0] in result.functions):
            continue
        place = git_place(words, result.moved.get(id(words), WORKING["cwd"]))
        if place is None or place[1] not in ("switch", "checkout"):
            continue
        here, sub, args = place
        if here is None:
            continue
        if main is None:
            main = main_checkout()
            if main is None:
                return None
        top = repo_top(here)
        if top is None:
            continue
        if top != main:
            dirs = linked_git_dirs(top)
            if dirs is None or dirs[1] != os.path.realpath(os.path.join(main, ".git")):
                continue
        made = sets_upstream(sub, args, os.path.join(main, ".git"))
        if made is not None:
            new, start = made
            of = f" of {start}" if start else ""
            fix = f": `git switch --no-track -c {new} {start}`" if new and start else ""
            return "deny", (f"coldlogic guard: this `git {sub}` would set up tracking{of}, which writes "
                            f".git/config. The sandbox protects that file, so the command would fail "
                            f"partway. Add --no-track{fix}.")
    return None


def plain_args(words):
    """Whether no argument, or option value, points outside the project or
    names an output file, and the program isn't a path out of it."""
    if "/" in words[0] and (outside(words[0]) or not at_top()):
        # A relative program from a subdirectory is another file than the
        # rule's.
        return False
    prog = program(words[0])
    if prog == "git" and git_waits_or_drops(words):
        return False
    if prog in ("gh", "gh-app") and gh_opens_editor(words[1:]):
        return False
    text_options = text_options_of(prog, words)
    value_next = False
    for w in words[1:]:
        # A message, title or body (`git commit -m "-o is refused"`,
        # `gh-app issue comment 3 --body "-e is nice"`) is text, not an
        # option: the option before takes it whatever it holds. Only the
        # subcommands where that option takes text count (`git fetch -t` is
        # `--tags`). A word with whitespace isn't skipped for that alone: git
        # parses `"--upload-pack=a b"` as an option. A word that could name a
        # program for git to run is checked even as text, and so is one that
        # could name an output file (`-o`, `--output`) unless it holds
        # whitespace, as a sentence does (`git commit -m "-o is refused"`).
        text, value_next = value_next, not value_next and w in text_options
        if text and prog == "git" and (w.startswith("-c") or git_option(w, "--config")
                                       or (w.startswith(("-o", "--output"))
                                           and not any(c.isspace() for c in w))
                                       or git_option(w, "--config-env")
                                       or git_option(w, "--upload-pack")
                                       or git_option(w, "--receive-pack")
                                       or git_option(w, "--exec")):
            text = False
        # For any program: an output file, a list of paths, or configuration
        # that can name a program to run. Some programs take shorter
        # abbreviations (wc's `--f=`) or a short config flag (wrangler's -c,
        # whose build command runs). A word starting `-o` is refused (an
        # output file, ssh's options, unzip's overwrite) except where it is
        # known to do neither (`grep -o` prints the match); an `o` later in a
        # cluster (`-qo`) only for the programs in O_CLUSTER. Elsewhere it
        # may be another letter's value (`git status -uno`), a harmless flag
        # (`ls -lo`) or a single-dash long option (go's `-count=1`).
        if ((prog not in HARMLESS_O and not text
             and (w.startswith("-o") or (prog in O_CLUSTER and re.match(r"^-[A-Za-z0-9]*o", w))))
                or long_option(w, "--output", 5) or long_option(w, "--config", 5)
                or long_option(w, "--files0-from", 8)
                or (prog in ("wc", "sort", "du") and long_option(w, "--files0-from", 3))
                or (prog == "cargo" and long_option(w, "--config", 4))
                or (prog == "wrangler" and (re.match(r"^-[A-Za-z]*c", w) or long_option(w, "--config", 3)))
                # gh's jq and templates can read the environment, the App's
                # GH_TOKEN included.
                or (prog in ("gh", "gh-app") and reads_environment(words, w))):
            return False
        if prog == "cargo" and (w.startswith("-Z") or w.startswith("+")):
            return False
        if any(outside(c) and not scratch(c) for c in option_values(w)):
            return False
        if prog == "git" and long_option(w, "--pathspec-from-file", 7):
            # A file of pathspecs, whose names aren't checked.
            return False
        if prog == "git" and not text and git_runs_program(words[1:2], w):
            return False
        if (prog in ("gh", "gh-app") and not text
                and (w.startswith("--edit") or re.match(r"^-[A-Za-z]*e", w))):
            # An editor waits for a user who isn't there: `-e`, `--editor`,
            # `--edit-last`.
            return False
    return True


# The options whose next word is text (a message, title or body), by
# subcommand: git's by its subcommand, gh's by (command, subcommand).
GIT_TEXT_OPTIONS = {"commit": {"-m", "--message"}, "merge": {"-m", "--message"},
                    "notes": {"-m", "--message"}, "stash": {"-m", "--message"},
                    "tag": {"-m"}}
GH_TEXT_OPTIONS = {"-t", "--title", "-b", "--body"}
GH_TEXT_SUBCOMMANDS = {(c, s) for c in ("issue", "pr") for s in ("create", "edit", "comment")}


def text_options_of(prog, words):
    """The options of this git or gh command whose next word is text."""
    if prog == "git":
        sub = words[1] if len(words) > 1 else ""
        action = words[2] if len(words) > 2 else ""
        # stash list and show take log and diff options, where -m takes no
        # value; notes' other subcommands take no message.
        if sub == "stash" and not (action in ("", "push", "save") or action.startswith("-")):
            return set()
        if sub == "notes" and action not in ("add", "append"):
            return set()
        return GIT_TEXT_OPTIONS.get(sub, set())
    if prog in ("gh", "gh-app"):
        sub = gh_subcommand([a.lower() for a in words[1:]])
        return GH_TEXT_OPTIONS if sub in GH_TEXT_SUBCOMMANDS else set()
    return set()

# Programs whose -o only changes what they print (grep's only-matching) or
# sets a shell option (set -o pipefail, which set_options checks).
HARMLESS_O = {"grep", "egrep", "fgrep", "rg", "set"}
# Programs whose -o in a short cluster writes a file, overwrites, or takes a
# value that can run a program (`unzip -qo`, `ssh -4oProxyCommand=...`).
O_CLUSTER = {"unzip", "7z", "ssh", "scp", "sftp", "curl", "wget", "cc", "gcc", "clang",
             "sort", "mount"}


def gh_opens_editor(args):
    """Whether gh would open an editor for a body it isn't given: an issue
    or pull request created or commented on without one."""
    sub = gh_subcommand([a.lower() for a in args])
    if sub not in (("issue", "create"), ("pr", "create"), ("issue", "comment"), ("pr", "comment")):
        return False
    short = "bFf" if sub == ("pr", "create") else "bF"
    return not any(
        a.split("=", 1)[0] in ("--body", "--body-file", "--fill", "--fill-first", "--fill-verbose")
        or re.match(r"^-[A-Za-z]*[" + short + "]", a) for a in args)


def git_waits_or_drops(words):
    """Whether a whole git command opens an editor for a message it isn't
    given (a commit without -m, -F, -C, --no-edit or a plain --fixup; a
    `--fixup=reword:` or `amend:`; an annotated or signed tag without -m or
    -F), or a fetch can drop local work or refs
    (a forced or `+` refspec, a `:` refspec updating a local branch,
    `--update-head-ok`, `--prune`, `--prune-tags`, `--refmap`), or `git
    worktree add -B` resets a branch, or `git worktree remove` is forced in
    any spelling git accepts."""
    args = normalize_git_loosely(words)[1:]
    if not args:
        return False
    sub, rest = args[0], args[1:]
    if sub == "commit":
        given = False
        for k, w in enumerate(rest):
            if long_option(w, "--fixup", 5):
                value = w.split("=", 1)[1] if "=" in w else (rest[k + 1] if k + 1 < len(rest) else "")
                if value.startswith(("reword:", "amend:")):
                    return True
                given = True
            elif (git_short(w, "mFC", COMMIT_VALUED) or long_option(w, "--message", 5)
                  or long_option(w, "--file", 5) or long_option(w, "--no-edit", 6)
                  or long_option(w, "--reuse-message", 5)):
                given = True
        return not given
    if sub == "tag":
        # An annotated or signed tag (`-a`, `-s`, `-u`) with no -m or -F
        # opens an editor for its message.
        annotated = given = False
        for w in rest:
            if (git_short(w, "asu", TAG_VALUED) or git_option(w, "--annotate")
                    or git_option(w, "--sign") or git_option(w, "--local-user")):
                annotated = True
            if (git_short(w, "mF", TAG_VALUED) or long_option(w, "--message", 5)
                    or long_option(w, "--file", 5)):
                given = True
        return annotated and not given
    if sub == "fetch":
        operands, skip = [], False
        for w in rest:
            if skip:
                skip = False
                continue
            if w == "--":
                continue
            if (git_short(w, "fupP", "jo") or git_option(w, "--force")
                    or git_option(w, "--update-head-ok") or git_option(w, "--prune")
                    or git_option(w, "--prune-tags") or git_option(w, "--refmap")):
                return True
            # An option whose value is the next word: that word isn't an
            # operand. Only the full name, so an abbreviation that might
            # not take one leaves the next word an operand.
            skip = w in FETCH_SPLIT_VALUED or bool(re.match(r"^-[A-Za-z0-9]*[jo]$", w)
                                                    and not git_short(w[:-1], "jo", ""))
            if not w.startswith("-"):
                operands.append(w)
        # The first operand is the remote; a refspec after it with a `:`
        # updates a local ref, and a `+` forces it.
        return any(o.startswith("+") for o in operands) or any(":" in o for o in operands[1:])
    if sub == "worktree" and rest[:1] == ["add"]:
        # -B resets a branch that may already hold work, as `git branch -f`
        # does, alone or in a cluster (`-qB`).
        return any(git_short(w, "B", "b") for w in rest[1:])
    if sub == "worktree" and rest[:1] == ["remove"]:
        # A forced remove throws away the worktree's changes. The ask rules
        # name only the full spellings, and git takes `-f` in a cluster and
        # any prefix of `--force` (`--fo`).
        return any(git_short(w, "f", "") or git_option(w, "--force") for w in rest[1:])
    return False


def git_runs_program(sub, w):
    """Whether a git argument names a program for git to run (fetch's
    `--upload-pack`, push's `--receive-pack`, `--exec`, a transport helper
    URL that runs a command), or opens an editor or an interactive prompt,
    which waits for a user who isn't there. Fetch's `-u` is
    `--update-head-ok`, refused in git_waits_or_drops."""
    sub = sub[0] if sub else ""
    if (git_option(w, "--upload-pack") or git_option(w, "--receive-pack")
            or git_option(w, "--exec") or w.startswith(("ext::", "fd::"))):
        return True
    if git_option(w, "--edit-description") or git_option(w, "--interactive"):
        return True
    if sub == "commit" and (git_short(w, "ecp", COMMIT_VALUED) or git_option(w, "--edit")
                            or git_option(w, "--reedit-message") or git_option(w, "--patch")):
        return True
    if sub == "tag" and (git_short(w, "e", TAG_VALUED) or git_option(w, "--edit")):
        return True
    if sub == "add" and (re.match(r"^-[A-Za-z]*[iep]", w) or git_option(w, "--edit")
                         or git_option(w, "--patch")):
        return True
    return False


def reads_environment(words, w):
    """Whether a gh jq or template filter could read the environment (the
    App's GH_TOKEN): only on commands where -q and -t mean --jq and
    --template, and only if it mentions env."""
    k = words.index(w)
    value = w.split("=", 1)[1] if "=" in w else (words[k + 1] if k + 1 < len(words) else "")
    if long_option(w, "--jq", 4) or long_option(w, "--template", 4):
        return "env" in value.lower()
    lowered = [a.lower() for a in words[1:]]
    if (gh_subcommand(lowered) or ("",))[-1] in ("create", "edit", "comment") or lowered[:1] == ["api"]:
        return False
    return bool(re.match(r"^-[A-Za-z]*[qt]", w)) and "env" in value.lower()


# A template to copy from, which holds no secrets: `.env.example`,
# `.env.local.example`, `.env.dist`.
TEMPLATE = re.compile(r"[-_.](example|sample|template|dist)$")

# Programs that only mention the files they are given. Any other that names
# a secrets file is taken to read or write it.
SECRET_MENTIONS = {"ls", "test", "[", "[[", "echo", "printf", "stat"}


def secret_named(words):
    """The word by which a command names a secrets file in a way that could
    read or write it, or None."""
    prog = program(words[0])
    if prog == "git" and normalize_git_loosely(words)[1:2] == ["grep"]:
        # `git grep` takes its pattern as grep does.
        words, prog = normalize_git_loosely(words)[1:], "grep"
    found = None
    pattern_seen = False
    for k, w in enumerate(words):
        if w.startswith(">"):
            if secret_path(w):
                return w
            continue
        if k == 0:
            continue
        # grep's first operand is its pattern, unless -e or -f gives one.
        if prog in ("grep", "rg") and not pattern_seen and not w.startswith("-"):
            pattern_seen = True
            if not any(x in ("-e", "-f") or x.startswith(("--regexp", "--file")) for x in words[1:k]):
                continue
        if names_file(w) and secret_path(w):
            found = found or w
    if not found:
        return None
    if prog in SECRET_MENTIONS:
        return None
    first = next((w for w in words[1:] if not w.startswith("-")), None)
    if prog == "git" and normalize_git_loosely(words)[1:2] in (["rm"], ["check-ignore"]):
        return None
    # wrangler reads .dev.vars itself; pointing it at one is ordinary.
    if prog == "wrangler" and first == "dev":
        return None
    return found


def names_secret(path):
    """Whether a path names a secrets file. Case is folded as macOS's
    filesystem folds it (`ſ` is `s`). git pathspec magic (`:(glob)x`, `:/x`,
    `:!x`) and a revision (`HEAD:x`) are looked through."""
    if ":" in path and not path.startswith(":") and names_secret(path.split(":", 1)[1]):
        return True
    # Pathspec magic: `:(top)x`, `:/x`, `:!x`, `:/:x`, `::x`; and an index
    # stage, `:0:x`.
    path = re.sub(r"^:([0-3]:|\([^)]*\)|[/!^]*:?)", "", path)
    if path.startswith(":"):
        return names_secret(path)
    path = unicodedata.normalize("NFKC", path).casefold()
    if not path:
        return False
    name = os.path.basename(path.rstrip("/"))
    for secret in SECRET_NAMES:
        if name == secret or (name.startswith(secret + ".") and not TEMPLATE.search(name)):
            return True
    # Other spellings of an env file: .env-production, .env_local.
    if re.match(r"^\.env[-_].+$", name) and not TEMPLATE.search(name):
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


def claude_config(path):
    """Whether a path inside the project is in a `.claude` directory, other
    than inside one of its worktrees (`.claude/worktrees/<name>/...`), which
    are checkouts of the project. A path is judged by where it leads and,
    when it is itself a link, by where it sits (its directory resolved, its
    own name kept), so a file linked in `.claude` counts wherever it leads:
    devenv's settings.json is a link into the Nix store. A linked directory
    above the last component is judged only by where it leads."""
    views = []
    where = resolve(path)
    if where is not None and where[1] is not None:
        views.append(where[1])
    literal = os.path.expanduser(path).rstrip("/")
    head, name = os.path.split(literal)
    cwd = WORKING["cwd"]
    if cwd and name not in ("", ".", "..") and os.path.islink(os.path.join(cwd, literal)):
        parent = resolve(head)
        if parent is not None and parent[1] is not None:
            views.append(os.path.normpath(os.path.join(parent[1], name)))
    for inside in views:
        parts = unicodedata.normalize("NFKC", inside).casefold().split(os.sep)
        i = 0
        while i < len(parts):
            if parts[i] == ".claude":
                if parts[i + 1:i + 2] == ["worktrees"] and len(parts) > i + 3:
                    i += 3
                    continue
                return True
            i += 1
    return False


def rule_regex(rule, widen=False):
    if rule == "*":
        return re.compile(r"[\s\S]*\Z")
    return _rule_regex(rule, widen)


def _rule_regex(rule, widen=False):
    """A Bash permission rule as a regex. `*` matches anything but a
    newline (matches() turns one inside a parsed word into text); a trailing ` *` is optional when it's the rule's only wildcard.
    The older `cmd:*` form means `cmd *`, or, for an ask or deny rule
    (widen), any command starting with `cmd`."""
    if rule.endswith(":*"):
        if widen:
            return re.compile(re.escape(rule[:-2]) + r"[^\n]*\Z")
        rule = rule[:-2] + " *"
    if rule.count("*") == 1 and rule.endswith(" *"):
        return re.compile(re.escape(rule[:-2]) + r"( [^\n]*)?\Z")
    return re.compile("[^\n]*".join(re.escape(p) for p in rule.split("*")) + r"\Z")


def inner_rules(rules):
    """The inner command of each rule written with the devenv wrapper
    (`devenv shell --quiet -- gh-app issue create *` gives `gh-app issue
    create *`), when that command's program is named outright."""
    out = []
    for rule in rules:
        m = re.match(r"devenv shell(?: --quiet| -q)? -- (\S.*)\Z", rule, re.S)
        if m and "*" not in m.group(1).split()[0]:
            out.append(m.group(1))
    return out


def matches(rules, words):
    """Whether a rule matches the words. A program word holding whitespace
    (`"git status x/evil"` runs a file of that name) matches nothing."""
    if re.search(r"\s", words[0]):
        return False
    # A quoted argument may span lines (a PR body). The words are already
    # parsed, so a newline in one is text that a rule's `*` covers, for every
    # kind of rule alike. A stand-in no rule spells, so an exact rule
    # (`git push origin main`) doesn't match `git push "origin\nmain"`.
    text = " ".join(words).replace("\n", "\0")
    return any(r.match(text) for r in rules)


def read_only(words):
    """Whether this is a READ_ONLY command reading only inside the project."""
    if words[0] not in READ_ONLY:
        return False
    if any(PLACEHOLDER in a for a in words[1:]):
        # Its arguments are another command's output.
        return False
    prog, args = words[0], words[1:]
    if prog == "grep" and any(re.match(r"^-[A-Za-z0-9]*[rRdf]", a) or a.startswith("--r")
                              or a.startswith("--d") or a.split("=", 1)[0] == "--file"
                              or long_option(a, "--exclude-from", 10) for a in args):
        # -f/--file reads its patterns from a file, which could be a secrets
        # file the path check never sees as one.
        return False
    if prog == "printf" and any(a.startswith("-v") for a in args):
        # Assigns a shell variable (PATH...) that later commands run with.
        return False
    if prog == "sort" and sort_operands(args) is None:
        return False
    if prog == "uniq":
        operands = uniq_operands(args)
        if operands is None or len(operands) > 1:
            # A second operand is the file it writes.
            return False
    if prog == "tail" and any(re.match(r"^[-+][A-Za-z0-9]*[fF]", a) or long_option(a, "--follow", 3)
                              or long_option(a, "--retry", 3) for a in args):
        # Following a file never ends: the call would hang.
        return False
    if prog == "jq" and any(
            re.search(r"env|import|include", a, re.I)
            or re.match(r"^-[A-Za-z]*[fL]", a)
            or long_option(a, "--from-file", 3) or long_option(a, "--library-path", 3)
            for a in args):
        # jq can read the environment ($ENV, env: the App's GH_TOKEN) and load
        # modules and filters from files.
        return False
    if prog == "set" and not set_options(args):
        return False
    return True


def listed_options(args, flags, valued, long_flags, long_valued, end_ok):
    """The operands of a command whose options must all be on a list, or
    None when one isn't: an option not listed may name a program or a file
    to read or write without the path showing (`sort --files0-from=list`,
    `--random-source`, `-o`). flags are short options alone or in a cluster;
    valued short options take the rest of the word or the next one; long
    options are matched exactly, long_valued with `=value` or the next
    word. end_ok: whether `--` may end the options."""
    operands = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            if not end_ok:
                return None
            operands.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            if name in long_valued:
                i += 1 if "=" in a else 2
                continue
            if name not in long_flags or ("=" in a and not long_flags[name]):
                return None
            i += 1
            continue
        if a.startswith("-") and a != "-":
            for k, c in enumerate(a[1:], 1):
                if c in valued:
                    if k == len(a) - 1:
                        i += 1
                    break
                if c not in flags:
                    return None
            i += 1
            continue
        operands.append(a)
        i += 1
    return operands


def sort_operands(args):
    """sort's operands, or None for an option this doesn't approve."""
    return listed_options(
        args, "nrufbhVsz", "kt",
        {"--numeric-sort": False, "--reverse": False, "--unique": False, "--ignore-case": False,
         "--ignore-leading-blanks": False, "--human-numeric-sort": False, "--version-sort": False,
         "--stable": False, "--zero-terminated": False},
        {"--key", "--field-separator"}, end_ok=True)


def uniq_operands(args):
    """uniq's operands, or None for an option this doesn't approve. `--` is
    refused: after it `-x` is an operand, the file it writes."""
    return listed_options(
        args, "cdDuiz", "fsw",
        {"--count": False, "--repeated": False, "--unique": False, "--ignore-case": False,
         "--zero-terminated": False, "--all-repeated": True, "--group": True},
        {"--skip-fields", "--skip-chars", "--check-chars"}, end_ok=False)


def set_options(args):
    """Whether `set` only turns on pipefail and -e, -u or -x: options that
    make the calling shell fail sooner or louder, nothing else."""
    if not args:
        return False
    i = 0
    while i < len(args):
        a = args[i]
        m = re.fullmatch(r"-([eux]*)(o?)", a)
        if not m or a == "-":
            return False
        if m.group(2):
            if args[i + 1:i + 2] != ["pipefail"]:
                return False
            i += 1
        i += 1
    return True


def turns_on_pipefail(words):
    return words[0] == "set" and any(
        a == "pipefail" and k > 1 and re.fullmatch(r"-[eux]*o", words[k - 1])
        for k, a in enumerate(words) if k > 0)


def rough_deny(command):
    """A deny reason from reading the text without parsing it: each run of
    words between operators and newlines, quotes dropped. Used only when the
    real parse fails, so an unparsable part can't hide a forbidden one.
    Quoted heredoc bodies are data (see heredoc_data), and a call to a shell
    function the text defines isn't judged as the program of that name."""
    command = heredoc_data(command)
    functions = set(re.findall(r"(?:^|[\s;&|(){}])(" + FUNCTION_NAME + r")\s*\(\s*\)", command))
    functions |= set(re.findall(r"\bfunction\s+(" + FUNCTION_NAME + ")", command))
    # A here-string is checked as commands too (`sh <<<'git push -f'`).
    command = command.replace("<<<", " <<< ")
    todo = rough_words(command)
    while todo:
        words = todo.pop(0)
        if "<<<" in words:
            k = words.index("<<<")
            todo.append(words[k + 1:])
            words = words[:k]
        if not words or words[0] in functions:
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


def heredoc_data(text):
    """text without the bodies of its quoted heredocs, for rough_deny. A body
    stays unless every command on the line opening it surely takes it as
    data (see data_consumer: `cat <<'EOF'`, `git commit -F - <<'EOF'`), or
    when that line ends in a pipe, and from an unterminated body on,
    everything stays. Quotes and comments are
    skipped while looking for `<<`, so a quoted `<<'X'` opens nothing."""
    spans, pending = [], []
    i = line_start = 0
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            if quote == '"' and c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\":
            i += 2
        elif c in "'\"":
            quote = c
            i += 1
        elif c == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
        elif c == "\n":
            line = text[line_start:i]
            # A line ending in a pipe goes on after the bodies: what reads
            # them is on a line this doesn't look at.
            runs = not line_reads_data(line) or re.search(r"\|&?[ \t]*\Z", line)
            i += 1
            for delimiter, delimiter_quoted, strip_tabs in pending:
                try:
                    _, end = take_body(text, i, delimiter, strip_tabs)
                except Unparsable:
                    return remove_spans(text, spans)
                if delimiter_quoted and not runs:
                    spans.append((i, end))
                i = end
            pending = []
            line_start = i
        elif text.startswith("<<<", i):
            i += 3
        elif (m := HEREDOC.match(text, i)) and text.startswith("<<", i):
            pending.append((m.group(2), bool(m.group(1)), text.startswith("<<-", i)))
            i = m.end()
        else:
            i += 1
    data = remove_spans(text, spans)
    if re.search(r"(?:[)}]|\b(?:done|fi|esac))[ \t]*\|", data):
        # A compound command piped on (`{ cat <<'EOF' ... } | sh`): any
        # body may go where its output goes.
        return text
    return data


def line_reads_data(line):
    """Whether every command on a line surely takes what it reads as data
    (see data_consumer), read roughly: heredoc openers and redirects
    dropped, quotes stripped."""
    line = re.sub(r"\d*<<-?[ \t]*(['\"]?)[A-Za-z0-9_.-]+\1", " ", line)
    line = re.sub(r"\d*[<>]+&?[ \t]*[^\s;&|()]+", " ", line)
    for words in rough_words(line):
        cmd = Command()
        # `$TMPDIR` opening a word stands for its value, as in the full
        # reader, so a tee to scratch reads as one.
        cmd.words = [tmpdir(quoted=True) + w[m.end():] if (m := TMPDIR_WORD.match(w)) else w
                     for w in words]
        if not data_consumer(cmd):
            return False
    return True


def rough_words(text):
    """Each run of words between operators and newlines in text, quotes
    dropped: the rough reading's commands."""
    out = []
    for segment in re.split(r"[;&|()\n`]+|\$\(", text):
        words = [w.strip("'\"") for w in segment.split()]
        words = [w for w in words if w]
        if words:
            out.append(words)
    return out


def remove_spans(text, spans):
    out, last = [], 0
    for start, end in spans:
        out.append(text[last:start])
        last = end
    out.append(text[last:])
    return "".join(out)


def normalize_git_loosely(words):
    """git with every global option dropped, for rough_deny."""
    if os.path.basename(words[0]) != "git":
        return words
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                               "--super-prefix", "--attr-source", "--config-env") else 1
    return ["git"] + words[i:]


def project_file(path):
    """Whether a file a command writes is one of the project's, rather than
    a device, a scratch file ($TMPDIR, /tmp, the session scratchpad) or
    somewhere else outside the project. The project is its root and, for a
    session working in a worktree beside it, the checkout it runs in: the
    top of that worktree when it is one of the project's own, else the cwd.
    A path behind any variable but $PWD or $CLAUDE_PROJECT_DIR, or behind a
    substitution, is given the benefit of the doubt."""
    m = re.match(r"\$(\{(PWD|CLAUDE_PROJECT_DIR)\}|(PWD|CLAUDE_PROJECT_DIR)\b)/?", path)
    if m:
        path = path[m.end():] or "."
        if m.group(2) == "CLAUDE_PROJECT_DIR" or m.group(3) == "CLAUDE_PROJECT_DIR":
            path = os.path.join(WORKING["root"] or ".", path)
    if not path or path == "-" or path.startswith(("$", "~", PLACEHOLDER)):
        return False
    if ".git" in path.split("/"):
        # Edit and Write refuse these too: other rules decide them.
        return False
    cwd, root = WORKING["cwd"], WORKING["root"]
    if not root:
        return not path.startswith("/")
    real = os.path.realpath(os.path.join(cwd or root, path))
    checkout = checkout_of(cwd) if cwd else None
    bases = [os.path.realpath(root), checkout or os.path.realpath(cwd or root)]

    def under(base):
        return real == base or real.startswith(base + os.sep)

    if under(bases[0]):
        return True
    return not scratch(real) and under(bases[1])


def in_place_files(prog, args):
    """The files `sed -i` or `perl -i` edits, past its script, or None if it
    doesn't edit in place. An empty list: the files come from elsewhere
    (xargs, find -exec)."""
    if prog in ("sed", "gsed"):
        in_place = r"^-[nrEsuz]*i|^--in-place"
        takes_script = r"^-[nrEsuz]*[ef]$|^--(expression|file)$"
        names_script = r"^--(expression|file)="
    else:
        in_place = r"^-[0-9aplnsw]*i"
        takes_script = r"^-[0-9aplnsw]*[eE]$"
        names_script = None
    if not any(re.match(in_place, a) for a in args):
        return None
    files, script_given, i = [], False, 0
    while i < len(args):
        a = args[i]
        if re.match(takes_script, a):
            script_given, i = True, i + 2
            continue
        if names_script and re.match(names_script, a):
            script_given = True
        elif a == "-i" and i + 1 < len(args) and (args[i + 1] == "" or args[i + 1].startswith(".")):
            # BSD sed's backup suffix, `-i ''` or `-i .bak`.
            i += 1
        elif not (a.startswith("-") and a != "-"):
            files.append(a)
        i += 1
    return files if script_given else files[1:]


# A script opening a file for writing: Python's open() with a write mode or
# pathlib's write_text, Node's fs writes, Perl's `open(F, ">x")`, Ruby's
# File.write.
WRITES_FILE = re.compile(
    r"""\bopen\((?:[^\n()]|\([^\n()]*\))*?,\s*(?:mode\s*=\s*)?(['"])[rbt]*[wax+][rbt+]*\1"""
    r"""|\.open\(\s*(?:mode\s*=\s*)?(['"])[rbt]*[wax+][rbt+]*\2"""
    r"""|\.write_(?:text|bytes)\("""
    r"""|\b(?:writeFileSync|writeFile|appendFileSync|appendFile|createWriteStream)\s*\("""
    r"""|\bopen\s*\(?\s*(?:my\s+)?[$\w]+\s*,\s*['"]\+?>"""
    r"""|\b(?:File|IO)\.write\b""")
# A script naming a scratch location, whose writes are taken to go there.
SCRATCH_SCRIPT = re.compile(r"TMPDIR|['\"]/(?:private/)?tmp/|\btempfile\b|\bmkdtemp|\btmpdir\(")


def writing_script(script):
    return bool(WRITES_FILE.search(script)) and not SCRATCH_SCRIPT.search(script)


def inline_scripts(words):
    """The scripts an interpreter is given on its command line: python's
    -c, node's -e/-p/--eval/--print, perl's and ruby's -e/-E."""
    scripts, k = [], 1
    while k < len(words):
        w = words[k]
        name, eq, value = w.partition("=")
        if eq and name in ("--eval", "--print"):
            scripts.append(value)
        elif w in ("--eval", "--print") or re.match(r"^-[A-Za-z0-9]*[ceEp]$", w):
            if k + 1 < len(words):
                scripts.append(words[k + 1])
            k += 1
        elif w in ("-W", "-X", "-I", "-r", "--require", "--import", "--loader"):
            # An option's value (python's -W/-X, perl's and ruby's -I, node's
            # -r), not the script.
            k += 1
        elif not w.startswith("-") or w == "-":
            # A script file or stdin: the options after it are its own.
            break
        k += 1
    return scripts


def interpreter(prog):
    """Whether a program runs a script this can't read."""
    return prog in INTERPRETERS or bool(re.match(r"^python[0-9.]*$", prog))


def shell_edit(result):
    """How a command line changes a project file from Bash, or None. The
    common forms only (not cp, mv, dd, patch...): this turns an easy mistake
    into a redirect, it doesn't stop a determined one."""
    for target in result.writes:
        if project_file(target):
            return f"redirecting to {target}"
    for words in result.commands:
        if words[0].startswith(">"):
            continue
        prog = program(words[0])
        if prog in ("sed", "gsed", "perl"):
            files = in_place_files(prog, words[1:])
            if files is not None and (not files or any(project_file(f) for f in files)):
                return f"{prog} -i"
        if prog == "tee":
            for f in words[1:]:
                if not f.startswith("-") and project_file(f):
                    return f"tee {f}"
        # The interpreter may come behind a runner (`uv run python -c`).
        k = next((k for k, w in enumerate(words) if interpreter(program(w))), None)
        if k is not None and any(writing_script(s) for s in inline_scripts(words[k:])):
            return f"a {program(words[k])} script writing a file"
    for script in result.scripts:
        if writing_script(script):
            return "a script writing a file"
    return None


def decide(tool, tool_input, policy):
    """(decision, reason), or None to leave the call to Claude Code."""
    CHECKOUTS.clear()
    if tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if secret_path(path):
            return "deny", f"{path} is a secrets file. Change .env.example instead, and say what the real file needs."
        if tool != "Read" and ".git" in path.replace("\\", "/").split("/"):
            # A repository's own files, config and hooks among them, which git
            # runs from.
            return "deny", f"{path} is inside a .git directory."
        if tool != "Read" and claude_config(path):
            # The project's settings, hooks, skills and agents, which the
            # Edit allow rule would otherwise cover.
            return "ask", f"{path} is part of the project's Claude Code configuration."
        return None
    if tool in ("Grep", "Glob"):
        # Glob only lists names, so its pattern may mention a secrets file.
        for key in ("path",) if tool == "Glob" else ("path", "glob"):
            value = tool_input.get(key) or ""
            if secret_path(value):
                return "deny", f"{value} is a secrets file."
        return None
    if tool != "Bash":
        return None

    command = tool_input.get("command", "")
    # The canonical commit message is data: check the command with a stand-in.
    checked = commit_stand_in(command)
    try:
        result = analyse(checked)
        for words in result.commands:
            if id(words) in result.direct and words[0] in result.functions:
                # A call to a function the call defines: its body is checked
                # where it's defined, and the call asks below.
                continue
            reason = forbidden(words)
            if reason:
                return "deny", f"Not allowed in a session: {reason}."
            named = secret_named(words)
            if named:
                return "deny", f"{named.lstrip('>')} is a secrets file. Change .env.example instead, and say what the real file needs."
        for body in result.scanned:
            # A body something may run as a script (`ssh host <<'EOF'`).
            for words in body.commands + body.rough:
                try:
                    reason = forbidden(words)
                except Unparsable:
                    reason = None
                if reason:
                    return "deny", f"Not allowed in a session, in what a heredoc or here-string feeds: {reason}."
            for words in body.commands:
                named = secret_named(words)
                if named:
                    return "deny", f"{named.lstrip('>')} is a secrets file."
        # The main checkout stays on its default branch, in any part of the
        # call. Its ask waits for every deny below.
        stray = main_checkout_switch(result)
        if stray and stray[0] == "deny":
            return stray
        # Tracking config goes to the shared .git/config, which the sandbox
        # protects (#45).
        tracked = tracking_create(result)
        if tracked:
            return tracked
    except Unparsable as e:
        # A command this can't follow gets no automatic allow, and a user
        # decides it, unless a rough reading finds something to deny.
        reason = rough_deny(command)
        if reason:
            return "deny", reason
        return "ask", f"coldlogic guard can't follow this command ({e})."

    edit = shell_edit(result) or next(filter(None, (shell_edit(b) for b in result.scanned)), None)
    if edit:
        # A shell edit prompts the user, the Edit and Write tools don't.
        return "deny", (f"coldlogic guard: {edit} changes a project file from Bash. Make the change "
                        "with the Edit or Write tool instead, then run any command as its own Bash "
                        "call. Scratch output can go to $TMPDIR or /dev/null.")

    commands = [w for w in result.commands if not w[0].startswith(">")]
    # Every rule is matched against each command of the call in both
    # spellings: as written, wrapper included, and unwrapped. A rule written
    # with the wrapper (`devenv shell --quiet -- gh-app issue create *`) also
    # stands for its inner command.
    deny_rules, ask_rules = policy.get("deny", []), policy.get("ask", [])
    deny = [rule_regex(r, widen=True) for r in deny_rules + inner_rules(deny_rules)]
    ask = [rule_regex(r, widen=True) for r in ask_rules + inner_rules(ask_rules)]
    if any(r.match(checked) for r in deny):
        return "deny", "Denied by a deny rule."
    # Rules also see git with every global option dropped, so an inert one
    # (`git --literal-pathspecs push`) doesn't dodge them.
    def spellings(unwrapped):
        cmds = [w for w in unwrapped.commands if not w[0].startswith(">")]
        return (cmds + [normalize_git_loosely(w) for w in cmds if os.path.basename(w[0]) == "git"]
                + [words for words, _, _ in unwrapped.written])
    ruled = spellings(result)
    for words in ruled + [w for body in result.scanned for w in spellings(body) + body.rough]:
        if matches(deny, words):
            return "deny", f"Denied by this project's rules: {' '.join(words)}"
    if result.gate_piped:
        # The conventions forbid hiding the gate's exit status.
        return "deny", ("coldlogic guard: piping scripts/check.sh hides its exit status. Run it as "
                        "`set -o pipefail; ... | tail -40`, or redirect it to \"$TMPDIR/check.log\" "
                        "and read that.")
    if result.gate_hidden:
        return "deny", ("coldlogic guard: a command after scripts/check.sh (after `||`, `;`, a newline "
                        "or `&`), backgrounding it with `&`, or running it inside `$(...)`, hides its "
                        "exit status. Run the gate "
                        "on its own, or follow it only with `&& ...`.")
    if stray:
        # A switch the guard can't place, now that nothing is denied.
        return stray
    if result.functions:
        return "ask", "coldlogic guard: this call defines a shell function, which the guard can't follow."
    if any(r.match(checked) for r in ask):
        return "ask", "An ask rule covers this command."
    for words in ruled:
        if matches(ask, words):
            return "ask", f"An ask rule covers: {' '.join(words)}"

    allow_rules = policy.get("allow", [])
    allow = [rule_regex(r) for r in allow_rules]
    # An allow rule written with the wrapper allows its inner command only
    # as run through the wrapper.
    through_wrapper = allow + [rule_regex(r) for r in inner_rules(allow_rules)]
    # `checked` has the commit message's stand-in already.
    plain = plain_commands(checked) if not away_from_root() else None
    if plain is not None:
        cmds, targets = plain
        # The plain reading and the full analysis must agree on every
        # command, in order, and on every file written; each command, every
        # stage of a pipeline included, must be approved on its own.
        written = sorted(w[0][1:] for w in result.commands if w[0].startswith(">"))
        if ([c.words for c in cmds] == commands and written == sorted(targets)
                and not result.opaque
                and all(approved(c.words, through_wrapper if c.wrapped else allow) for c in cmds)):
            return "allow", "coldlogic guard: every command in this call is one an allow rule names or only reads."
        for c in cmds:
            if c.wrapped and not approved(c.words, through_wrapper) and matches(allow, c.original):
                # A rule allowing the wrapper itself would let anything through it.
                return "ask", "coldlogic guard: a rule allows the wrapper, not the command inside it."
    # Claude Code's own rules would allow a command that one names, though
    # an option or path in it is one this hook refuses: ask instead.
    for w in commands:
        if matches(allow, w) and not plain_args(w):
            return "ask", f"coldlogic guard: an allow rule names {w[0]}, but not with these arguments."
    for words, inner, opaque in result.written:
        # A rule allowing the wrapper itself would let anything through it,
        # and Claude Code matches it against each command of the call. Each
        # wrapped command counts on its own words, not the whole text's: a
        # rule for `git status` says nothing of `git status && eval ...`.
        if matches(allow, words) and (opaque or not all(approved(w, through_wrapper) for w in inner)):
            return "ask", "coldlogic guard: a rule allows the wrapper, not the command inside it."
    # Anything else is left to Claude Code's own rules, as it would be
    # without this hook.
    return None


# The one substitution allowed: a commit whose message is a quoted heredoc,
# as a command of its own, optionally behind `devenv shell --`.
COMMIT_MESSAGE = re.compile(
    r"""((?:devenv shell(?: --quiet| -q)? -- )?git commit(?: -[aqsvn]+| --(?:all|amend|no-verify|allow-empty|signoff|quiet|verbose|no-edit))*) -([aqsvn]*)m "\$\(cat <<'EOF'\n(?:(?!EOF)[^\n]*\n)*EOF\n\)"(?=\Z|[ \t]*(?:&&|;|\n))""")


def commit_stand_in(command):
    """command with each canonical heredoc commit message (COMMIT_MESSAGE)
    replaced by a stand-in, `git commit -m message`. A message counts only
    where a command starts: at the start of the text, or after `&&`, `;` or
    a newline ending text the strict reader reads (plain_commands), so it
    can't sit inside a quote or another heredoc. The first message that
    doesn't count stops the replacing."""
    done, rest = "", command
    while True:
        m = COMMIT_MESSAGE.search(rest)
        if not m:
            return done + rest
        prefix = done + rest[:m.start()]
        if prefix:
            ended = re.search(r"[ \t]*(?:&&|;|\n)[ \t]*\Z", prefix)
            if not ended or plain_commands(prefix[:ended.start()]) is None:
                return done + rest
        done = prefix + m.group(1) + " -" + m.group(2) + "m message"
        rest = rest[m.end():]
# Characters that mean nothing to the shell outside quotes.
PLAIN = re.compile(r"[A-Za-z0-9 _./:@%+,=-]")


class Plain:
    """A simple command as the strict reader reads it."""

    def __init__(self, original):
        # Its words as written, `devenv shell --` included.
        self.original = original
        # The words that run: past that prefix, git's global options dropped.
        self.words = original
        self.wrapped = False


# Words that may not start a command the strict reader approves: they change
# what the rest of the call runs, or aren't one command.
NOT_PLAIN = RESERVED | UNFOLLOWED | {"cd", "pushd", "popd", "source", "."}


def plain_word(text, i):
    """(a word's value, the index past it) for a word of the strict
    grammar starting at i, or None: plain characters, '...', "..." with no
    $ ` \\ inside, and a `$TMPDIR` or `${TMPDIR}`, quoted or not, opening the
    word."""
    start, out, bare_tilde = i, [], False
    while i < len(text):
        c = text[i]
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return None
            out.append(text[i + 1:j])
            i = j + 1
        elif c == '"':
            j = text.find('"', i + 1)
            if j < 0:
                return None
            body = text[i + 1:j]
            m = TMPDIR_WORD.match(body) if i == start else None
            if m:
                out.append(tmpdir(quoted=True))
                body = body[m.end():]
            if re.search(r'[$`\\]', body):
                return None
            out.append(body)
            i = j + 1
        elif c == "$":
            m = TMPDIR_WORD.match(text, i) if i == start else None
            value = tmpdir(quoted=False) if m else None
            if value is None:
                return None
            out.append(value)
            i = m.end()
        elif c in " \t\n;&|":
            break
        elif PLAIN.match(c) and not (c == "=" and i == start):
            out.append(c)
            i += 1
        elif c == "~" and i > start:
            # Checked below: only in a revision (`HEAD~1`). A quoted `~`
            # is just a character.
            out.append(c)
            bare_tilde = True
            i += 1
        else:
            return None
    if i == start:
        return None
    if bare_tilde and not REVISION.fullmatch(text[start:i]):
        return None
    return "".join(out), i


# A git revision with `~` ancestry (`HEAD~1`, `origin/main~2..HEAD`): the
# only words where the strict reader takes an unquoted `~`. Not first, so no
# home directory; and with zsh's EXTENDED_GLOB, where `a~b` matches files
# named a but not b, only names spelled out in full could match. `^` isn't
# taken: as a zsh glob operator it can match names the word doesn't spell.
REVISION = re.compile(r"[A-Za-z0-9_./@-]+(?:~[0-9]*)+(?:\.\.\.?[A-Za-z0-9_./@-]+(?:~[0-9]*)*)?")


def plain_commands(command):
    """(the simple commands, the files written) of a call the shell runs as
    written, or None. The commands are joined by `&&`, `||`, `;`, newlines
    and `|`, each optionally behind `devenv shell [--quiet|-q] --`; their
    words are plain_word's; their redirects only duplicate a descriptor
    (`2>&1`, `>&2`), write or append to a device or a scratch file outside
    the project, or open a heredoc with a fully quoted delimiter, whose body
    is skipped after the line's newline as the shell does. Anything else
    (`&`, `|&`, subshells, groups, `!`, reserved words, substitutions,
    comments, escapes, input redirects, assignments, wrappers) gets no allow
    from this hook. Bash and zsh read all of this alike."""
    cmds, targets, pending = [], [], []
    words = None
    # A command must follow: after `|`, `&&` or `||`.
    need = False

    def end():
        nonlocal words
        c, words = Plain(words), None
        run = c.original
        if run[:2] == ["devenv", "shell"]:
            k = 3 if run[2:3] in (["--quiet"], ["-q"]) else 2
            if run[k:k + 1] != ["--"] or len(run) <= k + 1:
                return False
            run, c.wrapped = run[k + 1:], True
        head = os.path.basename(run[0])
        if "=" in run[0] or head in WRAPPERS | SHELLS or head in NOT_PLAIN:
            # A runner or wrapper: the rule names what it runs, not it.
            return False
        try:
            c.words = normalize_git(run) if run[0] == "git" else run
        except Unparsable:
            return False
        cmds.append(c)
        return True

    i = 0
    while i < len(command):
        c = command[i]
        rest = command[i:]
        if c in " \t":
            i += 1
        elif c == "\n":
            i += 1
            for delimiter, strip_tabs in pending:
                try:
                    _, i = take_body(command, i, delimiter, strip_tabs)
                except Unparsable:
                    return None
            pending = []
            if words is not None and not end():
                return None
        elif rest.startswith(("&&", "||")) or c in "|;":
            op = rest[:2] if rest.startswith(("&&", "||")) else c
            if words is None or rest.startswith(("|&", ";;")) or not end():
                return None
            need = op != ";"
            i += len(op)
        elif m := re.match(r"[0-9]?>&[0-9](?=[\s;&|]|\Z)", rest):
            if words is None:
                return None
            i += m.end()
        elif m := re.match(r"(?:[0-9]?>>?|&>>?)(?![|!&(>])[ \t]*", rest):
            target = plain_word(command, i + m.end())
            if words is None or target is None:
                return None
            value, i = target
            if value != "/dev/null":
                if not safe_redirect(">", value):
                    return None
                targets.append(value)
        elif rest.startswith("<<") and not rest.startswith("<<<"):
            m = re.match(r"<<(-?)[ \t]*(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\")(?=[\s;&|]|\Z)", rest)
            if words is None or not m:
                return None
            pending.append((m.group(2) or m.group(3), bool(m.group(1))))
            i += m.end()
        else:
            word = plain_word(command, i)
            if word is None:
                return None
            value, i = word
            words = (words or []) + [value]
            need = False
    if pending or (words is not None and not end()) or need or not cmds:
        return None
    return cmds, targets


def approved(words, allow):
    """Whether a command may run without a prompt as part of a call: an
    allow rule names it or it only reads, its arguments stay inside the
    project, and it isn't a shell or an interpreter reading its script from
    stdin."""
    prog = program(words[0])
    if prog in SHELLS or (interpreter(prog) and not any(not a.startswith("-") for a in words[1:])):
        return False
    return plain_args(words) and (read_only(words) or matches(allow, words))


def is_gate(words):
    """Whether a command runs the gate, scripts/check.sh: by its path, or as
    a shell's or `source`'s script (`bash scripts/check.sh`)."""
    def gate_path(w):
        return os.path.normpath(w) == "scripts/check.sh" or w.endswith("/scripts/check.sh")
    if not words:
        return False
    if gate_path(words[0]):
        return True
    if program(words[0]) in SHELLS or words[0] in ("source", "."):
        i = 1
        while i < len(words) and words[i][:1] in ("-", "+") and words[i] not in ("-", "--"):
            # -o and +o take an option name.
            i += 2 if words[i] in ("-o", "+o") else 1
        if i < len(words) and words[i] == "--":
            i += 1
        return i < len(words) and gate_path(words[i])
    return False


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
        if result and result[0] == "allow" and event.get("permission_mode") == "plan":
            # Plan mode makes no changes: this hook doesn't speed anything up there.
            result = None
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
