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
. "$root/../env/env.sh" 2>/dev/null || true

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
WAYLAND_DISPLAY=wayland-0 "$probe"
probe_rc=$?

sleep 0.3
if ! kill -0 $pid 2>/dev/null; then
	echo ""
	echo "RESULT: FAIL - the compositor died"
	echo "last lines of $log:"
	tail -5 "$log" | sed 's/^/    /'
	exit 1
fi

if [ $probe_rc -ne 0 ]; then
	echo ""
	echo "RESULT: FAIL - probe exited $probe_rc"
	tail -5 "$log" | sed 's/^/    /'
	exit 1
fi

echo ""
echo "RESULT: PASS - compositor survived every lifecycle step"
exit 0
