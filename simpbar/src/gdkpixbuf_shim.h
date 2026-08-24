/* Plain C wrapper around gdk-pixbuf, deliberately free of GLib's macros
 * (G_GNUC_BEGIN_IGNORE_DEPRECATIONS and friends expand to back-to-back
 * _Pragma(...) invocations that Zig's translate-c can't parse when
 * @cImport-ing GLib/gdk-pixbuf headers directly). This header only has
 * plain declarations, so @cImport-ing *this* file works fine; the real
 * gdk-pixbuf.h is only included from the .c side, compiled by a real C
 * compiler instead of translate-c. */
#ifndef SIMPBAR_GDKPIXBUF_SHIM_H
#define SIMPBAR_GDKPIXBUF_SHIM_H

typedef struct SimpbarPixbuf SimpbarPixbuf;

/* NULL on failure (bad path, unsupported format, decode error). */
SimpbarPixbuf *simpbar_pixbuf_load(const char *path, int target_size);
void simpbar_pixbuf_free(SimpbarPixbuf *pb);

int simpbar_pixbuf_width(SimpbarPixbuf *pb);
int simpbar_pixbuf_height(SimpbarPixbuf *pb);
int simpbar_pixbuf_rowstride(SimpbarPixbuf *pb);
int simpbar_pixbuf_channels(SimpbarPixbuf *pb);
int simpbar_pixbuf_has_alpha(SimpbarPixbuf *pb);
const unsigned char *simpbar_pixbuf_pixels(SimpbarPixbuf *pb);

#endif
