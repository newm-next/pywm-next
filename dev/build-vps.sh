#!/bin/sh
# Build pywm against wlroots 0.20.2 on a machine without sudo/docker/GPU.
#
# The host only provides the base toolchain: wlroots 0.20.2 needs newer
# wayland / wayland-protocols / libdrm / xkbcommon / pixman than Debian
# trixie ships, so meson builds those five from the wraps pinned in
# subprojects/*.wrap (--wrap-mode=default).
#
# Usage: dev/build-vps.sh [builddir]         (default: build)
#        NINJA_ARGS="-v" dev/build-vps.sh   to pass extra ninja flags
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
builddir=${1:-build}
envsh=$root/../env/env.sh

# Toolchain + user sysroot prepared for this project (not needed on a machine
# that already has the build deps installed system-wide).
if [ -f "$envsh" ]; then
	# shellcheck disable=SC1090
	. "$envsh"
fi

jobs=${JOBS:-$(nproc 2>/dev/null || echo 2)}

meson setup "$builddir" --wrap-mode=default \
	--force-fallback-for=wayland,wayland-protocols,libdrm,xkbcommon,pixman \
	-Dwlroots:examples=false -Dwlroots:backends=drm,libinput -Dwlroots:renderers=gles2 \
	-Dwlroots:allocators=gbm,udmabuf -Dwlroots:xwayland=enabled \
	-Dwayland:documentation=false -Dwayland:tests=false -Dwayland:dtd_validation=false \
	-Dlibdrm:tests=false -Dlibdrm:intel=disabled -Dlibdrm:radeon=disabled -Dlibdrm:amdgpu=disabled \
	-Dlibdrm:nouveau=disabled -Dlibdrm:vmwgfx=disabled -Dlibdrm:werror=false \
	-Dxkbcommon:enable-docs=false -Dxkbcommon:enable-x11=false -Dxkbcommon:enable-tools=false \
	-Dxkbcommon:enable-xkbregistry=false -Dxkbcommon:enable-bash-completion=false \
	-Dpixman:tests=disabled -Dpixman:demos=disabled

# -k 0: keep going so a single C error in src/ does not hide the rest.
ninja -C "$builddir" -k 0 -j "$jobs" ${NINJA_ARGS:-}
