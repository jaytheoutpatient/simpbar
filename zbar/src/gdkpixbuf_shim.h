/* Plain C wrapper around gdk-pixbuf, deliberately free of GLib's macros
 * (G_GNUC_BEGIN_IGNORE_DEPRECATIONS and friends expand to back-to-back
 * _Pragma(...) invocations that Zig's translate-c can't parse when
 * @cImport-ing GLib/gdk-pixbuf headers directly). This header only has
 * plain declarations, so @cImport-ing *this* file works fine; the real
 * gdk-pixbuf.h is only included from the .c side, compiled by a real C
 * compiler instead of translate-c. */
#ifndef ZBAR_GDKPIXBUF_SHIM_H
#define ZBAR_GDKPIXBUF_SHIM_H

typedef struct ZbarPixbuf ZbarPixbuf;

/* NULL on failure (bad path, unsupported format, decode error). */
ZbarPixbuf *zbar_pixbuf_load(const char *path, int target_size);
void zbar_pixbuf_free(ZbarPixbuf *pb);

int zbar_pixbuf_width(ZbarPixbuf *pb);
int zbar_pixbuf_height(ZbarPixbuf *pb);
int zbar_pixbuf_rowstride(ZbarPixbuf *pb);
int zbar_pixbuf_channels(ZbarPixbuf *pb);
int zbar_pixbuf_has_alpha(ZbarPixbuf *pb);
const unsigned char *zbar_pixbuf_pixels(ZbarPixbuf *pb);

#endif
