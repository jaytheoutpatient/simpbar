#include "gdkpixbuf_shim.h"
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdlib.h>

struct ZbarPixbuf {
    GdkPixbuf *pb;
};

ZbarPixbuf *zbar_pixbuf_load(const char *path, int target_size) {
    GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_size(path, target_size, target_size, NULL);
    if (!pb) return NULL;
    ZbarPixbuf *wrapper = malloc(sizeof(ZbarPixbuf));
    if (!wrapper) {
        g_object_unref(pb);
        return NULL;
    }
    wrapper->pb = pb;
    return wrapper;
}

void zbar_pixbuf_free(ZbarPixbuf *w) {
    if (!w) return;
    g_object_unref(w->pb);
    free(w);
}

int zbar_pixbuf_width(ZbarPixbuf *w) { return gdk_pixbuf_get_width(w->pb); }
int zbar_pixbuf_height(ZbarPixbuf *w) { return gdk_pixbuf_get_height(w->pb); }
int zbar_pixbuf_rowstride(ZbarPixbuf *w) { return gdk_pixbuf_get_rowstride(w->pb); }
int zbar_pixbuf_channels(ZbarPixbuf *w) { return gdk_pixbuf_get_n_channels(w->pb); }
int zbar_pixbuf_has_alpha(ZbarPixbuf *w) { return gdk_pixbuf_get_has_alpha(w->pb); }
const unsigned char *zbar_pixbuf_pixels(ZbarPixbuf *w) { return gdk_pixbuf_get_pixels(w->pb); }
