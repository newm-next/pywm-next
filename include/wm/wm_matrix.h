#ifndef WM_MATRIX_H
#define WM_MATRIX_H

#include <wayland-server-protocol.h>

struct wlr_box;

/*
 * wlroots 0.17 removed the public wlr_matrix_* API (wlr/util/matrix.h).
 * PyWM only needs the four helpers below, so they are carried locally.
 * The implementations are copied verbatim from wlroots util/matrix.c so the
 * resulting geometry is bit-for-bit identical to what pywm used before.
 */

void wm_matrix_multiply(float mat[static 9], const float a[static 9],
        const float b[static 9]);

void wm_matrix_transpose(float mat[static 9], const float m[static 9]);

void wm_matrix_project_box(float mat[static 9], const struct wlr_box *box,
        enum wl_output_transform transform, const float projection[static 9]);

void wm_matrix_projection(float mat[static 9], int width, int height,
        enum wl_output_transform transform);

#endif
