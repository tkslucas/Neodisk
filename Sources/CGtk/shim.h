/*
 * The GTK 4 + libadwaita C API as the Linux app sees it. Swift imports the
 * headers directly; the few pieces it can't import (function-like macros,
 * cast-heavy constants) are re-exposed below as static inline functions.
 */
#ifndef NEODISK_CGTK_SHIM_H
#define NEODISK_CGTK_SHIM_H

#include <adwaita.h>
#include <glib-unix.h>
#include <gtk/gtk.h>

/*
 * libdispatch SPI — the hooks CoreFoundation's run loop uses to drain the
 * main dispatch queue from a foreign event loop. The GTK app owns the main
 * thread with GLib's loop, so it watches the queue's eventfd and drains it
 * from there; that is what makes @MainActor code run.
 */
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

static inline GType neodisk_object_type(void) { return G_TYPE_OBJECT; }
static inline GType neodisk_widget_type(void) { return GTK_TYPE_WIDGET; }
static inline GType neodisk_boolean_type(void) { return G_TYPE_BOOLEAN; }
static inline GType neodisk_string_type(void) { return G_TYPE_STRING; }
static inline guint neodisk_invalid_list_position(void) { return GTK_INVALID_LIST_POSITION; }
static inline int neodisk_pango_scale(void) { return PANGO_SCALE; }

#endif
