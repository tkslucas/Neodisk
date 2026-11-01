/*
 * The COM-heavy half of the Windows app's platform layer, as a plain C API:
 * Direct2D/DirectWrite drawing for the window chrome, UI Automation providers
 * for custom-drawn elements, uxtheme, the folder picker and PNG capture.
 * Window handles and device contexts cross as void pointers so this header
 * doesn't pull <windows.h> into the module.
 */
#ifndef NEODISK_CNEODISKWIN_H
#define NEODISK_CNEODISKWIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NdwRGBA { float r, g, b, a; } NdwRGBA;
typedef struct NdwRect { float x, y, w, h; } NdwRect;

/* MARK: - Process setup */

/* libdispatch SPI, the hooks Foundation's run loop uses: the event the main queue signals when it has work,
 * and the call that drains it. The app's message loop waits on window messages and this event together,
 * which is what makes @MainActor code run on the UI thread. */
extern void *_dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

/* COM (apartment threaded) and the common controls; call once on the UI thread. */
int32_t ndw_initialize(void);
/* Lets popup menus and scroll bars follow the dark theme (uxtheme's preferred app mode). */
void ndw_set_app_dark_mode(int32_t dark);
/* SetWindowTheme. Null names pass NULL. */
int32_t ndw_set_window_theme(void *hwnd, const uint16_t *app_name, const uint16_t *id_list);

/* MARK: - Drawing */

/* A window area drawn by Direct2D into a premultiplied 32-bit buffer, then copied into the paint DC with its
 * alpha, so pixels left clear show the window backdrop (Mica). */
typedef struct NdwSurface NdwSurface;
typedef struct NdwGfx NdwGfx;

typedef enum NdwFontFamily {
    NDW_FONT_TEXT = 0,      /* Segoe UI Variable Text, falling back to Segoe UI */
    NDW_FONT_DISPLAY = 1,   /* Segoe UI Variable Display */
    NDW_FONT_ICONS = 2,     /* Segoe Fluent Icons, falling back to Segoe MDL2 Assets */
} NdwFontFamily;

typedef enum NdwTextAlign {
    NDW_ALIGN_LEADING = 0,
    NDW_ALIGN_CENTER = 1,
    NDW_ALIGN_TRAILING = 2,
} NdwTextAlign;

typedef struct NdwTextStyle {
    float size;          /* pixels */
    int32_t weight;      /* 400 regular, 600 semibold */
    int32_t family;      /* NdwFontFamily */
    int32_t align;       /* NdwTextAlign */
    int32_t tabular;     /* tabular figures, for numbers that update */
} NdwTextStyle;

NdwSurface *ndw_surface_create(void *hwnd);
void ndw_surface_destroy(NdwSurface *surface);
/* Starts drawing the dirty rect of `hdc` (from BeginPaint) in client pixels; the dirty rect starts clear. */
NdwGfx *ndw_surface_begin(NdwSurface *surface, void *hdc, int32_t x, int32_t y, int32_t width, int32_t height);
/* Copies the result into the DC given to begin. Returns 0 on success. */
int32_t ndw_surface_end(NdwSurface *surface);

/* Off-screen drawing into a 32-bit premultiplied BGRA buffer of width * height * 4 bytes (snapshots, images). */
NdwGfx *ndw_bitmap_begin(int32_t width, int32_t height);
int32_t ndw_bitmap_end(NdwGfx *gfx, uint8_t *bgra_out);

void ndw_fill_rect(NdwGfx *gfx, NdwRect rect, NdwRGBA color);
void ndw_fill_rounded(NdwGfx *gfx, NdwRect rect, float radius, NdwRGBA color);
void ndw_stroke_rounded(NdwGfx *gfx, NdwRect rect, float radius, float width, NdwRGBA color);
void ndw_fill_ellipse(NdwGfx *gfx, NdwRect rect, NdwRGBA color);
void ndw_line(NdwGfx *gfx, float x0, float y0, float x1, float y1, float width, NdwRGBA color);
/* Diagonal stripes of `color` inside a rounded rect, offset by `phase` pixels: the progress bar's sheen. */
void ndw_fill_stripes(NdwGfx *gfx, NdwRect rect, float radius, float period, float phase, NdwRGBA color);
void ndw_push_clip(NdwGfx *gfx, NdwRect rect);
void ndw_pop_clip(NdwGfx *gfx);
/* One line, vertically centered in `rect`, trimmed with an ellipsis. */
void ndw_text(NdwGfx *gfx, const uint16_t *text, int32_t length, NdwRect rect, NdwTextStyle style, NdwRGBA color);
/* The width one line of `text` takes. */
float ndw_text_width(const uint16_t *text, int32_t length, NdwTextStyle style);

/* MARK: - Images */

/* An image list of icon-font glyphs (one per code unit in `glyphs`, a space for a blank one), for list views. */
void *ndw_glyph_image_list(const uint16_t *glyphs, int32_t count, int32_t width, int32_t height, float glyph_size,
                           NdwRGBA color);

/* MARK: - UI Automation for custom-drawn elements */

typedef enum NdwRole {
    NDW_ROLE_PANE = 0,
    NDW_ROLE_BUTTON = 1,
    NDW_ROLE_RADIO = 2,
    NDW_ROLE_LIST = 3,
    NDW_ROLE_LIST_ITEM = 4,
    NDW_ROLE_GROUP = 5,
    NDW_ROLE_PROGRESS = 6,
    NDW_ROLE_TEXT = 7,
    NDW_ROLE_TOOLBAR = 8,
    NDW_ROLE_STATUS_BAR = 9,
    NDW_ROLE_SPLITTER = 10,
    NDW_ROLE_HEADER = 11,
} NdwRole;

enum {
    NDW_NODE_FOCUSABLE = 1 << 0,
    NDW_NODE_FOCUSED = 1 << 1,
    NDW_NODE_SELECTED = 1 << 2,
    NDW_NODE_DISABLED = 1 << 3,
    NDW_NODE_HIDDEN = 1 << 4,
};

typedef struct NdwA11yNode {
    int32_t id;              /* stable and > 0 */
    int32_t parent;          /* 0: the window itself */
    int32_t role;            /* NdwRole */
    int32_t flags;
    NdwRect rect;            /* client pixels */
    const uint16_t *name;
    int32_t name_length;
    const uint16_t *help;    /* tooltip and keyboard shortcut text, may be null */
    int32_t help_length;
    const uint16_t *automation_id;
    int32_t automation_id_length;
    double value;            /* progress, 0 to 100 */
} NdwA11yNode;

typedef struct NdwA11yCallbacks {
    void *context;
    void (*invoke)(void *context, int32_t id);
    void (*focus)(void *context, int32_t id);
} NdwA11yCallbacks;

typedef struct NdwA11y NdwA11y;

NdwA11y *ndw_a11y_create(void *hwnd, NdwA11yCallbacks callbacks);
/* What the window itself is: its control type and name (instead of the window class and title). */
void ndw_a11y_set_root(NdwA11y *a11y, int32_t role, const uint16_t *name, int32_t name_length);
/* Replaces the element tree; nodes and their strings are copied. Parents come before their children. */
void ndw_a11y_set_nodes(NdwA11y *a11y, const NdwA11yNode *nodes, int32_t count);
/* WM_GETOBJECT: returns 1 and sets *result when this window answered. */
int32_t ndw_a11y_get_object(NdwA11y *a11y, uintptr_t wparam, intptr_t lparam, intptr_t *result);
void ndw_a11y_focus_changed(NdwA11y *a11y, int32_t id);
void ndw_a11y_value_changed(NdwA11y *a11y, int32_t id);
/* Raises the events the calls above posted; returns 1 when `message` was one of them. */
int32_t ndw_a11y_handle_message(NdwA11y *a11y, uint32_t message, uintptr_t wparam, intptr_t lparam);
void ndw_a11y_destroy(NdwA11y *a11y);

/* MARK: - Shell */

/* Names a standard control for assistive technology (an edit field has no label of its own). */
int32_t ndw_set_accessible_name(void *hwnd, const uint16_t *name);

/* Sets a control's accessible value (what a screen reader reads after its name) and raises the value-change
 * event, so a focused control announces the change. */
int32_t ndw_set_accessible_value(void *hwnd, const uint16_t *value);

/* Shows a popup menu at screen pixels and returns the chosen item's id, 0 for none (TrackPopupMenu with
 * TPM_RETURNCMD, whose BOOL result Swift would import as Bool). */
int32_t ndw_track_popup_menu(void *menu, int32_t x, int32_t y, void *owner);

/* The folder picker; writes a NUL-terminated path into `out` (capacity in UTF-16 units). Returns 1 when one
 * was picked. */
int32_t ndw_pick_folder(void *owner, const uint16_t *title, uint16_t *out, int32_t capacity);

/* Saves the window as PNG: from the screen (what the user sees, backdrop included) when `from_screen` is set,
 * else through PrintWindow. Returns 0 on success. */
int32_t ndw_capture_window_png(void *hwnd, const uint16_t *path, int32_t from_screen);

#ifdef __cplusplus
}
#endif

#endif
