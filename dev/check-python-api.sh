#!/bin/sh
# Check that the Python API of pywm did not change while porting to a newer
# wlroots. Two directions are checked against a base ref (default:
# origin/wlroots-update):
#
#  1. Python -> C: the module surface (_pywm methods, module init) and the
#     contents of pywm/*.py.
#  2. C -> Python: every callback name pywm calls into Python, and every
#     Py_BuildValue() format string, i.e. what newm actually receives.
#
# Field-level checks of the event structs are in the PR description: they
# cannot be automated across wlroots versions, but the format strings below
# are the contract that would break first. One extra guard covers the scroll
# unit change (120 per notch in 0.20), which no type/name diff can detect.
#
# Usage: dev/check-python-api.sh [base-ref]
set -eu

base=${1:-origin/wlroots-update}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fail=0
note() { printf '%s\n' "$*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

PY_FILES="src/py/_pywmmodule.c src/py/_pywm_callbacks.c src/py/_pywm_view.c src/py/_pywm_widget.c"

# cat_sources <tree|ref> : dump the four C sources
cat_sources() {
	if [ "$1" = tree ]; then
		cat $PY_FILES
	else
		for f in $PY_FILES; do git show "$1:$f"; done
	fi
}

# fingerprint <tree|ref> <prefix>
fingerprint() {
	out=$tmp/$2
	cat_sources "$1" >"$out.src"

	# _pywm_methods entries: name + METH_* flags
	sed -n 's/.*{ *"\([a-zA-Z_0-9]*\)",.*\(METH_[A-Z_ |]*\).*/\1 \2/p' \
		"$out.src" | sort >"$out.methods"

	# python callbacks reached from C
	grep -o 'callbacks\.[a-z_0-9]*' "$out.src" | sort -u >"$out.callbacks"

	# Py_BuildValue format strings
	grep -o 'Py_BuildValue("[^"]*"' "$out.src" | sort >"$out.formats"

	# module init symbol
	grep -o 'PyInit_[a-zA-Z_0-9]*' "$out.src" | sort -u >"$out.init"

	# number of Python call sites
	grep -c 'PyObject_Call\|Py_BuildValue' "$out.src" >"$out.calls" || true
}

fingerprint tree new
fingerprint "$base" old

# --- direction 1: pywm/*.py ----------------------------------------------
if git diff --quiet "$base" -- pywm/; then
	note "ok   pywm/*.py identical to $base"
else
	note "FAIL pywm/*.py differs from $base:"
	git diff --stat "$base" -- pywm/
	fail=1
fi

# --- direction 1/2: fingerprints ----------------------------------------
check() {
	if cmp -s "$tmp/old.$1" "$tmp/new.$1"; then
		note "ok   $2 identical ($3)"
	else
		note "FAIL $2 changed:"
		diff -u "$tmp/old.$1" "$tmp/new.$1" || true
		fail=1
	fi
}

check methods "_pywm methods" "$(wc -l <"$tmp/new.methods") entries"
check init "module init name" "$(cat "$tmp/new.init")"
check callbacks "python callback inventory" "$(wc -l <"$tmp/new.callbacks") callbacks"
check formats "Py_BuildValue formats" "$(wc -l <"$tmp/new.formats") call sites"
check calls "Python call sites" "$(cat "$tmp/new.calls") occurrences"

# --- scroll units guard --------------------------------------------------
# wlroots >= 0.17 reports discrete axis values in 1/120 units, so the raw
# field must not reach Python (newm would scroll 120x too fast). The name and
# the type of the field did not change, so only an explicit check catches it.
if ! grep -q 'wm_axis_discrete_value(event)' src/py/_pywm_callbacks.c; then
	note "FAIL axis callback does not use wm_axis_discrete_value()"
	fail=1
elif ! grep -q 'WLR_POINTER_AXIS_DISCRETE_STEP' src/py/_pywm_callbacks.c; then
	note "FAIL axis conversion does not reference WLR_POINTER_AXIS_DISCRETE_STEP"
	fail=1
elif grep -q 'event->delta, event->delta_discrete' src/py/_pywm_callbacks.c; then
	note "FAIL raw event->delta_discrete still forwarded to Python"
	fail=1
else
	note "ok   scroll: delta_discrete converted from v120 to whole notches"
fi

# --- configure call graph (wlroots sources) ------------------------------
# dev/check-configure-guards.py rebuilds the call graph of the wlroots sources
# shipped in subprojects/wlroots, lists every public function that ends up
# configuring a surface, and fails if pywm calls one without an
# initialized/initial_commit guard. This is what catches a setter that is
# added later on a code path nobody thought about.
if ! command -v python3 >/dev/null 2>&1; then
	note "skip configure call graph (python3 not found)"
elif [ ! -d subprojects/wlroots ]; then
	note "skip configure call graph (subprojects/wlroots not checked out)"
else
	if guards_out=$(python3 dev/check-configure-guards.py 2>&1); then
		printf '%s\n' "$guards_out"
		note "ok   no unguarded wlroots configure call"
	else
		printf '%s\n' "$guards_out"
		note "FAIL unguarded wlroots configure call (listed above)"
		fail=1
	fi
fi

# --- xdg configure guard -------------------------------------------------
# Every wlr_xdg_toplevel_set_*() / wlr_xdg_surface_schedule_configure() ends in
# schedule_configure(), which asserts surface->initialized. A surface loses that
# flag when it is unmapped, so each call must either sit behind an
# "initialized" test or run from the initial_commit handling. Heuristic: the
# guard must be within 20 lines (same function); wm_view_xdg_apply_pending() is
# the replay helper and is itself checked to be called under initial_commit.
if ! awk '
	/^[[:space:]]*\*/ || /^[[:space:]]*\/\*/ { next }
	/^[a-zA-Z_].*\(/ {
		fn = $0; sub(/\(.*/, "", fn); n = split(fn, a, " "); fn = a[n]; guard = 0
	}
	/initialized|initial_commit/ { guard = NR }
	/wlr_xdg_toplevel_set_|wlr_xdg_surface_schedule_configure/ {
		if (fn != "wm_view_xdg_apply_pending" && (guard == 0 || NR - guard > 20)) {
			printf("     %s:%d (%s) %s\n", FILENAME, FNR, fn, $0); bad = 1
		}
	}
	/wm_view_xdg_apply_pending\(view\);/ {
		if (guard == 0 || NR - guard > 15) {
			printf("     %s:%d apply_pending outside initial_commit\n", FILENAME, FNR); bad = 1
		}
	}
	END { exit bad }
' src/wm/*.c; then
	note "FAIL xdg configure call without an initialized/initial_commit guard (listed above)"
	fail=1
else
	note "ok   xdg configure calls all guarded by initialized/initial_commit"
fi

# --- surface lifecycle guard --------------------------------------------
# wlroots >= 0.18: xdg roles only exist once new_toplevel fires, and both xdg
# and layer-shell surfaces need a configure on their first commit. Getting
# this wrong compiles fine and crashes at the first window.
if grep -q 'xdg_shell->events.new_surface' src/wm/wm_server.c; then
	note "FAIL xdg_shell still listens to new_surface (role is not set yet)"
	fail=1
elif ! grep -q 'xdg_shell->events.new_toplevel' src/wm/wm_server.c; then
	note "FAIL xdg_shell does not listen to new_toplevel"
	fail=1
elif ! grep -q 'initial_commit' src/wm/wm_view_xdg.c; then
	note "FAIL xdg views never answer initial_commit"
	fail=1
elif ! grep -q 'initial_commit' src/wm/wm_view_layer.c; then
	note "FAIL layer views never answer initial_commit"
	fail=1
elif ! grep -q 'events.associate' src/wm/wm_view_xwayland.c; then
	note "FAIL xwayland views do not track associate/dissociate"
	fail=1
else
	note "ok   surface lifecycle: new_toplevel + initial_commit + associate"
fi

# --- listener inventory (informational, for the PR) ---------------------
note ""
note "listener inventory (wl_signal_add per file):"
grep -c 'wl_signal_add' src/wm/*.c src/py/*.c 2>/dev/null | sed 's/^/     /' || true

if [ "$fail" -ne 0 ]; then
	note ""
	note "RESULT: FAIL"
	exit 1
fi

note ""
note "RESULT: PASS - python API unchanged"
