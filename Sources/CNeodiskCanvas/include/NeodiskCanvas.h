// The treemap and sunburst canvas's drawing layer: Direct3D 11, a DXGI flip-model swap chain, a Direct2D device
// context, DirectWrite and WIC behind a C API Swift can call. COM stays on this side.

#ifndef NEODISK_CANVAS_H
#define NEODISK_CANVAS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NDCanvas NDCanvas;
typedef struct NDImage NDImage;
typedef struct NDText NDText;

typedef struct NDColor {
    float r, g, b, a;
} NDColor;

typedef struct NDRect {
    float x, y, width, height;
} NDRect;

/// A ring segment: angles in radians on screen (0 at 3 o'clock, growing clockwise), radii in DIPs.
typedef struct NDArc {
    float start;
    float end;
    float inner;
    float outer;
    NDColor fill;
} NDArc;

typedef struct NDAdapterInfo {
    int32_t isSoftware;
    uint32_t vendorID;
    uint16_t description[128];
} NDAdapterInfo;

/// How `ndc_canvas_end` presents.
enum {
    NDPresentNone = 0,
    NDPresentVSync = 1,
    NDPresentImmediate = 2,
};

/// Returned by `ndc_canvas_end` when the device is gone: destroy every canvas and image, then start over.
#define ND_DEVICE_LOST ((int32_t)0x8899000C)

// MARK: Canvas

/// A canvas presenting into `hwnd` through a flip-model swap chain sized in device pixels.
int32_t ndc_canvas_create_hwnd(void *hwnd, uint32_t pixelWidth, uint32_t pixelHeight, float dpi, NDCanvas **out);
/// A canvas drawing into an offscreen bitmap, for headless renders (`ndc_canvas_save_png`).
int32_t ndc_canvas_create_offscreen(uint32_t pixelWidth, uint32_t pixelHeight, float dpi, NDCanvas **out);
void ndc_canvas_destroy(NDCanvas *canvas);
int32_t ndc_canvas_resize(NDCanvas *canvas, uint32_t pixelWidth, uint32_t pixelHeight, float dpi);
/// The adapter the shared device runs on (a software one means WARP).
void ndc_adapter_info(NDAdapterInfo *out);

int32_t ndc_canvas_begin(NDCanvas *canvas, NDColor clear);
int32_t ndc_canvas_end(NDCanvas *canvas, int32_t present);
/// Blocks until the device has executed everything submitted, so a benchmark times real work.
void ndc_canvas_finish(NDCanvas *canvas);
int32_t ndc_canvas_save_png(NDCanvas *canvas, const uint16_t *path);

// MARK: Drawing, in DIPs, between begin and end

void ndc_draw_image(NDCanvas *canvas, NDImage *image, NDRect dest, float opacity, int32_t smooth);
void ndc_fill_rect(NDCanvas *canvas, NDRect rect, NDColor color);
/// A stroke of `width` DIPs inside `rect`.
void ndc_stroke_rect(NDCanvas *canvas, NDRect rect, float width, NDColor color);
void ndc_push_clip(NDCanvas *canvas, NDRect rect);
void ndc_pop_clip(NDCanvas *canvas);
void ndc_draw_text(NDCanvas *canvas, NDText *text, float x, float y, NDColor color);
/// Each arc filled with its color times `opacities[i]` (all 1 when NULL), then outlined with the separator.
void ndc_draw_arcs(NDCanvas *canvas, float cx, float cy, const NDArc *arcs, uint32_t count,
                   const float *opacities, NDColor separator, float separatorWidth);
/// One arc filled with `arc.fill` (skipped when transparent) and stroked.
void ndc_draw_arc_overlay(NDCanvas *canvas, float cx, float cy, NDArc arc, NDColor stroke, float width);

// MARK: Images (premultiplied, device pixels; drawn at the canvas DPI)

NDImage *ndc_image_create(NDCanvas *canvas, const void *pixels, uint32_t width, uint32_t height, uint32_t stride,
                          int32_t isBGRA);
void ndc_image_release(NDImage *image);
/// Renders `texts` at `origins` (x, y pairs in DIPs) into a transparent image once, with a soft dark halo when
/// `haloRadius` > 0. Call outside begin/end.
NDImage *ndc_image_render_texts(NDCanvas *canvas, uint32_t pixelWidth, uint32_t pixelHeight,
                                NDText *const *texts, const float *origins, uint32_t count,
                                NDColor color, float haloRadius, NDColor haloColor);

// MARK: Text (any thread)

/// A single-line layout in the UI font, ellipsized at `maxWidth` DIPs when it's > 0.
/// alignment: 0 leading, 1 centered, 2 trailing.
NDText *ndc_text_create(const uint16_t *utf16, uint32_t length, float fontSize, int32_t bold, float maxWidth,
                        int32_t alignment);
void ndc_text_release(NDText *text);
/// The drawn size, and the width the whole string would need.
void ndc_text_metrics(NDText *text, float *width, float *height, float *naturalWidth);
float ndc_text_measure(const uint16_t *utf16, uint32_t length, float fontSize, int32_t bold);

// MARK: CPU raster (any thread, no shared device)

/// Paints arcs (fill + separator) into premultiplied BGRA pixels, clearing to transparent first.
int32_t ndc_rasterize_arcs(uint32_t pixelWidth, uint32_t pixelHeight, float scale, float cx, float cy,
                           const NDArc *arcs, uint32_t count, NDColor separator, float separatorWidth,
                           void *pixels, uint32_t stride);

#ifdef __cplusplus
}
#endif

#endif
