#!/usr/bin/env python3
"""
Detect calls that make wlroots configure a surface too early.

wlroots >= 0.18 refuses to configure a surface before its first commit:
wlr_xdg_surface_schedule_configure() starts with assert(surface->initialized)
and wlr_layer_surface_v1_configure() with assert(surface->initialized). Both
are reached through a long chain of public functions (set_size, set_tiled,
unconstrain_from_box, decoration set_mode, ...), and calling any of them on a
surface that is not initialized aborts the compositor.

This script rebuilds that chain from the wlroots sources shipped in
subprojects/wlroots: it taints every function that calls a seed directly or
transitively, then reports every call to a tainted function in pywm's sources
that is not protected by an "initialized" test or does not happen from the
initial_commit handling.

Deliberate limits: it works on function names, not types, so it is an
over-approximation - that is the point, a false positive is a review question,
a false negative is a compositor abort.

Usage: dev/check-configure-guards.py [--wlroots DIR] [--src DIR] [-q]
Exit code 1 if an unguarded call is found.
"""
import argparse
import os
import re
import sys

SEEDS = (
    "wlr_xdg_surface_schedule_configure",
    "wlr_layer_surface_v1_configure",
)

# Functions that legitimately replay deferred requests. They are only reached
# from the initial_commit branch (check-python-api.sh asserts that separately).
REPLAY_FUNCTIONS = {
    "wm_view_xdg_apply_pending",
    "wm_popup_xdg_unconstrain",
    "wm_popup_layer_unconstrain",
}

KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "case", "do", "else",
    "assert", "defined", "typeof", "alignof", "_Static_assert",
}

GUARD_WINDOW = 20  # lines

FUNC_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_ \t\*]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(([^;{)]*)\)\s*\{",
    re.MULTILINE,
)
CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def strip_comments(text):
    """Replace comments and string literals by spaces, keeping line numbers."""
    out = []
    i, n = 0, len(text)
    state = None  # None, "line", "block", "str", "char"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"
                out.append("  ")
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                out.append("  ")
                i += 2
                continue
            if c == '"':
                state = "str"
                out.append(" ")
                i += 1
                continue
            if c == "'":
                state = "char"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == "line":
            if c == "\n":
                state = None
                out.append(c)
            else:
                out.append(" ")
            i += 1
        elif state == "block":
            if c == "*" and nxt == "/":
                state = None
                out.append("  ")
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        elif state in ("str", "char"):
            if c == "\\":
                out.append("  ")
                i += 2
                continue
            if (state == "str" and c == '"') or (state == "char" and c == "'"):
                state = None
            out.append(" ")
            i += 1
    return "".join(out)


def function_bodies(text):
    """Yield (name, start_line, body) for every function definition."""
    for m in FUNC_RE.finditer(text):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        depth = 1
        i = m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield name, text.count("\n", 0, m.start()) + 1, text[m.end():i - 1]


def collect_functions(paths):
    funcs = {}
    for path in paths:
        if not path.endswith(".c"):
            continue
        text = strip_comments(open(path, errors="replace").read())
        for name, line, body in function_bodies(text):
            calls = {c for c in CALL_RE.findall(body) if c not in KEYWORDS}
            # a function may be defined once per file; merge
            funcs.setdefault(name, set()).update(calls)
    return funcs


def tainted_functions(funcs):
    tainted = set()
    changed = True
    while changed:
        changed = False
        for name, calls in funcs.items():
            if name in tainted:
                continue
            if any(c in SEEDS or c in tainted for c in calls):
                tainted.add(name)
                changed = True
    return tainted


def scan_pywm(paths, tainted):
    findings = []
    checked = 0
    for path in paths:
        if not path.endswith(".c"):
            continue
        text = strip_comments(open(path, errors="replace").read())
        lines = text.split("\n")
        # function -> (start, end)
        spans = []
        for name, start, body in function_bodies(text):
            spans.append((name, start, start + body.count("\n") + 2))

        def enclosing(line_no):
            for name, start, end in spans:
                if start <= line_no <= end:
                    return name
            return "?"

        for idx, line in enumerate(lines, start=1):
            for call in CALL_RE.findall(line):
                if call not in tainted:
                    continue
                checked += 1
                fn = enclosing(idx)
                if fn in REPLAY_FUNCTIONS:
                    continue
                window = "\n".join(lines[max(0, idx - 1 - GUARD_WINDOW):idx])
                if "initialized" in window or "initial_commit" in window:
                    continue
                findings.append((path, idx, fn, call, line.strip()))
    return findings, checked


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--wlroots", default=os.path.join(root, "subprojects", "wlroots"))
    ap.add_argument("--src", default=os.path.join(root, "src"))
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.wlroots):
        print("   cannot read wlroots sources at %s" % args.wlroots)
        return 2

    wlroots_c = []
    for base, _dirs, files in os.walk(args.wlroots):
        for f in files:
            if f.endswith(".c"):
                wlroots_c.append(os.path.join(base, f))

    funcs = collect_functions(wlroots_c)
    tainted = tainted_functions(funcs)

    pywm_c = []
    for base, _dirs, files in os.walk(args.src):
        for f in files:
            if f.endswith(".c"):
                pywm_c.append(os.path.join(base, f))

    findings, checked = scan_pywm(sorted(pywm_c), tainted)

    if not args.quiet:
        rel = os.path.relpath(args.wlroots, root)
        print("   %d wlroots functions scanned, %d call a surface configure"
              % (len(funcs), len([f for f in tainted if f.startswith("wlr_")])))
        interesting = sorted(t for t in tainted
                             if t.startswith("wlr_") and not t.startswith("wlr_xdg_surface_")
                             and not t.startswith("wlr_layer_surface"))
        if interesting:
            print("   configure chain (public entry points pywm may call):")
            for name in interesting:
                print("     %s" % name)

    def display(path):
        rel = os.path.relpath(path, root)
        return path if rel.startswith("..") else rel

    if findings:
        for path, line, fn, call, src in findings:
            print("   %s:%d in %s(): %s" % (display(path), line, fn, call))
        return 1

    if not args.quiet:
        print("   %d calls to those entry points in pywm sources, all guarded"
              % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
