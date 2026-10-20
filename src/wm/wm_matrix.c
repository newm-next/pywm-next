/*
 * Small 3x3 matrix helpers owned by pywm.
 *
 * Derived from wlroots' util/matrix.c (MIT licence, Copyright (c) 2017 wlroots
 * contributors), at tag 0.20.2. wlroots stopped exporting wlr_matrix_* in
 * 0.19.0, so pywm keeps its own copy instead of including a private header.
 */

#include <assert.h>
#include <math.h>
#include <string.h>

#include "wm/wm_matrix.h"

enum wl_output_transform wm_output_transform_invert(enum wl_output_transform transform) {
    switch (transform) {
    case WL_OUTPUT_TRANSFORM_NORMAL:
        return WL_OUTPUT_TRANSFORM_NORMAL;
    case WL_OUTPUT_TRANSFORM_90:
        return WL_OUTPUT_TRANSFORM_270;
    case WL_OUTPUT_TRANSFORM_180:
        return WL_OUTPUT_TRANSFORM_180;
    case WL_OUTPUT_TRANSFORM_270:
        return WL_OUTPUT_TRANSFORM_90;
    case WL_OUTPUT_TRANSFORM_FLIPPED:
        return WL_OUTPUT_TRANSFORM_FLIPPED;
    case WL_OUTPUT_TRANSFORM_FLIPPED_90:
        return WL_OUTPUT_TRANSFORM_FLIPPED_270;
    case WL_OUTPUT_TRANSFORM_FLIPPED_180:
        return WL_OUTPUT_TRANSFORM_FLIPPED_180;
    case WL_OUTPUT_TRANSFORM_FLIPPED_270:
        return WL_OUTPUT_TRANSFORM_FLIPPED_90;
    }
    return WL_OUTPUT_TRANSFORM_NORMAL;
}

void wm_matrix_identity(float mat[static 9]) {
    static const float identity[9] = {
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    };
    memcpy(mat, identity, sizeof(identity));
}

void wm_matrix_multiply(float mat[static 9], const float a[static 9],
                        const float b[static 9]) {
    float product[9];

    product[0] = a[0]*b[0] + a[1]*b[3] + a[2]*b[6];
    product[1] = a[0]*b[1] + a[1]*b[4] + a[2]*b[7];
    product[2] = a[0]*b[2] + a[1]*b[5] + a[2]*b[8];

    product[3] = a[3]*b[0] + a[4]*b[3] + a[5]*b[6];
    product[4] = a[3]*b[1] + a[4]*b[4] + a[5]*b[7];
    product[5] = a[3]*b[2] + a[4]*b[5] + a[5]*b[8];

    product[6] = a[6]*b[0] + a[7]*b[3] + a[8]*b[6];
    product[7] = a[6]*b[1] + a[7]*b[4] + a[8]*b[7];
    product[8] = a[6]*b[2] + a[7]*b[5] + a[8]*b[8];

    memcpy(mat, product, sizeof(product));
}

void wm_matrix_transpose(float mat[static 9], const float a[static 9]) {
    float product[9] = {
        a[0], a[3], a[6],
        a[1], a[4], a[7],
        a[2], a[5], a[8],
    };
    memcpy(mat, product, sizeof(product));
}

void wm_matrix_translate(float mat[static 9], float x, float y) {
    float translate[9] = {
        1.0f, 0.0f, x,
        0.0f, 1.0f, y,
        0.0f, 0.0f, 1.0f,
    };
    wm_matrix_multiply(mat, mat, translate);
}

void wm_matrix_scale(float mat[static 9], float x, float y) {
    float scale[9] = {
        x,    0.0f, 0.0f,
        0.0f, y,    0.0f,
        0.0f, 0.0f, 1.0f,
    };
    wm_matrix_multiply(mat, mat, scale);
}

static const float transforms[][9] = {
    [WL_OUTPUT_TRANSFORM_NORMAL] = {
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_90] = {
        0.0f, 1.0f, 0.0f,
        -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_180] = {
        -1.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_270] = {
        0.0f, -1.0f, 0.0f,
        1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_FLIPPED] = {
        -1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_FLIPPED_90] = {
        0.0f, 1.0f, 0.0f,
        1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_FLIPPED_180] = {
        1.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
    [WL_OUTPUT_TRANSFORM_FLIPPED_270] = {
        0.0f, -1.0f, 0.0f,
        -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f,
    },
};

void wm_matrix_transform(float mat[static 9], enum wl_output_transform transform) {
    wm_matrix_multiply(mat, mat, transforms[transform]);
}

void wm_matrix_projection(float mat[static 9], int width, int height,
                          enum wl_output_transform transform) {
    memset(mat, 0, sizeof(*mat) * 9);

    const float *t = transforms[transform];
    float x = 2.0f / width;
    float y = 2.0f / height;

    // Rotation + reflection
    mat[0] = x * t[0];
    mat[1] = x * t[1];
    mat[3] = y * -t[3];
    mat[4] = y * -t[4];

    // Translation
    mat[2] = -copysign(1.0f, mat[0] + mat[1]);
    mat[5] = -copysign(1.0f, mat[3] + mat[4]);

    // Identity
    mat[8] = 1.0f;
}

void wm_matrix_project_box(float mat[static 9], const struct wlr_box *box,
                           enum wl_output_transform transform,
                           const float projection[static 9]) {
    int x = box->x;
    int y = box->y;
    int width = box->width;
    int height = box->height;

    wm_matrix_identity(mat);
    wm_matrix_translate(mat, x, y);

    wm_matrix_scale(mat, width, height);

    if (transform != WL_OUTPUT_TRANSFORM_NORMAL) {
        wm_matrix_translate(mat, 0.5, 0.5);
        wm_matrix_transform(mat, transform);
        wm_matrix_translate(mat, -0.5, -0.5);
    }

    wm_matrix_multiply(mat, projection, mat);
}
