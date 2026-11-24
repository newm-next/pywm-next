#!/bin/sh
# Build the delivery archive for Arch Linux from git trees, never from a build
# directory: three sources, no .git, no build artefacts.
#
#   pywm-next/                       the pywm tree (HEAD of this branch)
#   pywm-next/subprojects/wlroots/   wlroots 0.20.2 submodule content
#   newm-next/                       newm-next (dd9097f)
#   INSTALL-ARCH.md, TEST-HARDWARE.md at the root
#
# Usage: dev/make-release-tar.sh <newm checkout> [output.tar.gz]
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
newm=${1:?usage: make-release-tar.sh <newm checkout> [output.tar.gz]}
out=${2:-$root/../pywm-wlroots-0.20.2-arch.tar.gz}
name=pywm-wlroots-0.20.2-arch

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/$name/pywm-next/subprojects/wlroots" "$tmp/$name/newm-next"

git -C "$root" archive --format=tar HEAD | tar -x -C "$tmp/$name/pywm-next"
# the submodule pointer is a gitlink: its content is not in the superproject
# archive, so it is exported from the submodule clone at the pinned tag.
tag=$(git -C "$root/subprojects/wlroots" describe --tags --exact-match 2>/dev/null || echo 0.20.2)
git -C "$root/subprojects/wlroots" archive --format=tar "$tag" \
	| tar -x -C "$tmp/$name/pywm-next/subprojects/wlroots"
git -C "$newm" archive --format=tar HEAD | tar -x -C "$tmp/$name/newm-next"

cp "$root/dev/INSTALL-ARCH.md" "$root/dev/TEST-HARDWARE.md" "$tmp/$name/"

# provenance, so the archive can be traced back without git
{
	printf 'pywm-next %s\n' "$(git -C "$root" rev-parse HEAD)"
	printf 'wlroots    %s (%s)\n' "$(git -C "$root/subprojects/wlroots" rev-parse HEAD)" "$tag"
	printf 'newm-next  %s\n' "$(git -C "$newm" rev-parse HEAD)"
} > "$tmp/$name/SOURCES.txt"

tar -czf "$out" -C "$tmp" "$name"
echo "$out"
sha256sum "$out"
