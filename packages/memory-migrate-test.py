"""Cases for memory-migrate.py: python3 -I memory-migrate-test.py.

HTTP is replaced by fakes that record each call and answer from a list, so no
socket is opened. Each case builds a projects tree in a temporary directory.
"""

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location(
    "migrate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-migrate.py"))
migrate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migrate)
# run() swaps the http functions for fakes; the real one is kept for its own cases.
REAL_POST = migrate.http_post

BASE = "https://m.example.ts.net"
passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"ok   {name}")
    else:
        failed += 1
        print(f"FAIL {name}{': ' + str(detail) if detail else ''}")


class Fake:
    """Stands in for http_get and http_post: records calls, answers in turn."""

    def __init__(self, gets=None, posts=None):
        self.calls = []
        self.gets = list(gets or [])
        self.posts = list(posts or [])

    def get(self, url):
        self.calls.append(("GET", url, None))
        answer = self.gets.pop(0) if self.gets else {"memories": [], "has_more": False}
        if isinstance(answer, Exception):
            raise answer
        return answer

    def post(self, url, body):
        self.calls.append(("POST", url, body))
        answer = self.posts.pop(0) if self.posts else {"success": True, "message": "ok"}
        if isinstance(answer, Exception):
            raise answer
        return answer

    def methods(self):
        return [c[0] for c in self.calls]

    def bodies(self):
        return [c[2] for c in self.calls if c[0] == "POST"]


def tree(files):
    """A projects tree: {"<dir>/<name>": text}. Returns its path."""
    root = tempfile.mkdtemp()
    for key, text in files.items():
        d, name = key.split("/", 1)
        os.makedirs(os.path.join(root, d, "memory"), exist_ok=True)
        with open(os.path.join(root, d, "memory", name), "w", encoding="utf-8") as f:
            f.write(text)
    return root


def snapshot(root):
    """Every path under root with its bytes and mtime (lstat, links not followed)."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for n in dirnames + filenames:
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            data = None
            if os.path.isfile(p) and not os.path.islink(p):
                with open(p, "rb") as f:
                    data = f.read()
            out[p] = (data, st.st_mtime_ns, st.st_mode)
    return out


def run(projects, table=None, apply=False, fake=None, url=BASE, extra=()):
    """Runs main with the fakes; returns (code, stdout, stderr, fake)."""
    fake = fake or Fake()
    migrate.http_get = fake.get
    migrate.http_post = fake.post
    argv = ["--projects", projects]
    if table is None:
        argv += ["--list"]
    else:
        path = os.path.join(tempfile.mkdtemp(), "table.tsv")
        with open(path, "w", encoding="utf-8") as f:
            f.write(table)
        argv += ["--map", path]
    if apply:
        argv += ["--apply"]
    if url is not None:
        argv += ["--url", url]
    argv += list(extra)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = migrate.main(argv)
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue(), fake


APP = "-Users-x-Projects-app"
LIB = "-Users-x-Projects-lib"
BUILD = """---
name: build-notes
description: How the build is run
metadata:
  type: project
---

Run the build with make.
Then test.
"""
NO_PIPES = """---
name: no-pipes
description: "Plain commands: no pipes"
metadata:
  type: feedback
---
Use plain commands.
"""


def base_tree():
    return tree({
        f"{APP}/build-notes.md": BUILD,
        f"{APP}/no-pipes.md": NO_PIPES,
        f"{APP}/MEMORY.md": "- [Build](build-notes.md)\n",
        f"{LIB}/plain.md": "First line of a plain note\nSecond line\n",
    })


# --- --list -------------------------------------------------------------------

root = base_tree()
os.makedirs(os.path.join(root, "-Users-x-empty", "memory"))
code, out, err, fake = run(root)
check("--list: exit 0", code == 0, (code, err))
check("--list: each dir with its count, MEMORY.md not counted",
      out == f"{APP}\t2\n{LIB}\t1\n", out)
check("--list: contacts nothing", fake.calls == [], fake.calls)

# --- Existing auto memory files can be imported ------------------------------

root = base_tree()
before = snapshot(root)
table = f"# scopes\n\n{APP}\tscope:project:acme/app\n{APP}/no-pipes.md\tscope:org\n{LIB}\tscope:user:someone\n"
code, out, err, fake = run(root, table, apply=True)
check("apply: exit 0", code == 0, (code, out, err))
bodies = {b["metadata"]["source_file"]: b for b in fake.bodies()}
b = bodies.get(f"{APP}/build-notes.md")
check("a mapped project: stored once", b is not None and len(fake.bodies()) == 3, fake.calls)
check("... tagged scope, type, source",
      b and b["tags"] == ["scope:project:acme/app", "type:project", "source:auto-memory"], b)
check("... first line is the description",
      b and b["content"].split("\n")[0] == "How the build is run", b)
check("... then a blank line and the body",
      b and b["content"] == "How the build is run\n\nRun the build with make.\nThen test.", b)
check("... metadata name, description, source, source_file",
      b and b["metadata"] == {"name": "build-notes", "description": "How the build is run",
                              "source": "auto-memory", "source_file": f"{APP}/build-notes.md"}, b)
check("... no memory_type sent", b and "memory_type" not in b, b)
check("... POSTed to <base>/api/memories",
      all(c[1] == f"{BASE}/api/memories" for c in fake.calls if c[0] == "POST"), fake.calls)
n = bodies.get(f"{APP}/no-pipes.md")
check("a row for one file: that file under its own scope",
      n and n["tags"][0] == "scope:org", n)
check("a quoted description with a colon: read as a JSON string",
      n and n["content"].split("\n")[0] == "Plain commands: no pipes", n)
p = bodies.get(f"{LIB}/plain.md")
check("a file without frontmatter: its file name as its name",
      p and p["metadata"]["name"] == "plain", p)
check("... its first line as its summary",
      p and p["content"].split("\n")[0] == "First line of a plain note", p)
check("... and no type: tag", p and p["tags"] == ["scope:user:someone", "source:auto-memory"], p)
check("MEMORY.md is not imported", f"{APP}/MEMORY.md" not in bodies, list(bodies))
check("the files afterwards: byte for byte and mtimes unchanged", snapshot(root) == before)
check("apply prints the counts", "3 stored" in out and "0 failed" in out, out)

# A top-level type, a single-quoted value, a symlinked .md.
root = tree({
    f"{APP}/top.md": "---\nname: 'top-type'\ndescription: Top level\ntype: user\n---\nBody\n",
    f"{APP}/odd.md": "---\nname: odd\nmetadata:\n  type: Not A Type\n---\nBody\n",
    f"{APP}/target.txt": "not markdown\n",
})
os.symlink(os.path.join(root, APP, "memory", "target.txt"),
           os.path.join(root, APP, "memory", "linked.md"))
before = snapshot(root)
code, out, err, fake = run(root, f"{APP}\tscope:org\n", apply=True)
bodies = {b["metadata"]["source_file"]: b for b in fake.bodies()}
t = bodies.get(f"{APP}/top.md")
check("a top-level type: tagged", t and "type:user" in t["tags"], t)
check("a single-quoted value: unquoted", t and t["metadata"]["name"] == "top-type", t)
o = bodies.get(f"{APP}/odd.md")
check("a type that isn't [a-z0-9-]+: no type tag",
      o and not any(x.startswith("type:") for x in o["tags"]), o)
check("... summary falls back to the name", o and o["content"].startswith("odd\n\n"), o)
check("a symlinked .md is not imported", f"{APP}/linked.md" not in bodies, list(bodies))
check("... nor a .txt", f"{APP}/target.txt" not in bodies, list(bodies))
check("... and the link is untouched", snapshot(root) == before)
check("... it is reported with --apply", f"skip (symlink, not imported)\t{APP}/linked.md" in out, out)
check("... counted apart", "1 symlinked" in out, out)
check("... the other files still stored", len(fake.bodies()) == 2, fake.calls)
check("... and --apply exits 1", code == 1, (code, out, err))

# Symlinks in --list and a dry run, a dangling one and a dir holding only links.
os.symlink(os.path.join(root, "nowhere.md"), os.path.join(root, APP, "memory", "dangling.md"))
os.makedirs(os.path.join(root, LIB, "memory"))
os.symlink(os.path.join(root, APP, "memory", "top.md"), os.path.join(root, LIB, "memory", "only.md"))
code, out, err, fake = run(root)
check("--list: symlinks counted per dir, links-only dir listed",
      out == f"{APP}\t2\t2 symlinked, not imported\n{LIB}\t0\t1 symlinked, not imported\n", out)
check("... and --list still exits 0", code == 0, (code, err))
code, out, err, fake = run(root, f"{APP}\tscope:org\n")
check("a dry run reports each symlink, dangling or in a links-only dir",
      all(f"skip (symlink, not imported)\t{k}" in out
          for k in (f"{APP}/linked.md", f"{APP}/dangling.md", f"{LIB}/only.md")), out)
check("... a links-only dir is not unmapped", "unmapped" not in out, out)
check("... the regular files still listed", f"store\t{APP}/top.md\tscope:org" in out, out)
check("... and the dry run exits 1", code == 1, (code, out, err))
check("... nothing POSTed", "POST" not in fake.methods(), fake.calls)
code, out, err, fake = run(root, f"{APP}/linked.md\tscope:org\n{APP}\tscope:org\n")
check("a table row naming a symlink names nothing: exit 2, no call",
      code == 2 and fake.calls == [], (code, out, err, fake.calls))
for apply in (False, True):
    tag = " (--apply)" if apply else ""
    code, out, err, fake = run(root, f"{APP}\tscope:org\n{LIB}\tskip\n", apply=apply)
    check(f"a row for a links-only dir, as --list prints it, is accepted{tag}",
          code == 1 and "names no directory" not in err
          and f"skip (symlink, not imported)\t{LIB}/only.md" in out, (code, out, err))
    check(f"... its link still never stored{tag}",
          not any(b["metadata"]["source_file"].startswith(LIB + "/") for b in fake.bodies()),
          fake.calls)
code, out, err, fake = run(root, f"{APP}\tscope:org\n{LIB}\tscope:org\n", apply=True)
check("... mapped to a scope too, and the other dir's files still stored",
      code == 1 and len(fake.bodies()) == 2
      and all(b["metadata"]["source_file"].startswith(APP + "/") for b in fake.bodies()),
      (code, out, err, fake.calls))
code, out, err, fake = run(root, f"{APP}\tscope:org\n-Users-x-nowhere\tskip\n")
check("a row for a dir --list doesn't print still exits 2, no call",
      code == 2 and fake.calls == [] and "names no directory" in err, (code, err))

# YAML's own rules for the values it reads: `''`, comments, null, a BOM.
EDGES = {
    "squote.md": "---\nname: squote\ndescription: 'Don''t pipe, it''s slow'\n---\nBody\n",
    "squote-end.md": "---\nname: se\ndescription: 'ends in a quote '''\n---\nBody\n",
    "dq-comment.md": "---\nname: dqc\ndescription: \"Quoted: yes\"  # why it's quoted\n---\nBody\n",
    "sq-comment.md": "---\nname: sqc\ndescription: 'Single' # note\n---\nBody\n",
    "plain-issue.md": "---\nname: pi\ndescription: on hold until #107 lands\n---\nBody\n",
    "plain-hash.md": "---\nname: ph\ndescription: Issue#12 stays\n---\nBody\n",
    "plain-lead.md": "---\nname: pl\ndescription: #107 first\n---\nBody\n",
    "plain-null.md": "---\nname: pn\ndescription: null # unset\n---\nBody\n",
    "tilde.md": "---\nname: tilde-name\ndescription: ~\n---\nBody\n",
    "null.md": "---\nname: null-name\ndescription: null\n---\nBody\n",
    "empty.md": "---\nname: empty-name\ndescription:\n---\nBody\n",
    "bom.md": "﻿---\nname: bom\ndescription: After a BOM\n---\nBody\n",
    "bom-plain.md": "﻿A plain note after a BOM\n",
    "meta-comment.md": "---\nname: mc\nmetadata:  # nested below\n  type: project\n---\nBody\n",
    "meta-hash.md": "---\nname: mh\nmetadata:#x\n---\nBody\n",
    "crlf.md": "---\r\nname: crlf\r\ndescription: Windows line ends\r\nmetadata:\r\n  type: project\r\n---\r\nFirst\r\nSecond\r\n",
    "cr.md": "---\rname: cr\rdescription: Old Mac line ends\r---\rOnly\r",
    "crlf-plain.md": "A plain note\r\nwith a second line\r\n",
    "upper-type.md": "---\nname: ut\nmetadata:\n  type: Project\n---\nBody\n",
    "upper-top-type.md": "---\nname: utt\ntype: FEEDBACK\n---\nBody\n",
}
root = tree({f"{APP}/{n}": t for n, t in EDGES.items()})
code, out, err, fake = run(root, f"{APP}\tscope:org\n", apply=True)
bodies = {b["metadata"]["source_file"].split("/", 1)[1]: b for b in fake.bodies()}


def summary(n):
    b = bodies.get(n)
    return b and b["content"].split("\n")[0]


check("frontmatter edge cases: all stored, exit 0",
      code == 0 and set(bodies) == set(EDGES), (code, out, sorted(bodies)))
check("'' inside single quotes is one '", summary("squote.md") == "Don't pipe, it's slow", bodies.get("squote.md"))
check("... also just before the closing quote", summary("squote-end.md") == "ends in a quote '", bodies.get("squote-end.md"))
check("a comment after a double-quoted value: dropped", summary("dq-comment.md") == "Quoted: yes", bodies.get("dq-comment.md"))
check("a comment after a single-quoted value: dropped", summary("sq-comment.md") == "Single", bodies.get("sq-comment.md"))
check("' #' in a plain value is text: an issue number is kept",
      summary("plain-issue.md") == "on hold until #107 lands"
      and bodies["plain-issue.md"]["metadata"]["description"] == "on hold until #107 lands",
      bodies.get("plain-issue.md"))
check("... as is a # with no space before it", summary("plain-hash.md") == "Issue#12 stays", bodies.get("plain-hash.md"))
check("... and one that starts the value", summary("plain-lead.md") == "#107 first", bodies.get("plain-lead.md"))
check("... so `null # unset` is text, not no value", summary("plain-null.md") == "null # unset", bodies.get("plain-null.md"))
for n, name in [("tilde.md", "tilde-name"), ("null.md", "null-name"),
                ("empty.md", "empty-name")]:
    b = bodies.get(n)
    check(f"no value ({n}): the summary falls back to the name, description empty",
          b and summary(n) == name and b["metadata"]["description"] == "", b)
check("a leading BOM: the frontmatter is read", summary("bom.md") == "After a BOM"
      and bodies["bom.md"]["metadata"]["name"] == "bom", bodies.get("bom.md"))
check("... and isn't stored in a plain note",
      bodies.get("bom-plain.md") and bodies["bom-plain.md"]["content"] == "A plain note after a BOM",
      bodies.get("bom-plain.md"))
check("`metadata:  # comment` opens the nested block",
      bodies.get("meta-comment.md") and "type:project" in bodies["meta-comment.md"]["tags"],
      bodies.get("meta-comment.md"))
check("... `metadata:#x` (no space before #) is a value, not a block",
      bodies.get("meta-hash.md") and not any(x.startswith("type:") for x in bodies["meta-hash.md"]["tags"]),
      bodies.get("meta-hash.md"))
c = bodies.get("crlf.md")
check("CRLF line ends: frontmatter read, body stored with LF only",
      c and c["content"] == "Windows line ends\n\nFirst\nSecond" and "type:project" in c["tags"]
      and c["metadata"]["name"] == "crlf", c)
c = bodies.get("cr.md")
check("... lone CR line ends too", c and c["content"] == "Old Mac line ends\n\nOnly", c)
c = bodies.get("crlf-plain.md")
check("... and a plain note", c and c["content"] == "A plain note\nwith a second line", c)
check("no body holds a CR", not any("\r" in b["content"] for b in bodies.values()), list(bodies))
check("a type in capitals is lower-cased: metadata",
      bodies.get("upper-type.md") and "type:project" in bodies["upper-type.md"]["tags"], bodies.get("upper-type.md"))
check("... and top-level",
      bodies.get("upper-top-type.md") and "type:feedback" in bodies["upper-top-type.md"]["tags"],
      bodies.get("upper-top-type.md"))

# --- The import writes only when told, and only once -------------------------

root = base_tree()
code, out, err, fake = run(root, table)
check("a dry run: exit 0", code == 0, (code, err))
check("... sends no POST", "POST" not in fake.methods(), fake.calls)
check("... no call other than GET", set(fake.methods()) <= {"GET"}, fake.calls)
check("... lists each file with its scope",
      f"store\t{APP}/build-notes.md\tscope:project:acme/app" in out
      and f"store\t{APP}/no-pipes.md\tscope:org" in out
      and f"store\t{LIB}/plain.md\tscope:user:someone" in out, out)
check("... asks for source:auto-memory, 100 a page",
      fake.calls and "tag=source%3Aauto-memory" in fake.calls[0][1]
      and "page_size=100" in fake.calls[0][1]
      and fake.calls[0][1].startswith(f"{BASE}/api/memories?"), fake.calls)

code, out, err, fake = run(root, f"{APP}\tskip\n")
check("dry run, a skip row and an unmapped dir",
      f"skip (table)\t{APP}/build-notes.md" in out and f"unmapped\t{LIB}/plain.md" in out, out)
check("... no POST", "POST" not in fake.methods(), fake.calls)
check("... exit 1, as --apply would refuse it", code == 1, (code, out, err))
code, out, err, fake = run(root, f"{APP}\tskip\n{LIB}\tskip\n")
check("a dry run with every dir mapped or skipped: exit 0", code == 0, (code, out, err))

code, out, err, fake = run(root, f"{APP}\tscope:org\n", apply=True)
check("an unmapped directory with --apply: non-zero", code not in (0, None), code)
check("... nothing stored, nothing asked", fake.calls == [], fake.calls)
check("... the directory is named", LIB in err, err)

code, out, err, fake = run(root, f"{APP}\tscope:org\n{LIB}\tskip\n", apply=True)
check("every dir mapped or skipped: stores", code == 0 and len(fake.bodies()) == 2, (code, out, err))

# A second run: the store now reports every file as imported, over two pages.
BUILD_CONTENT = "How the build is run\n\nRun the build with make.\nThen test."
NO_PIPES_CONTENT = "Plain commands: no pipes\n\nUse plain commands."
PLAIN_CONTENT = "First line of a plain note\nSecond line"


def mem(source, content):
    return {"content": content, "metadata": {"source_file": source}}


stored = [mem(f"{APP}/build-notes.md", BUILD_CONTENT),
          mem(f"{APP}/no-pipes.md", NO_PIPES_CONTENT + "\n")]
fake = Fake(gets=[{"memories": stored[:1], "has_more": True},
                  {"memories": stored[1:] + [mem(f"{LIB}/plain.md", PLAIN_CONTENT)],
                   "has_more": False}])
code, out, err, fake = run(root, table, apply=True, fake=fake)
check("a second run: stores nothing", fake.bodies() == [], fake.calls)
check("... pages until has_more is false",
      fake.methods() == ["GET", "GET"] and "page=2" in fake.calls[1][1], fake.calls)
check("... reports each as already imported (ends trimmed)",
      out.count("skip (already imported)") == 3, out)
check("... exit 0", code == 0, code)

# The same source_file with other content: a conflict, never stored, exit 1.
for label, other in [("different content", mem(f"{APP}/build-notes.md", "An older summary\n\nOld body")),
                     ("no content field", {"metadata": {"source_file": f"{APP}/build-notes.md"}})]:
    fake = Fake(gets=[{"memories": [other, mem(f"{APP}/no-pipes.md", NO_PIPES_CONTENT),
                                    mem(f"{LIB}/plain.md", PLAIN_CONTENT)], "has_more": False}])
    code, out, err, fake = run(root, table, apply=True, fake=fake)
    check(f"same source_file, {label}: a conflict",
          f"conflict (same source_file, different content)\t{APP}/build-notes.md\tscope:project:acme/app" in out, out)
    check("... not stored", fake.bodies() == [], fake.calls)
    check("... exit 1, counted", code == 1 and "1 conflict" in out and "2 already imported" in out, (code, out))
fake = Fake(gets=[{"memories": [mem(f"{APP}/build-notes.md", "Old"),
                                mem(f"{APP}/build-notes.md", BUILD_CONTENT)], "has_more": False}])
code, out, err, fake = run(root, table, fake=fake)
check("one of two memories from the path matches: already imported",
      f"skip (already imported)\t{APP}/build-notes.md" in out and "conflict" not in out, out)
fake = Fake(gets=[{"memories": [mem(f"{APP}/build-notes.md", "Old")], "has_more": False}])
code, out, err, fake = run(root, table, fake=fake)
check("a conflict in a dry run: listed, exit 1, no POST",
      code == 1 and f"conflict (same source_file, different content)\t{APP}/build-notes.md" in out
      and "POST" not in fake.methods(), (code, out))

fake = Fake(posts=[{"success": False, "message": "Duplicate content detected"},
                   {"success": True}, {"success": True}])
code, out, err, fake = run(root, table, apply=True, fake=fake)
check("a duplicate refusal: its own outcome, not 'already imported'",
      code == 0 and f"skip (duplicate content in store)\t{APP}/build-notes.md" in out
      and "skip (already imported)" not in out, (code, out))
check("... counted apart",
      "1 duplicate in store" in out and "0 already imported" in out and "2 stored" in out, out)

# What http_post returns for a 409 with only `detail`, and for 5xx answers that
# mention a duplicate.
fake = Fake(posts=[{"detail": "Duplicate content", migrate.HTTP_STATUS: 409},
                   {"success": False, "message": "duplicate key in index", migrate.HTTP_STATUS: 500},
                   {"detail": "Duplicate check failed", migrate.HTTP_STATUS: 503}])
code, out, err, fake = run(root, table, apply=True, fake=fake)
check("a 409 with only `detail` saying duplicate: a duplicate",
      f"skip (duplicate content in store)\t{APP}/build-notes.md" in out, out)
check("a 500 whose message mentions a duplicate: a failure",
      f"fail (duplicate key in index)\t{APP}/no-pipes.md" in out, out)
check("... a 503 whose detail does too",
      f"fail (Duplicate check failed)\t{LIB}/plain.md" in out, out)
check("... counted, exit 1",
      code == 1 and "1 duplicate in store" in out and "2 failed" in out, (code, out))

fake = Fake(posts=[RuntimeError("boom"), {"success": True}, {"success": False, "message": "nope"}])
before = snapshot(root)
code, out, err, fake = run(root, table, apply=True, fake=fake)
check("a POST failure: the others still tried", len(fake.bodies()) == 3, fake.calls)
check("... exit 1", code == 1, code)
check("... counts", "1 stored" in out and "2 failed" in out, out)
check("... files unchanged", snapshot(root) == before)

fake = Fake(gets=[OSError("connection refused")])
code, out, err, fake = run(root, table, apply=True, fake=fake)
check("store unreachable with --apply: exit 1, no POST",
      code == 1 and "POST" not in fake.methods(), (code, fake.calls))
check("... says so, and to run from a terminal",
      "couldn't be reached" in err and "terminal" in err, err)
fake = Fake(gets=[OSError("connection refused")])
code, out, err, fake = run(root, table, fake=fake)
check("store unreachable, dry run: exit 1", code == 1, (code, out, err))
check("... no file listed as 'store'",
      not any(line.startswith("store\t") for line in out.splitlines()), out)
check("... every file it would have checked is unknown",
      out.count("unknown (store not reached)\t") == 3
      and f"unknown (store not reached)\t{APP}/build-notes.md\tscope:project:acme/app" in out, out)
check("... no POST", "POST" not in fake.methods(), fake.calls)
check("... says so", "couldn't be reached" in err, err)
fake = Fake(gets=[OSError("connection refused")])
code, out, err, fake = run(root, f"{APP}\tskip\n{LIB}\tskip\n", fake=fake)
check("store unreachable, dry run, every file skipped: still exit 1", code == 1, (code, out))
code, out, err, fake = run(root, table, apply=True, url="")
check("no URL with --apply: exit 1, no call", code == 1 and fake.calls == [], (code, fake.calls))
code, out, err, fake = run(root, table, url="")
check("no URL, dry run: exit 1, no call, states unknown",
      code == 1 and fake.calls == [] and "store\t" not in out
      and out.count("unknown (store not reached)") == 3, (code, out, fake.calls))

# --- The store URL is checked as the hook checks it ----------------------------

root = base_tree()
for bad in ["m.example.ts.net", "ftp://h", "https://u:p@h", "https://u@h", "https://h?x=1",
            "https://h#f", "https://h/a b", "https://h:port", "file:///tmp/x", " https://h"]:
    for apply in (False, True):
        code, out, err, fake = run(root, table, apply=apply, url=bad)
        check(f"bad --url {bad!r}{', --apply' if apply else ''}: exit 2, no call",
              code == 2 and fake.calls == [] and "store URL" in err, (code, err, fake.calls))
code, out, err, fake = run(root, table, url="https://user:s3cret@h/")
check("a bad --url: its value (a password, say) isn't echoed",
      code == 2 and "s3cret" not in err and "s3cret" not in out, (code, out, err))
old = os.environ.get("COLDLOGIC_MEMORY_URL")
os.environ["COLDLOGIC_MEMORY_URL"] = "https://u:p@h/"
try:
    code, out, err, fake = run(root, table, url=None)
finally:
    if old is None:
        del os.environ["COLDLOGIC_MEMORY_URL"]
    else:
        os.environ["COLDLOGIC_MEMORY_URL"] = old
check("a bad $COLDLOGIC_MEMORY_URL: exit 2, no call",
      code == 2 and fake.calls == [] and "COLDLOGIC_MEMORY_URL" in err, (code, err, fake.calls))
for good in ["https://m.example.ts.net/", "http://10.0.0.5:8000", "https://h/base/path///"]:
    code, out, err, fake = run(root, table, url=good)
    check(f"good --url {good!r}: asks the store without trailing slashes",
          code == 0 and fake.calls and fake.calls[0][1].startswith(good.rstrip("/") + "/api/memories?"),
          (code, err, fake.calls))

# --- Frontmatter it can't read is never stored ---------------------------------

UNSUPPORTED = {
    "folded.md": "---\nname: folded\ndescription: >\n  A folded\n  description\n---\nBody\n",
    "literal.md": "---\nname: literal\ndescription: |-\n  A literal\n---\nBody\n",
    "keep.md": "---\nname: keep\ndescription: >+ # a comment\n  text\n---\nBody\n",
    "indicator.md": "---\nname: ind\ndescription: |2\n    text\n---\nBody\n",
    "meta-block.md": "---\nname: mb\nmetadata:\n  type: >\n    project\n---\nBody\n",
    "continued.md": "---\nname: cont\ndescription: The first part\n  and the rest\n---\nBody\n",
    "continued-plain.md": "---\nname: cp\ndescription: The first part\nand the rest\n---\nBody\n",
    "unclosed.md": "---\nname: uq\ndescription: \"An open quote\n  closed later\"\n---\nBody\n",
    "deeper.md": "---\nname: deep\nmetadata:\n  type: project\n    extra: x\n---\nBody\n",
    "dq-trailing.md": "---\nname: dqt\ndescription: \"Quoted\" and more\n---\nBody\n",
    "sq-trailing.md": "---\nname: sqt\ndescription: 'Quoted' and more\n---\nBody\n",
    "sq-unclosed.md": "---\nname: squ\ndescription: 'It''s open\n---\nBody\n",
    "dq-bad-escape.md": "---\nname: dqe\ndescription: \"A YAML \\x41 escape\"\n---\nBody\n",
    "never-closed.md": "---\nname: nc\ndescription: no closing line\n\nThe body\n",
    "never-closed-crlf.md": "---\r\nname: ncc\r\nThe body\r\n",
}
root = tree({f"{APP}/{n}": t for n, t in UNSUPPORTED.items()} | {f"{APP}/fine.md": NO_PIPES})
before = snapshot(root)
code, out, err, fake = run(root, f"{APP}\tscope:org\n", apply=True)
stored = {b["metadata"]["source_file"] for b in fake.bodies()}
check("unsupported frontmatter: only the readable file stored",
      stored == {f"{APP}/fine.md"}, sorted(stored))
for n in UNSUPPORTED:
    check(f"... {n}: skip (unsupported frontmatter)",
          any(line.startswith("skip (unsupported frontmatter") and f"\t{APP}/{n}\t" in line
              for line in out.splitlines()), out)
check("frontmatter never closed: `skip (unsupported frontmatter: unclosed)`",
      all(f"skip (unsupported frontmatter: unclosed)\t{APP}/{n}\t" in out
          for n in ("never-closed.md", "never-closed-crlf.md")), out)
check("... and no body starts with `---`",
      not any(b["content"].startswith("---") for b in fake.bodies()), fake.bodies())
check("... no body holds a bare '>' or '|' summary",
      not any(b["content"].split("\n")[0] in (">", "|", "|-", ">+") for b in fake.bodies()), fake.bodies())
check("... counted, and exit 1", code == 1 and f"{len(UNSUPPORTED)} unsupported" in out, (code, out))
check("... files unchanged", snapshot(root) == before)
code, out, err, fake = run(root, f"{APP}\tscope:org\n")
check("unsupported frontmatter, dry run: listed, exit 1, no POST",
      code == 1 and out.count("skip (unsupported frontmatter") == len(UNSUPPORTED)
      and f"store\t{APP}/fine.md\tscope:org" in out and "POST" not in fake.methods(), (code, out))
code, out, err, fake = run(root, f"{APP}\tscope:org\n{APP}/folded.md\tskip\n" + "".join(
    f"{APP}/{n}\tskip\n" for n in UNSUPPORTED if n != "folded.md"), apply=True)
check("... a skip row for each: exit 0", code == 0 and "0 unsupported" in out, (code, out))

# --- Malformed tables exit 2 with no HTTP call --------------------------------

root = base_tree()
for name, bad in [
    ("no tab", f"{APP} scope:org\n"),
    ("three fields", f"{APP}\tscope:org\textra\n"),
    ("empty scope", f"{APP}\t\n"),
    ("unknown scope form", f"{APP}\tscope:team:x\n"),
    ("project without repo", f"{APP}\tscope:project:acme\n"),
    ("project with ..", f"{APP}\tscope:project:../app\n"),
    ("project whose repo is only .git", f"{APP}\tscope:project:acme/.git\n"),
    ("user with a bad login", f"{APP}\tscope:user:-x\n"),
    ("a non-ASCII letter that lower() folds to ASCII", f"{APP}\tscope:user:Kate\n"),
    ("project with a non-ASCII owner", f"{APP}\tscope:project:Kcme/app\n"),
    ("an upper-case prefix", f"{APP}\tScope:Org\n"),
    ("an upper-case scope kind", f"{APP}\tscope:User:x\n"),
    ("a dir that names nothing", "-Users-x-none\tscope:org\n"),
    ("a file that names nothing", f"{APP}/none.md\tscope:org\n"),
    ("MEMORY.md as a key", f"{APP}/MEMORY.md\tscope:org\n"),
    ("a key mapped twice", f"{APP}\tscope:org\n{APP}\tskip\n"),
]:
    for apply in (False, True):
        code, out, err, fake = run(root, bad, apply=apply)
        check(f"malformed table ({name}{', --apply' if apply else ''}): exit 2, no call",
              code == 2 and fake.calls == [], (code, err, fake.calls))

# --- Table scopes are lower-cased as the hook derives them ---------------------

root = base_tree()
code, out, err, fake = run(
    root, f"{APP}\tscope:project:Acme/App.Web\n{LIB}\tscope:user:SomeOne\n", apply=True)
tags = sorted(b["tags"][0] for b in fake.bodies())
check("upper-case owner, repo and login: accepted, exit 0", code == 0, (code, out, err))
check("... stored under the lower-cased scopes",
      tags == ["scope:project:acme/app.web", "scope:project:acme/app.web", "scope:user:someone"], tags)
check("... and reported lower-cased",
      f"stored\t{APP}/build-notes.md\tscope:project:acme/app.web" in out
      and f"stored\t{LIB}/plain.md\tscope:user:someone" in out, out)
code, out, err, fake = run(root, f"{APP}\tscope:project:Acme/app\n{APP}\tscope:project:acme/app\n")
check("a key mapped twice, differing only in case: still exit 2", code == 2 and fake.calls == [], (code, err))
code, out, err, fake = run(
    root, f"{APP}\tscope:project:Acme/App.GIT\n{LIB}\tscope:project:acme/lib.git.git\n", apply=True)
tags = {b["metadata"]["source_file"].split("/")[0]: b["tags"][0] for b in fake.bodies()}
check("a repo's trailing .git dropped (after lower-casing), as the hook drops it",
      code == 0 and tags.get(APP) == "scope:project:acme/app", (code, tags, err))
check("... only one", tags.get(LIB) == "scope:project:acme/lib.git", tags)

# --- A failed POST says why, never None ----------------------------------------

root = tree({f"{APP}/a.md": "A\n", f"{APP}/b.md": "B\n", f"{APP}/c.md": "C\n",
             f"{APP}/d.md": "D\n", f"{APP}/e.md": "E\n"})
fake = Fake(posts=[
    {"success": False, "detail": "Field required: content"},
    {"success": False, migrate.HTTP_STATUS: 503},
    {"success": False, "message": None, "detail": [{"loc": ["body"], "msg": "bad"}]},
    {"success": False, "message": "two\nlines\tand a tab"},
    {"success": False},
])
code, out, err, fake = run(root, f"{APP}\tscope:org\n", apply=True, fake=fake)
lines = {line.split("\t")[1]: line.split("\t")[0] for line in out.splitlines() if "\t" in line}
check("a failure with only `detail`: reports it",
      lines.get(f"{APP}/a.md") == "fail (Field required: content)", lines)
check("a failure with neither: reports the HTTP status", lines.get(f"{APP}/b.md") == "fail (HTTP 503)", lines)
check("a structured `detail`: reported as JSON",
      lines.get(f"{APP}/c.md") == 'fail ([{"loc": ["body"], "msg": "bad"}])', lines)
check("a message with a newline or tab: one line, no extra row",
      lines.get(f"{APP}/d.md") == "fail (two lines and a tab)"
      and "lines" not in [line.split("\t")[0] for line in out.splitlines()], out)
check("a failure with no reason at all: says so, not None",
      lines.get(f"{APP}/e.md") == "fail (no reason given)", lines)
check("... no failure reads None", "None" not in out, out)
check("... all counted as failed, exit 1", code == 1 and "5 failed" in out, (code, out))


class _Raising:
    """An opener whose open raises the given HTTPError."""

    def __init__(self, code, body):
        self.code, self.body = code, body

    def open(self, req, timeout=None):
        raise migrate.urllib.error.HTTPError(
            req.full_url, self.code, "status", {}, io.BytesIO(self.body))


real_opener = migrate._OPENER
try:
    migrate._OPENER = _Raising(422, b'{"detail": "Unprocessable"}')
    a = REAL_POST("https://h/api/memories", {})
    check("http_post on an error status: the body plus the status",
          a == {"detail": "Unprocessable", migrate.HTTP_STATUS: 422}, a)
    migrate._OPENER = _Raising(500, b'"just a string"')
    a = REAL_POST("https://h/api/memories", {})
    check("... a body that isn't an object: kept as detail",
          a == {"detail": "just a string", migrate.HTTP_STATUS: 500}, a)
    migrate._OPENER = _Raising(502, b"<html>Bad gateway</html>")
    try:
        REAL_POST("https://h/api/memories", {})
        check("... a body that isn't JSON: the HTTP error is raised", False)
    except migrate.urllib.error.HTTPError as e:
        check("... a body that isn't JSON: the HTTP error is raised", e.code == 502, e)
finally:
    migrate._OPENER = real_opener

# --- The real http functions: no proxy, no redirects ---------------------------

handlers = [type(h).__name__ for h in migrate._OPENER.handlers]
check("the opener has no proxy from the environment",
      all(not getattr(h, "proxies", None) for h in migrate._OPENER.handlers), handlers)
check("the opener refuses redirects", "_NoRedirect" in handlers, handlers)
check("timeout is 10 seconds", migrate.TIMEOUT == 10)

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
