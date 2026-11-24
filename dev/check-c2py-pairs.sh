#!/bin/sh
# Pair every Py_BuildValue() format string with the Python callback it is
# handed to, and compare the (callback, format) pairs between the working tree
# and a base ref.
#
# Why: dev/check-python-api.sh compares the set of callback names and the
# multiset of format strings separately. Swapping two call sites keeps both
# sets identical -- e.g. handing the key event's (iiis) to the button callback.
# Only the pairing catches that.
#
# Usage: dev/check-c2py-pairs.sh [base-ref]
set -eu

base=${1:-origin/wlroots-update}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

SRC="src/py/_pywmmodule.c src/py/_pywm_callbacks.c src/py/_pywm_view.c src/py/_pywm_widget.c"

# pairs_from_stdin: emit "callback format" for each Py_BuildValue site, taking
# the first callback reference that follows it in the same function body.
pairs() {
	awk '
	/^#include/ { pending = "" }                          # file boundary: drop stale site
	/Py_BuildValue\(/ {
		buf = $0
		# a format string may sit on the next line: join until complete
		while (buf !~ /Py_BuildValue\([ 	]*"[^"]*"/) {
			if ((getline line) <= 0) break
			buf = buf " " line
		}
		if (!match(buf, /Py_BuildValue\([ 	]*"[^"]*"/)) next
		fmt = substr(buf, RSTART, RLENGTH)
		sub(/^Py_BuildValue\([ 	]*"/, "", fmt)
		sub(/"$/, "", fmt)
		pending = fmt
	}
	pending != "" && /(callbacks|_get_all\(\))(->|\.)[a-z_]+/ {
		cb = $0
		gsub(/.*(callbacks|_get_all\(\))(->|\.)/, "", cb)
		gsub(/[^a-z_0-9].*/, "", cb)
		print cb, pending
		pending = ""
	}
	' | sort
}

cat $SRC | pairs > /tmp/pairs.new.$$
for f in $SRC; do git show "$base:$f"; done | pairs > /tmp/pairs.old.$$
trap 'rm -f /tmp/pairs.new.$$ /tmp/pairs.old.$$' EXIT INT TERM

echo "call sites: $(wc -l < /tmp/pairs.new.$$) in tree, $(wc -l < /tmp/pairs.old.$$) in $base"
echo ""
echo "callback / format pairs:"
cat /tmp/pairs.new.$$ | sed 's/^/     /'
echo ""

if cmp -s /tmp/pairs.old.$$ /tmp/pairs.new.$$; then
	echo "RESULT: PASS - every callback still receives the same format"
	exit 0
fi

echo "diff against $base (- expected, + got):"
diff -u /tmp/pairs.old.$$ /tmp/pairs.new.$$ || true
echo "RESULT: FAIL"
exit 1
