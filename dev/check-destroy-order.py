#!/usr/bin/env python3
"""
Check that pywm removes its listeners before wlroots verifies them.

wlroots 0.20 asserts, when it destroys an object, that a precise list of that
object's signals has no listener left (see DESTRUCTION_ASSERTS below). The
assertions run *after* the object's own destroy signal is emitted, so a
listener attached to that destroy signal can still remove everything, including
itself - wl_signal_emit_mutable() tolerates removal during the emission.

That ordering is what pywm got wrong: it listened to xdg_surface->events.destroy
while wlroots destroys (and checks) the wlr_xdg_toplevel first.

The check is deliberately bounded:

  * types are resolved from the pywm functions' parameters and from the
    struct fields declared in include/ and in subprojects/wlroots/include/;
  * for every object type wlroots checks, pywm must register a listener on that
    object's `events.destroy` (MUST_HANDLE_DESTROY) and must remove each of its
    listeners on that object somewhere in the same file;
  * it does not prove that the removal is reached at run time - the call chain
    goes through function pointers across files - but it does prove that the
    destroy handler exists and that nothing is left dangling, which is what the
    original bug was missing.

Usage: dev/check-destroy-order.py [--src DIR] [--headers DIR ...] [-q]
Exit code 1 on a finding.
"""
import argparse
import os
import re
import sys

# object type -> signals wlroots requires empty at destruction (verified in the
# wlroots sources listed in the comments).
DESTRUCTION_ASSERTS = {
    # types/xdg_shell/wlr_xdg_toplevel.c:548-557
    "wlr_xdg_toplevel": [
        "destroy", "request_maximize", "request_fullscreen", "request_minimize",
        "request_move", "request_resize", "request_show_window_menu",
        "set_parent", "set_title", "set_app_id",
    ],
    # types/xdg_shell/wlr_xdg_popup.c:476-477
    "wlr_xdg_popup": ["destroy", "reposition"],
    # types/xdg_shell/wlr_xdg_surface.c:534-538
    "wlr_xdg_surface": ["destroy", "ping_timeout", "new_popup", "configure",
                        "ack_configure"],
    # types/wlr_layer_shell_v1.c:54-55
    "wlr_layer_surface_v1": ["destroy", "new_popup"],
    # types/wlr_subcompositor.c:36
    "wlr_subsurface": ["destroy"],
    # xwayland/xwm.c:581+
    "wlr_xwayland_surface": ["destroy", "request_configure", "request_move",
                             "request_resize", "request_minimize",
                             "request_maximize", "request_fullscreen",
                             "request_activate"],
    # types/wlr_compositor.c:732-737
    "wlr_surface": ["client_commit", "commit", "map", "unmap", "destroy",
                    "new_subsurface"],
}

# Types for which pywm must react to the destruction itself: it stores pointers
# to them and its teardown releases the view. wlr_surface is not in the list on
# purpose: pywm never listens on its destroy and unbinds everything when the
# owning role object goes away.
MUST_HANDLE_DESTROY = {
    "wlr_xdg_toplevel",
    "wlr_xdg_popup",
    "wlr_xdg_surface",
    "wlr_layer_surface_v1",
    "wlr_subsurface",
    "wlr_xwayland_surface",
}

SIGNAL_ADD_RE = re.compile(
    r"wl_signal_add\(&([A-Za-z_]\w*(?:->\w+)*)->events\.(\w+)\s*,\s*&([A-Za-z_]\w*(?:->\w+)*)\)")
LISTENER_NOTIFY_RE = re.compile(
    r"([A-Za-z_]\w*(?:->\w+)*)\.notify\s*=\s*&?\s*([A-Za-z_]\w*)")
REMOVE_RE = re.compile(r"wl_list_remove\(&([A-Za-z_]\w*(?:->\w+)*)\.link\)")
FUNC_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_ \t\*]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\(([^;{)]*)\)\s*\{",
    re.MULTILINE)
PARAM_RE = re.compile(r"struct\s+(\w+)\s*\*\s*(\w+)")


def strip_comments(text):
    out, i, n, state = [], 0, len(text), None
    while i < n:
        c, nxt = text[i], text[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"; out.append("  "); i += 2; continue
            if c == "/" and nxt == "*":
                state = "block"; out.append("  "); i += 2; continue
            if c in "\"'":
                state = c; out.append(" "); i += 1; continue
            out.append(c); i += 1
        elif state == "line":
            if c == "\n":
                state = None; out.append(c)
            else:
                out.append(" ")
            i += 1
        elif state == "block":
            if c == "*" and nxt == "/":
                state = None; out.append("  "); i += 2; continue
            out.append("\n" if c == "\n" else " "); i += 1
        else:
            if c == "\\":
                out.append("  "); i += 2; continue
            if c == state:
                state = None
            out.append(" "); i += 1
    return "".join(out)


def parse_structs(paths):
    structs = {}
    for path in paths:
        text = strip_comments(open(path, errors="replace").read())
        for m in re.finditer(r"struct\s+(\w+)\s*\{", text):
            name = m.group(1)
            depth, i = 1, m.end()
            while i < len(text) and depth:
                if text[i] == "{":
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                i += 1
            body = text[m.end():i - 1]
            fields = {}
            for fm in re.finditer(r"struct\s+(\w+)\s*\*\s*(\w+)\s*[;,\[]", body):
                fields[fm.group(2)] = fm.group(1)
            structs.setdefault(name, {}).update(fields)
    return structs


def functions(path):
    text = strip_comments(open(path, errors="replace").read())
    for m in FUNC_RE.finditer(text):
        name = m.group(1)
        if name in {"if", "for", "while", "switch", "sizeof", "return"}:
            continue
        params = {p[1]: p[0] for p in PARAM_RE.findall(m.group(2))}
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield name, params, text[m.end():i - 1], text.count("\n", 0, m.start()) + 1


def resolve_type(expr, params, structs):
    parts = expr.split("->")
    t = params.get(parts[0])
    for field in parts[1:]:
        if t is None:
            return None
        t = structs.get(t, {}).get(field)
    return t


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(root, "src"))
    ap.add_argument("--headers", nargs="*", default=[
        os.path.join(root, "include"),
        os.path.join(root, "subprojects", "wlroots", "include"),
    ])
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    header_files = []
    for base in args.headers:
        for d, _s, files in os.walk(base):
            header_files += [os.path.join(d, f) for f in files if f.endswith(".h")]
    structs = parse_structs(header_files)

    sources = []
    for d, _s, files in os.walk(args.src):
        sources += [os.path.join(d, f) for f in files if f.endswith(".c")]

    def display(path):
        rel = os.path.relpath(path, root)
        return path if rel.startswith("..") else rel

    findings = []
    checked = 0
    for path in sorted(sources):
        rel = display(path)
        regs = []          # (type, signal, owner, func, line)
        handlers = {}      # listener field -> function name
        removals = set()   # listener fields removed anywhere in the file

        for fname, params, body, start in functions(path):
            for m in LISTENER_NOTIFY_RE.finditer(body):
                handlers[m.group(1)] = m.group(2)
            for m in REMOVE_RE.finditer(body):
                removals.add(m.group(1))
            for m in SIGNAL_ADD_RE.finditer(body):
                obj, sig, owner = m.group(1), m.group(2), m.group(3)
                t = resolve_type(obj, params, structs)
                if t is None:
                    continue
                line = start + body.count("\n", 0, m.start())
                regs.append((t, sig, owner, fname, line, obj))

        if not regs:
            continue

        types_registered = {}
        for t, sig, owner, fname, line, obj in regs:
            if sig == "destroy":
                types_registered.setdefault(t, set()).add(owner)

        for t, sig, owner, fname, line, obj in regs:
            if t not in DESTRUCTION_ASSERTS:
                continue
            if sig not in DESTRUCTION_ASSERTS[t]:
                continue
            checked += 1
            if t in MUST_HANDLE_DESTROY and t not in types_registered:
                findings.append(
                    "%s:%d %s: listener on %s->events.%s but no listener on its "
                    "events.destroy" % (rel, line, fname, t, sig))
                continue
            if owner not in removals:
                findings.append(
                    "%s:%d %s: %s is added on %s->events.%s and never removed"
                    % (rel, line, fname, owner, t, sig))

    if findings:
        for f in findings:
            print("   " + f)
        return 1

    if not args.quiet:
        print("   %d listener(s) on destruction-checked signals, all released"
              % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
