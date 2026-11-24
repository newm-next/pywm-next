#!/bin/sh
# Test the v120 -> whole-notch accumulator of the axis callback.
#
# src/py/_pywm_callbacks.c converts wlroots' 1/120 discrete axis units back to
# whole notches, accumulating the remainder so a high-resolution wheel still
# produces notches. That logic cannot be reached on the build host (no input
# device), and no name/type diff would notice it breaking, so the function is
# extracted verbatim from the source and driven here.
#
# Usage: dev/check-axis-acc.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
src=src/py/_pywm_callbacks.c
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# The accumulator + the function, copied out of the real file.
awk '/^static struct \{/{on=1} on{print} /^static bool call_axis/{exit}' "$src" \
	| sed '/^static bool call_axis/d' > "$tmp/extracted.c"

if ! grep -q 'wm_axis_discrete_value' "$tmp/extracted.c"; then
	echo "FAIL could not extract wm_axis_discrete_value() from $src" >&2
	exit 1
fi

cat > "$tmp/harness.c" <<'EOF'
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

/* Minimal stand-ins for the wlroots 0.20.2 definitions used by the function. */
struct wlr_pointer { int id; };
struct wlr_pointer_axis_event {
	uint32_t time_msec;
	enum { WL_POINTER_AXIS_SOURCE_WHEEL = 0, WL_POINTER_AXIS_SOURCE_FINGER = 1,
	       WL_POINTER_AXIS_SOURCE_CONTINUOUS = 2 } source;
	enum { WL_POINTER_AXIS_VERTICAL_SCROLL = 0,
	       WL_POINTER_AXIS_HORIZONTAL_SCROLL = 1 } orientation;
	int32_t delta_discrete;
	struct wlr_pointer *pointer;
};
enum wl_pointer_axis_source { x_unused_a };
#define WLR_POINTER_AXIS_DISCRETE_STEP 120

#include "extracted.c"

static int failures;
static int last_got;
static struct wlr_pointer mouse = { 1 }, pad = { 2 };

static void ev(int32_t discrete, int orientation, int source,
		struct wlr_pointer *p) {
	struct wlr_pointer_axis_event e = {
		.source = source,
		.orientation = orientation,
		.delta_discrete = discrete,
		.pointer = p,
	};
	int got = wm_axis_discrete_value(&e);
	printf("  %-5s src=%d discrete=%5d -> %d\n",
	       orientation == WL_POINTER_AXIS_HORIZONTAL_SCROLL ? "horiz" : "vert",
	       source, discrete, got);
	/* the caller feeds this value to Python */
	last_got = got;
}

static void expect(int want) {
	if (last_got != want) {
		printf("  FAIL expected %d, got %d\n", want, last_got);
		failures++;
	}
}

int main(void) {
	int W = WL_POINTER_AXIS_SOURCE_WHEEL, V = WL_POINTER_AXIS_VERTICAL_SCROLL;
	int H = WL_POINTER_AXIS_HORIZONTAL_SCROLL;
	int F = WL_POINTER_AXIS_SOURCE_FINGER;

	printf("classic wheel, one notch per event\n");
	ev(120, V, W, &mouse);  expect(1);
	ev(120, V, W, &mouse);  expect(1);
	ev(-120, V, W, &mouse); expect(-1);

	printf("high-resolution wheel, 8 x 15 per notch\n");
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(0);
	ev(15, V, W, &mouse); expect(1);

	printf("direction reversal voids the pending remainder\n");
	ev(15, V, W, &mouse); ev(15, V, W, &mouse); ev(15, V, W, &mouse); /* 45 */
	ev(-120, V, W, &mouse); expect(-1);
	ev(-120, V, W, &mouse); expect(-1);

	printf("touchpad / continuous: remainder flushed, stays 0\n");
	ev(60, V, W, &mouse);   expect(0);
	ev(0, V, F, &mouse);    expect(0);
	ev(0, V, F, &mouse);    expect(0);

	printf("horizontal axis is independent\n");
	ev(60, V, W, &mouse);   expect(0);
	ev(120, H, W, &mouse);  expect(1);
	ev(60, V, W, &mouse);   expect(1);

	printf("switching pointer resets the remainder\n");
	ev(60, V, W, &mouse);   expect(0);
	ev(60, V, W, &pad);     expect(0);
	ev(60, V, W, &pad);     expect(1);

	printf("non-multiples accumulate exactly\n");
	ev(100, V, W, &mouse);  expect(0);
	ev(20, V, W, &mouse);   expect(1);

	printf("\n%s (%d failure(s))\n", failures ? "RESULT: FAIL" : "RESULT: PASS", failures);
	return failures ? 1 : 0;
}
EOF

cp "$tmp/extracted.c" "$tmp/extracted.c.keep"
${CC:-gcc} -Wall -Wextra -o "$tmp/harness" "$tmp/harness.c" -I"$tmp" || {
	echo "FAIL harness does not compile" >&2; exit 1; }
"$tmp/harness"
