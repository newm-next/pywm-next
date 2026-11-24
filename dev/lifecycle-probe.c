/*
 * lifecycle-probe — exercise the surface lifecycle paths of pywm/wlroots
 * without a GPU, and report which step kills the compositor.
 *
 * Each step is followed by a roundtrip, so a compositor that aborts names the
 * exact step in the last line printed. Steps, in order:
 *
 *   1. a toplevel asks for its decoration BEFORE the first commit
 *      (wlr sends new_toplevel before the role exists -> pywm must defer)
 *   2. the window is committed (first commit: initial configure)
 *   3. a popup is created on it (unconstrain happens on the popup first commit)
 *   4. the popup is destroyed on its own
 *   5. the window is unmapped and mapped again (reset_xdg_surface ->
 *      initialized drops back to false; the pending state must be replayed)
 *   6. the window is destroyed on its own
 *   7. a layer-shell surface is created, configured and destroyed
 *   8. the client disconnects
 *
 * The compositor must survive all of it. Steps 4, 6 and 7 are what the
 * listener-teardown fix is about: wlroots asserts at destroy time that nobody
 * is left listening on the object it frees.
 *
 * Build (see run-headless-probe.sh): the xdg-shell, xdg-decoration and
 * layer-shell XML are in the tree; wayland-scanner comes from the build.
 */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_registry *registry;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct zxdg_decoration_manager_v1 *deco_manager;
static struct zwlr_layer_shell_v1 *layer_shell;

static int step_no;
static const char *step_name;

/* ---------------------------------------------------------------- registry */
static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *interface, uint32_t version) {
	(void)data; (void)version;
	if (!strcmp(interface, wl_compositor_interface.name)) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (!strcmp(interface, wl_shm_interface.name)) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (!strcmp(interface, xdg_wm_base_interface.name)) {
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
	} else if (!strcmp(interface, zxdg_decoration_manager_v1_interface.name)) {
		deco_manager = wl_registry_bind(reg, name, &zxdg_decoration_manager_v1_interface, 1);
	} else if (!strcmp(interface, zwlr_layer_shell_v1_interface.name)) {
		layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, 1);
	}
}
static void registry_global_remove(void *d, struct wl_registry *r, uint32_t n) {
	(void)d; (void)r; (void)n;
}
static const struct wl_registry_listener registry_listener = {
	.global = registry_global, .global_remove = registry_global_remove,
};

/* ------------------------------------------------------------ xdg plumbing */
static void wm_base_ping(void *d, struct xdg_wm_base *s, uint32_t serial) {
	(void)d; xdg_wm_base_pong(s, serial);
}
static const struct xdg_wm_base_listener wm_base_listener __attribute__((unused)) = { .ping = wm_base_ping };

static int configured;
static void xdg_surface_configure(void *d, struct xdg_surface *s, uint32_t serial) {
	(void)d;
	xdg_surface_ack_configure(s, serial);
	configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = { .configure = xdg_surface_configure };

static void layer_surface_configure(void *d, struct zwlr_layer_surface_v1 *s,
		uint32_t serial, uint32_t w, uint32_t h) {
	(void)d; (void)w; (void)h;
	zwlr_layer_surface_v1_ack_configure(s, serial);
	printf("  layer surface configured (this requires an initialized surface)\n");
}
static void layer_surface_closed(void *d, struct zwlr_layer_surface_v1 *s) {
	(void)d; (void)s;
}
static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure, .closed = layer_surface_closed,
};

/* ------------------------------------------------------------------ helpers */
static void begin(const char *name) {
	step_name = name;
	printf("step %d: %s\n", ++step_no, name);
}

static int roundtrip(void) {
	if (wl_display_roundtrip(display) < 0) {
		/* Do not guess: the connection can be lost because the compositor
		 * died, or because the compositor closed us on a protocol error.
		 * run-headless-probe.sh tells the two apart by looking at the pid. */
		fprintf(stderr, "step %d (%s): connection lost (PROBE_CONNECTION_LOST)\n",
			step_no, step_name);
		return -1;
	}
	printf("  ok: %s\n", step_name);
	return 0;
}

/* A shm buffer, needed to map and unmap a window for real. */
struct buffer { struct wl_buffer *wl; void *data; size_t size; };

static struct buffer make_buffer(int w, int h) {
	struct buffer b = {0};
	int stride = w * 4;
	b.size = (size_t)stride * h;
	char tmpl[] = "/tmp/probe-shm-XXXXXX";
	int fd = mkstemp(tmpl);
	if (fd < 0) { perror("mkstemp"); exit(1); }
	unlink(tmpl);
	if (ftruncate(fd, b.size) < 0) { perror("ftruncate"); exit(1); }
	b.data = mmap(NULL, b.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (b.data == MAP_FAILED) { perror("mmap"); exit(1); }
	memset(b.data, 0x40, b.size);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b.size);
	b.wl = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	return b;
}

/* ------------------------------------------------- surface frame callback */
static int frame_drawn;

static void frame_handle_done(void *data, struct wl_callback *cb, uint32_t t) {
	(void)data; (void)t;
	frame_drawn = 1;
	wl_callback_destroy(cb);
}
static const struct wl_callback_listener frame_listener = { .done = frame_handle_done };

/* Wait up to timeout_ms for the compositor to report the frame as drawn.
 * Returns 0 on success, -1 on timeout, -2 on connection loss. */
static int wait_frame(int timeout_ms) {
	struct timespec start, now;
	clock_gettime(CLOCK_MONOTONIC, &start);
	while (!frame_drawn) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		long elapsed = (now.tv_sec - start.tv_sec) * 1000L +
			(now.tv_nsec - start.tv_nsec) / 1000000L;
		if (elapsed >= timeout_ms) return -1;
		struct pollfd pfd = { .fd = wl_display_get_fd(display), .events = POLLIN };
		int r = poll(&pfd, 1, (int)(timeout_ms - elapsed));
		if (r == 0) return -1;
		if (r < 0) { if (errno == EINTR) continue; return -2; }
		if (wl_display_dispatch(display) < 0) return -2;
	}
	return 0;
}

int main(void) {
	setvbuf(stdout, NULL, _IONBF, 0);

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "cannot connect (WAYLAND_DISPLAY unset?)\n");
		return 2;
	}
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	wl_display_roundtrip(display);

	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "missing base globals (compositor/shm/xdg_wm_base)\n");
		return 2;
	}
	printf("globals: decoration=%s layer_shell=%s\n",
		deco_manager ? "yes" : "no", layer_shell ? "yes" : "no");

	/* --- window, decoration requested before the first commit ---------- */
	begin("toplevel asks for a decoration before its first commit");
	struct wl_surface *surface = wl_compositor_create_surface(compositor);
	struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xs, &xdg_surface_listener, NULL);
	struct xdg_toplevel *tl = xdg_surface_get_toplevel(xs);
	xdg_toplevel_set_title(tl, "lifecycle-probe");
	xdg_toplevel_set_app_id(tl, "lifecycle-probe");
	struct zxdg_toplevel_decoration_v1 *deco = NULL;
	if (deco_manager) {
		deco = zxdg_decoration_manager_v1_get_toplevel_decoration(deco_manager, tl);
		zxdg_toplevel_decoration_v1_set_mode(deco,
			ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
	}
	if (roundtrip()) return 3;

	/* --- first commit: no buffer allowed, it only asks for a configure -- */
	begin("first commit (no buffer: initial configure requested)");
	wl_surface_commit(surface);
	if (roundtrip()) return 3;

	/* --- now the window can really map --------------------------------- */
	begin("buffer attached, window maps");
	struct buffer buf = make_buffer(200, 120);
	if (!configured) {
		fprintf(stderr, "step %d: no configure received before mapping (PROBE_NO_CONFIGURE)\n", step_no);
		return 4;
	}
	wl_surface_attach(surface, buf.wl, 0, 0);
	wl_surface_commit(surface);
	if (roundtrip()) return 3;

	/* --- repaint: frame callbacks must come back ----------------------- */
	for (int i = 0; i < 3; i++) {
		char label[96];
		snprintf(label, sizeof(label), "frame %d: damage the window, wait for wl_surface.frame done", i + 1);
		begin(label);
		frame_drawn = 0;
		struct wl_callback *cb = wl_surface_frame(surface);
		wl_callback_add_listener(cb, &frame_listener, NULL);
		/* touch the pixels: there must be something to redraw */
		struct buffer next = make_buffer(200, 120);
		memset(next.data, 0x10 * (i + 1), next.size);
		wl_surface_attach(surface, next.wl, 0, 0);
		wl_surface_damage_buffer(surface, 0, 0, 200, 120);
		wl_surface_commit(surface);
		int r = wait_frame(2000);
		if (r == -1) {
			printf("  no frame callback: compositor does not repaint\n");
			return 5;
		}
		if (r < 0) {
			fprintf(stderr, "step %d (%s): connection lost (PROBE_CONNECTION_LOST)\n",
				step_no, step_name);
			return 3;
		}
		printf("  ok: frame %d drawn\n", i + 1);
	}

	/* --- popup --------------------------------------------------------- */
	begin("popup created on the window");
	struct wl_surface *psurf = wl_compositor_create_surface(compositor);
	struct xdg_surface *pxs = xdg_wm_base_get_xdg_surface(wm_base, psurf);
	xdg_surface_add_listener(pxs, &xdg_surface_listener, NULL);
	struct xdg_positioner *pos = xdg_wm_base_create_positioner(wm_base);
	xdg_positioner_set_size(pos, 120, 80);
	xdg_positioner_set_anchor_rect(pos, 0, 0, 10, 10);
	xdg_positioner_set_anchor(pos, XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT);
	struct xdg_popup *popup = xdg_surface_get_popup(pxs, xs, pos);
	xdg_positioner_destroy(pos);
	/* same rule as a toplevel: the first commit carries no buffer */
	wl_surface_commit(psurf);
	if (roundtrip()) return 3;
	begin("popup buffer attached");
	struct buffer pbuf = make_buffer(120, 80);
	wl_surface_attach(psurf, pbuf.wl, 0, 0);
	wl_surface_commit(psurf);
	if (roundtrip()) return 3;

	/* --- popup destroyed on its own ------------------------------------ */
	begin("popup destroyed");
	xdg_popup_destroy(popup);
	xdg_surface_destroy(pxs);
	wl_surface_destroy(psurf);
	if (roundtrip()) return 3;

	/* --- unmap / remap -------------------------------------------------- */
	begin("window unmapped (NULL buffer commit)");
	wl_surface_attach(surface, NULL, 0, 0);
	wl_surface_commit(surface);
	if (roundtrip()) return 3;

	begin("window mapped again (configure, then buffer)");
	configured = 0;
	wl_surface_commit(surface);
	if (roundtrip()) return 3;
	if (!configured) {
		fprintf(stderr, "step %d: no configure after unmap (PROBE_NO_CONFIGURE)\n", step_no);
		return 4;
	}
	wl_surface_attach(surface, buf.wl, 0, 0);
	wl_surface_commit(surface);
	if (wl_display_roundtrip(display) < 0) {
		fprintf(stderr, "step %d (%s): display error -> compositor is gone\n", step_no, step_name);
		return 3;
	}

	/* --- window destroyed ---------------------------------------------- */
	begin("window destroyed");
	/* protocol order: the decoration object must die before its toplevel */
	if (deco) {
		zxdg_toplevel_decoration_v1_destroy(deco);
		deco = NULL;
	}
	xdg_toplevel_destroy(tl);
	xdg_surface_destroy(xs);
	wl_surface_destroy(surface);
	if (roundtrip()) return 3;

	/* --- layer-shell surface (the panel) ------------------------------- */
	if (layer_shell) {
		begin("layer-shell surface created, configured and destroyed");
		struct wl_surface *lsurf = wl_compositor_create_surface(compositor);
		struct zwlr_layer_surface_v1 *ls = zwlr_layer_shell_v1_get_layer_surface(
			layer_shell, lsurf, NULL, ZWLR_LAYER_SHELL_V1_LAYER_TOP, "probe-panel");
		zwlr_layer_surface_v1_add_listener(ls, &layer_surface_listener, NULL);
		zwlr_layer_surface_v1_set_size(ls, 300, 30);
		zwlr_layer_surface_v1_set_anchor(ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
			ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
		/* a layer surface also needs its configure before any buffer */
		wl_surface_commit(lsurf);
		if (roundtrip()) return 3;
		struct buffer lbuf = make_buffer(300, 30);
		wl_surface_attach(lsurf, lbuf.wl, 0, 0);
		wl_surface_commit(lsurf);
		if (roundtrip()) return 3;
		begin("layer-shell surface destroyed");
		zwlr_layer_surface_v1_destroy(ls);
		wl_surface_destroy(lsurf);
		if (roundtrip()) return 3;
	} else {
		printf("note: no layer-shell global, panel path not exercised\n");
	}

	/* --- disconnect ----------------------------------------------------- */
	begin("client disconnects");
	printf("PROBE OK: compositor survived every step\n");
	wl_display_disconnect(display);
	return 0;
}
