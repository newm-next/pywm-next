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
# are the contract that would break first.
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
