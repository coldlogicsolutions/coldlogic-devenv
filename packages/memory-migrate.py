"""Imports Claude Code's auto memory files into the shared memory store.

    coldlogic-memory-migrate --list [--projects <dir>]
    coldlogic-memory-migrate --map <table> [--apply] [--url <base>]
                             [--projects <dir>]

Each regular, non-symlink `<projects>/<dir>/memory/<name>.md` other than
MEMORY.md is one memory. A symlinked `.md` there is never followed or stored:
it reads `skip (symlink, not imported)`, is counted apart, and makes a dry run
and `--apply` exit 1, so a note kept behind one isn't lost unnoticed. `--list`
prints each <dir> that has memory files, with their count and any symlinks', as
a start for the table, and contacts nothing.

The table maps a project directory, or one file in it, to a scope. Lines are
`<key><TAB><scope>`, with `#` comments and blank lines; a key is `<dir>` or
`<dir>/<name>.md`, and a file's row wins over its directory's. A scope is
`scope:org`, `scope:user:<login>`, `scope:project:<owner>/<repo>` or `skip`;
the login, owner and repo are lower-cased (A-Z only) first, and one trailing
`.git` dropped from the repo, as the recall hook derives them. Any directory `--list` prints can have a row, a links-only
one included. A malformed row, an unknown scope or a key that names nothing
exits 2 before the store is contacted.

The store URL (`--url`, else `$COLDLOGIC_MEMORY_URL`) must be `http(s)://<host>
[:<port>][/<path>]` with nothing else (no credentials, query, fragment or
space), as the recall hook and devenv.nix accept it; anything else exits 2.

Without `--apply` it is a dry run: it asks the store which files are already
imported and prints one line per file (`store`, `skip (already imported)`,
`conflict (same source_file, different content)`, `skip (table)`, `skip
(unsupported frontmatter)` or `unmapped`), and stores nothing. A file counts as
already imported only when a memory with its `source_file` holds its content
(ends trimmed); a memory with its `source_file` and other content is a
conflict: never stored, and the exit status is 1. An `unmapped` file makes the
dry run exit 1 too, as `--apply` would refuse it. When the store can't be
asked, every file it would have checked reads `unknown (store not reached)`
and the exit status is 1. With `--apply` it
refuses while any file is unmapped, then stores file by file, skipping what is
already imported, carries on past a failure, prints the counts and exits 1 if
any failed, conflicted or had frontmatter it can't read. A file the store
refuses as a duplicate of content it already holds (its `message`, else its
`detail`, says so, with a status that isn't 5xx) reads `skip (duplicate content
in store)`, counted apart from the files already imported. It never changes a
file under `--projects`: they are the only copy until the import has been
checked.

Frontmatter is read as `key: value` lines and one nested level under
`metadata:`. A value it can't read that way (a YAML block scalar such as `>` or
`|-`, a value continued on further lines, an unclosed quote, text after a
closing quote other than a ` # comment`), or an opening `---` never closed,
makes the file `skip (unsupported frontmatter: <why>)`: it is never stored
with a value cut short, or with `---` as its summary. As in YAML, `''` in a
single-quoted value is one `'`, and `~`, `null` or nothing is no value, so the
summary falls back to the name. Unlike YAML, a plain value is taken whole: ` #`
in it is text (`see #107`), as Claude writes these files; a ` # comment` is
dropped only after a closing quote or a bare `metadata:`. A leading byte order
mark is dropped, CRLF and lone CR line ends are read (and stored) as LF, and a
`type` is lower-cased (A-Z only).

The store's REST API is outside a Claude Code session's sandbox by design, so
this runs from a terminal.
"""

import argparse
import json
import os
import re
import stat
import string
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 10
SOURCE = "auto-memory"
PART = re.compile(r"[a-z0-9._-]+")
LOGIN = re.compile(r"[a-z0-9][a-z0-9-]*")
TYPE = re.compile(r"[a-z0-9-]+")
TERMINAL = ("Run it from a terminal, not from a Claude Code session: the "
            "sandbox keeps a session's commands away from the store.")
# The store's base URL, as devenv.nix's normaliseMemoryUrl and the recall hook
# accept it.
URL = re.compile(r"https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/*")
# A YAML block scalar's header: `|` or `>`, an optional chomping and
# indentation indicator, then nothing but a comment.
BLOCK = re.compile(r"[|>][0-9+-]*(\s+#.*)?")
# What may follow a quoted value's closing quote or a bare `metadata:`. A plain
# value has no comments: ` #` in it is text.
COMMENT = re.compile(r"\s+#.*")


class Usage(Exception):
    """A table or argument error: exit 2, nothing sent."""


class Unsupported(Exception):
    """Frontmatter this reader can't take apart safely: the file isn't stored."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# No proxy from the environment, and a redirect is an error, not followed.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def http_get(url):
    """GETs url and returns the parsed JSON body. Raises on any failure."""
    with _OPENER.open(urllib.request.Request(url, method="GET"), timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def http_post(url, body):
    """POSTs body as JSON to url and returns the parsed JSON answer. An error
    status with a JSON body comes back as that body, a dict carrying the status
    under HTTP_STATUS, so a refusal is reported with its reason."""
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json"})
    try:
        with _OPENER.open(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        # The service answers a refusal (a duplicate, say) with a JSON body.
        try:
            answer = json.loads(e.read().decode("utf-8"))
        except Exception:
            raise e
        if not isinstance(answer, dict):
            answer = {"detail": answer}
        return {**answer, HTTP_STATUS: e.code}


# Where http_post puts an error answer's HTTP status. No store field has it.
HTTP_STATUS = "_http_status"


def failure_message(answer):
    """Why a POST failed: the answer's `message`, else its `detail`, else its
    HTTP status. Never `None`, and on one line, so the store can't add rows to
    the report."""
    def one_line(value):
        text = value if isinstance(value, str) else json.dumps(value)
        return " ".join(text.split())

    if not isinstance(answer, dict):
        return one_line(answer)
    for field in ("message", "detail"):
        value = answer.get(field)
        if value is not None and one_line(value):
            return one_line(value)
    if HTTP_STATUS in answer:
        return f"HTTP {answer[HTTP_STATUS]}"
    return "no reason given"


# ------------------------------------------------------------------ files --

def discover(projects):
    """({dir: [file name, ...]}, {dir: [symlink name, ...]}), sorted: the
    regular memory files, and the `.md` symlinks beside them. A symlink is
    never followed (it may point anywhere), but it is reported, so a note kept
    behind one isn't lost unnoticed when auto memory is turned off."""
    found, linked = {}, {}
    try:
        dirs = sorted(os.listdir(projects))
    except OSError:
        return found, linked
    for d in dirs:
        mem = os.path.join(projects, d, "memory")
        try:
            names = sorted(os.listdir(mem))
        except OSError:
            continue
        files, links = [], []
        for name in names:
            if not name.endswith(".md") or name == "MEMORY.md":
                continue
            try:
                st = os.lstat(os.path.join(mem, name))
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                files.append(name)
            elif stat.S_ISLNK(st.st_mode):
                links.append(name)
        if files:
            found[d] = files
        if links:
            linked[d] = links
    return found, linked


def _after_quote(key, rest):
    """What may follow a closing quote: nothing, or a ` # comment`."""
    if rest.strip() and not COMMENT.fullmatch(rest):
        raise Unsupported(f"{key!r} has text after its closing quote")


def _value(key, raw):
    """A one-line value, unquoted, or None for no value (empty, `~`, `null`).
    Raises Unsupported for a block scalar, an unclosed quote or text after a
    closing quote, which would otherwise be stored as `>` or cut short."""
    raw = raw.strip()
    if BLOCK.fullmatch(raw):
        raise Unsupported(f"{key!r} is a YAML block scalar")
    if raw[:1] == '"':
        # A JSON string, then nothing but a comment. YAML escapes JSON lacks
        # (`\x41`, say) aren't guessed at.
        try:
            value, end = json.JSONDecoder().raw_decode(raw)
        except ValueError:
            raise Unsupported(f"{key!r} has an unclosed or undecodable double quote")
        _after_quote(key, raw[end:])
        return str(value)
    if raw[:1] == "'":
        # YAML's single quotes: no escapes, and `''` is one `'`.
        out, i = [], 1
        while True:
            j = raw.find("'", i)
            if j < 0:
                raise Unsupported(f"{key!r} has an unclosed single quote")
            out.append(raw[i:j])
            if raw[j + 1:j + 2] == "'":
                out.append("'")
                i = j + 2
                continue
            _after_quote(key, raw[j + 1:])
            return "".join(out)
    # A plain value is taken whole: ` #` in it is text, not a comment. Claude
    # writes these files, not a YAML author, and `#107` is an issue far more
    # often than a comment, so cutting there would store `... store` for
    # `... store #107`.
    if raw in ("", "~", "null", "Null", "NULL"):
        return None
    return raw


def parse_memory(text):
    """(frontmatter, nested metadata, body, has frontmatter) of a memory file.

    Raises Unsupported when a line isn't a `key: value` this reader takes:
    a continuation line, a deeper level, or a value of more than one line.
    A leading UTF-8 byte order mark is dropped first, so it can't hide the
    opening `---` or start the stored text, and CRLF and lone CR line ends
    become LF, so a file saved on Windows reads (and is stored) as the same
    lines. An opening `---` with no closing one raises Unsupported rather
    than storing the frontmatter, `---` and all, as the note."""
    text = text.removeprefix("﻿").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, {}, text, False
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise Unsupported("unclosed")
    top, meta, in_meta, meta_indent = {}, {}, False, None
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" \t"))
        key, sep, value = line.strip().partition(":")
        key = key.strip()
        if not sep or not key:
            # A line that is no `key: value`: the previous value continues.
            raise Unsupported(f"line {line.strip()!r} continues a value")
        if indent:
            if not in_meta:
                raise Unsupported(f"indented line {line.strip()!r} outside metadata")
            if meta_indent is None:
                meta_indent = indent
            elif indent != meta_indent:
                raise Unsupported(f"line {line.strip()!r} nests deeper than metadata")
            meta[key] = _value(key, value)
            continue
        # `metadata:` opens the nested block when nothing, or nothing but a
        # ` # comment`, follows it.
        in_meta = key == "metadata" and (not value.strip() or bool(COMMENT.fullmatch(value)))
        meta_indent = None
        if not in_meta:
            top[key] = _value(key, value)
    return top, meta, "\n".join(lines[end + 1:]), True


def memory_body(d, name, text):
    """The body to POST for one file."""
    top, meta, body, has_front = parse_memory(text)
    stem = name[:-3]
    body = body.strip("\n")
    if has_front:
        summary = top.get("description") or top.get("name") or stem
        content = summary + ("\n\n" + body if body.strip() else "")
    else:
        # No frontmatter: the file as it is, so its first line is the summary.
        content = body if body.strip() else stem
    tags = []
    # Lower-cased (A-Z only) first, so `Project` is tagged as `project` is.
    mtype = (meta.get("type") or top.get("type") or "").translate(_ASCII_LOWER)
    if TYPE.fullmatch(mtype):
        tags.append("type:" + mtype)
    tags.append("source:" + SOURCE)
    return {
        "content": content,
        "tags": tags,
        "metadata": {
            "name": top.get("name") or stem,
            "description": top.get("description") or "",
            "source": SOURCE,
            "source_file": d + "/" + name,
        },
    }


def read_file(projects, d, name):
    path = os.path.join(projects, d, "memory", name)
    # Read-only, and never through a link that appeared since discovery.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as f:
        return f.read().decode("utf-8")


# ------------------------------------------------------------------ table --

def normal_scope(scope):
    """The scope with its login, or owner and repo, lower-cased, as the hook
    derives them, so `scope:project:Acme/Widget` lands where a session in that
    repo looks. The prefixes stay exact. Only A-Z is folded: str.lower() would
    also fold the Kelvin sign to `k`, letting a non-ASCII name pass the check.
    A project's repo loses one trailing `.git`, as the hook drops it from
    origin, so `acme/app.git` is the scope a session in acme/app recalls."""
    for prefix in ("scope:user:", "scope:project:"):
        if scope.startswith(prefix):
            rest = scope[len(prefix):].translate(_ASCII_LOWER)
            if prefix == "scope:project:":
                rest = rest.removesuffix(".git")
            return prefix + rest
    return scope


_ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)


def valid_scope(scope):
    if scope in ("skip", "scope:org"):
        return True
    if scope.startswith("scope:user:"):
        return bool(LOGIN.fullmatch(scope[len("scope:user:"):]))
    if scope.startswith("scope:project:"):
        parts = scope[len("scope:project:"):].split("/")
        return len(parts) == 2 and all(
            PART.fullmatch(p) and p not in (".", "..") for p in parts)
    return False


def parse_table(text, found, dirs):
    """{key: scope}. Raises Usage on a malformed row, scope or key.

    A directory key may name any directory `--list` prints (`dirs`), one
    holding only `.md` symlinks included, so a row copied from that list is
    never refused; its links are still reported and never stored. A file key
    must name a regular memory file (`found`)."""
    table = {}
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0].strip() or not fields[1].strip():
            raise Usage(f"table line {n}: expected <key><TAB><scope>: {line!r}")
        key, scope = fields[0].strip(), normal_scope(fields[1].strip())
        if not valid_scope(scope):
            raise Usage(f"table line {n}: unknown scope {scope!r}")
        if "/" in key:
            d, _, name = key.partition("/")
            if d not in found or name not in found[d]:
                raise Usage(f"table line {n}: {key!r} names no memory file")
        elif key not in dirs:
            raise Usage(f"table line {n}: {key!r} names no directory with memory files")
        if key in table:
            raise Usage(f"table line {n}: {key!r} is mapped twice")
        table[key] = scope
    return table


def scope_of(table, d, name):
    return table.get(d + "/" + name) or table.get(d)


# ------------------------------------------------------------------ store --

def imported(base):
    """{metadata.source_file: [content, ...]} for every memory already in the
    store under source:auto-memory. A memory without a string `content` is
    listed with None, which matches no file."""
    seen, page = {}, 1
    while page <= 10000:
        query = urllib.parse.urlencode(
            {"tag": "source:" + SOURCE, "page_size": 100, "page": page})
        answer = http_get(f"{base}/api/memories?{query}")
        memories = answer.get("memories")
        if not isinstance(memories, list):
            raise ValueError("the store's answer has no memories list")
        for m in memories:
            meta = m.get("metadata") if isinstance(m, dict) else None
            if isinstance(meta, dict) and isinstance(meta.get("source_file"), str):
                content = m.get("content")
                seen.setdefault(meta["source_file"], []).append(
                    content if isinstance(content, str) else None)
        if not answer.get("has_more") or not memories:
            return seen
        page += 1
    raise ValueError("the store kept answering has_more")


def same_content(stored, content):
    """Whether a stored memory's content is this file's, ignoring only the
    whitespace at its ends (a store may trim it)."""
    return stored is not None and stored.strip() == content.strip()


def is_duplicate(answer):
    """Whether a POST's answer is the store refusing content it already holds:
    its `message`, else its `detail`, mentions a duplicate, and the status is
    not a server error (a 5xx that says "duplicate" is still a failure)."""
    if not isinstance(answer, dict) or answer.get("success") is True:
        return False
    status = answer.get(HTTP_STATUS)
    if isinstance(status, int) and status >= 500:
        return False
    reason = answer.get("message") or answer.get("detail") or ""
    return "duplicate" in (reason if isinstance(reason, str) else json.dumps(reason)).lower()


def unreachable(base, e):
    print(f"coldlogic-memory-migrate: the memory store at {base} couldn't be reached ({e}). {TERMINAL}",
          file=sys.stderr)


# ------------------------------------------------------------------- main --

def main(argv=None):
    p = argparse.ArgumentParser(prog="coldlogic-memory-migrate")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true")
    mode.add_argument("--map")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--url", default=os.environ.get("COLDLOGIC_MEMORY_URL", ""))
    p.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    args = p.parse_args(argv)

    found, linked = discover(args.projects)
    dirs = sorted(set(found) | set(linked))
    if args.list:
        for d in dirs:
            line = f"{d}\t{len(found.get(d, []))}"
            if d in linked:
                line += f"\t{len(linked[d])} symlinked, not imported"
            print(line)
        return 0

    try:
        with open(args.map, "r", encoding="utf-8") as f:
            table = parse_table(f.read(), found, set(dirs))
    except (OSError, UnicodeDecodeError) as e:
        print(f"coldlogic-memory-migrate: can't read the table: {e}", file=sys.stderr)
        return 2
    except Usage as e:
        print(f"coldlogic-memory-migrate: {e}", file=sys.stderr)
        return 2

    # Checked before anything is sent, with the same pattern as the hook: a
    # mistake (a pasted query, credentials) stops here, not at the store. The
    # value isn't echoed: it may hold a password.
    if args.url and not URL.fullmatch(args.url):
        print("coldlogic-memory-migrate: the store URL (--url or COLDLOGIC_MEMORY_URL) "
              "is unusable: it must be http(s)://<host>[:<port>][/<path>], with no "
              "credentials, query, fragment or space.", file=sys.stderr)
        return 2

    unmapped = sorted({d for d, files in found.items()
                       for name in files if not scope_of(table, d, name)})
    if args.apply and unmapped:
        print("coldlogic-memory-migrate: nothing stored: these directories have "
              "memory files with no row in the table (map them or mark them skip): "
              + ", ".join(unmapped), file=sys.stderr)
        return 1

    base = args.url.rstrip("/")
    done = None
    if base:
        try:
            done = imported(base)
        except Exception as e:
            unreachable(base, e)
    else:
        print("coldlogic-memory-migrate: no store URL (--url or COLDLOGIC_MEMORY_URL).",
              file=sys.stderr)
    if args.apply and done is None:
        return 1

    counts = {"stored": 0, "already imported": 0, "duplicate in store": 0,
              "conflict": 0, "skipped": 0, "unsupported": 0, "symlinked": 0,
              "unknown": 0, "failed": 0}
    for d in dirs:
        links = set(linked.get(d, []))
        for name in sorted(found.get(d, []) + linked.get(d, [])):
            key = d + "/" + name
            if name in links:
                # Never followed, never stored, whatever the table says, and
                # the run exits 1: the note behind it needs a person.
                counts["symlinked"] += 1
                print(f"skip (symlink, not imported)\t{key}")
                continue
            scope = scope_of(table, d, name)
            if not scope:
                print(f"unmapped\t{key}")
                continue
            if scope == "skip":
                counts["skipped"] += 1
                print(f"skip (table)\t{key}")
                continue
            try:
                body = memory_body(d, name, read_file(args.projects, d, name))
            except (OSError, UnicodeDecodeError) as e:
                counts["failed"] += 1
                print(f"fail (can't read: {e})\t{key}\t{scope}")
                continue
            except Unsupported as e:
                counts["unsupported"] += 1
                print(f"skip (unsupported frontmatter: {e})\t{key}\t{scope}")
                continue
            body["tags"].insert(0, scope)
            if done is not None and key in done:
                # Imported only if a memory from this path holds this content.
                # The same path with other content (the file was edited, or
                # another machine's file has the same name) is neither skipped
                # silently nor stored again: the person decides.
                if any(same_content(c, body["content"]) for c in done[key]):
                    counts["already imported"] += 1
                    print(f"skip (already imported)\t{key}\t{scope}")
                else:
                    counts["conflict"] += 1
                    print(f"conflict (same source_file, different content)\t{key}\t{scope}")
                continue
            if done is None:
                # A dry run that couldn't ask the store: whether this file is
                # already there is unknown, so it isn't listed as `store`.
                counts["unknown"] += 1
                print(f"unknown (store not reached)\t{key}\t{scope}")
                continue
            if not args.apply:
                print(f"store\t{key}\t{scope}")
                continue
            try:
                answer = http_post(f"{base}/api/memories", body)
            except Exception as e:
                counts["failed"] += 1
                print(f"fail ({e})\t{key}\t{scope}")
                continue
            if isinstance(answer, dict) and answer.get("success") is True:
                counts["stored"] += 1
                print(f"stored\t{key}\t{scope}")
            elif is_duplicate(answer):
                # Not proof this file was imported: the store holds the same
                # content under some memory, perhaps another file's or one
                # stored by hand, with whatever tags that one has.
                counts["duplicate in store"] += 1
                print(f"skip (duplicate content in store)\t{key}\t{scope}")
            else:
                counts["failed"] += 1
                print(f"fail ({failure_message(answer)})\t{key}\t{scope}")

    if args.apply:
        print(", ".join(f"{counts[k]} {k}" for k in (
            "stored", "already imported", "duplicate in store", "conflict",
            "skipped", "unsupported", "symlinked", "failed")))
    # A dry run that couldn't ask the store hasn't checked anything, and one
    # with unmapped files exits 1 as `--apply` would (it refuses above). A
    # symlinked file exits 1 in both, so it isn't missed before auto memory
    # is turned off.
    return 1 if (done is None or unmapped or counts["failed"] or counts["unsupported"]
                 or counts["conflict"] or counts["symlinked"]) else 0


if __name__ == "__main__":
    sys.exit(main())
