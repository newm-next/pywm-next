#ifndef WM_MATRIX_H
#define WM_MATRIX_H

#include <wayland-server-protocol.h>
#include <wlr/util/box.h>

/*
 * Small 3x3 matrix helpers owned by pywm.
 *
 * wlroots stopped exporting wlr_matrix_* in 0.19.0 (the helpers now live in the
 * private include/util/matrix.h, which is not installed). These are derived from
 * wlroots' util/matrix.c, MIT licence, Copyright (c) 2017 wlroots contributors:
 * https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/0.20.2/util/matrix.c
 *
 * They stay local so pywm never includes a private wlroots header.
 */

enum wl_output_transform wm_output_transform_invert(enum wl_output_transform transform);

void wm_matrix_identity(float mat[static 9]);
void wm_matrix_multiply(float mat[static 9], const float a[static 9],
                        const float b[static 9]);
void wm_matrix_transpose(float mat[static 9], const float a[static 9]);
void wm_matrix_translate(float mat[static 9], float x, float y);
void wm_matrix_scale(float mat[static 9], float x, float y);
void wm_matrix_transform(float mat[static 9], enum wl_output_transform transform);
void wm_matrix_projection(float mat[static 9], int width, int height,
                          enum wl_output_transform transform);
void wm_matrix_project_box(float mat[static 9], const struct wlr_box *box,
                           enum wl_output_transform transform,
                           const float projection[static 9]);

#endif
