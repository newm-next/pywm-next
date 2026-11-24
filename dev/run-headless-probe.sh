#!/bin/sh
# Run the surface-lifecycle probe against a headless pywm (no GPU, no root).
#
# pywm needs a renderer with no DRM node available, so the test build is
# configured with xwayland disabled (its stubs are not in a wlroots built
# without xwayland) and run with:
#     WLR_BACKENDS=headless WLR_RENDERER=pixman
# wlroots 0.20 always compiles the pixman renderer and accepts it by name
# (render/wlr_renderer.c:219-271); the headless backend exists unconditionally.
#
# Exit code: 0 only if the compositor is still alive after every step.
#
# Usage: dev/run-headless-probe.sh [project-root] [builddir]
set -eu

script_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=${1:-$script_root}
builddir=${2:-build-headless}
probe=$builddir/lifecycle-probe
log=$builddir/lifecycle-probe.log

cd "$root"
root=$(pwd)   # absolute, the protocol XML paths below are built from it
# dash aborts on '.' with a missing file, even with '|| true': test first.
if [ -f "$root/../env/env.sh" ]; then
	. "$root/../env/env.sh"
fi

echo "== configure ($builddir, xwayland disabled)"
if [ -f "$builddir/build.ninja" ]; then
	echo "   already configured, reusing"
else
# subproject options (-Dxkbcommon:*, -Dwlroots:*) are only accepted at the
# first setup, so this block must not run on an existing builddir.
meson setup "$builddir" --wrap-mode=default \
	--force-fallback-for=wayland,wayland-protocols,libdrm,xkbcommon,pixman \
	-Dxwayland=disabled \
	-Dwlroots:examples=false -Dwlroots:xwayland=disabled -Dwlroots:backends=libinput \
	-Dwayland:documentation=false -Dwayland:tests=false -Dwayland:dtd_validation=false \
	-Dlibdrm:tests=false -Dlibdrm:intel=disabled -Dlibdrm:radeon=disabled \
	-Dlibdrm:amdgpu=disabled -Dlibdrm:nouveau=disabled -Dlibdrm:vmwgfx=disabled \
	-Dlibdrm:werror=false \
	-Dxkbcommon:enable-docs=false -Dxkbcommon:enable-x11=false \
	-Dxkbcommon:enable-tools=false -Dxkbcommon:enable-xkbregistry=false \
	-Dxkbcommon:enable-bash-completion=false \
	-Dpixman:tests=disabled -Dpixman:demos=disabled > "$builddir.setup.log" 2>&1 \
	|| { echo "meson setup failed, see $builddir.setup.log"; exit 2; }
fi

echo "== build pywm"
ninja -C "$builddir" pywm > "$builddir.ninja.log" 2>&1 \
	|| { echo "build failed, see $builddir.ninja.log"; exit 2; }

echo "== build probe"
scanner=$builddir/subprojects/wayland/src/wayland-scanner
[ -x "$scanner" ] || { echo "no wayland-scanner in $builddir"; exit 2; }
wdir=$builddir/probe
mkdir -p "$wdir"
xml=$root/protocols
wp=$root/subprojects/wayland-protocols
"$scanner" client-header "$wp/stable/xdg-shell/xdg-shell.xml" "$wdir/xdg-shell.h"
"$scanner" private-code  "$wp/stable/xdg-shell/xdg-shell.xml" "$wdir/xdg-shell.c"
"$scanner" client-header "$wp/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" "$wdir/xdg-decoration.h"
"$scanner" private-code  "$wp/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" "$wdir/xdg-decoration.c"
"$scanner" client-header "$xml/wlr-layer-shell-unstable-v1.xml" "$wdir/layer-shell.h"
"$scanner" private-code  "$xml/wlr-layer-shell-unstable-v1.xml" "$wdir/layer-shell.c"

# the probe includes the protocols under their generated names
cp -f "$wdir/xdg-shell.h" "$wdir/xdg-shell-client-protocol.h"
cp -f "$wdir/xdg-decoration.h" "$wdir/xdg-decoration-unstable-v1-client-protocol.h"
cp -f "$wdir/layer-shell.h" "$wdir/wlr-layer-shell-unstable-v1-client-protocol.h"

${CC:-cc} -O1 -Wall -o "$probe" "$script_root/dev/lifecycle-probe.c" \
	"$wdir/xdg-shell.c" "$wdir/xdg-decoration.c" "$wdir/layer-shell.c" \
	-I"$wdir" $(pkg-config --cflags --libs wayland-client) \
	|| { echo "probe build failed"; exit 2; }

# The vendored wayland built here is newer than the host one; without it first in
# the search path pywm dies on wl_resource_post_error_vargs before any test.
libs="$builddir/subprojects/wayland/src:$builddir/subprojects/libdrm"
libs="$libs:$builddir/subprojects/libxkbcommon:$builddir/subprojects/pixman/pixman"
LD_LIBRARY_PATH="$libs:${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH

echo "== start compositor (headless, pixman)"
runtime=$(mktemp -d)
export XDG_RUNTIME_DIR=$runtime
chmod 700 "$runtime"
WLR_BACKENDS=headless WLR_RENDERER=pixman \
	"$builddir/pywm" > "$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$runtime"' EXIT INT TERM

i=0
while [ ! -S "$runtime/wayland-0" ]; do
	i=$((i + 1))
	[ $i -gt 50 ] && { echo "compositor did not create a socket, see $log"; exit 2; }
	sleep 0.1
done

echo "== run probe"
# set -e would abort on the probe's non-zero status; capture it instead
probe_rc=0
WAYLAND_DISPLAY=wayland-0 "$probe" > "$log.probe" 2>&1 || probe_rc=$?
cat "$log.probe"

sleep 0.3
alive=0
kill -0 $pid 2>/dev/null && alive=1

# exit status of the compositor, if it is already gone
comp_status=""
if [ $alive -eq 0 ]; then
	comp_status=0
	wait $pid 2>/dev/null || comp_status=$?
	case $comp_status in
		134) comp_status="134 (SIGABRT: assertion failed)";;
		139) comp_status="139 (SIGSEGV)";;
	esac
fi

# the step that was running when the connection dropped
step=$(sed -n 's/.*step \([0-9]*\) (\(.*\)): connection lost.*/\1 (\2)/p' "$log.probe" 2>/dev/null | tail -1)
assertion=$(grep -m1 -E "Assertion|assertion" "$log" 2>/dev/null || true)

echo ""
if [ $alive -eq 0 ]; then
	echo "RESULT: FAIL - the compositor died"
	[ -n "$step" ] && echo "  during step: $step"
	echo "  exit status: ${comp_status:-unknown}"
	[ -n "$assertion" ] && echo "  $assertion"
	echo "  last lines of $log:"
	tail -5 "$log" | sed 's/^/    /'
	exit 1
fi

if [ $probe_rc -eq 3 ]; then
	echo "RESULT: FAIL - client lost the connection, the compositor is still alive"
	[ -n "$step" ] && echo "  during step: $step"
	echo "  this is a protocol error on the client side or a compositor that closed it"
	grep -m3 -E "error [0-9]+:" "$log.probe" 2>/dev/null | sed 's/^/    /' || true
	exit 1
fi

if [ $probe_rc -eq 4 ]; then
	echo "RESULT: FAIL - the compositor did not send a configure when expected"
	exit 1
fi

if [ $probe_rc -eq 5 ]; then
	echo "RESULT: FAIL - no frame callback: compositor does not repaint"
	echo "  the window was damaged and wl_surface.frame never fired within 2s"
	[ -n "$step" ] && echo "  during step: $step"
	exit 1
fi

if [ $probe_rc -ne 0 ]; then
	echo "RESULT: FAIL - probe exited $probe_rc"
	exit 1
fi

echo ""
echo "RESULT: PASS - compositor survived every lifecycle step"
exit 0
