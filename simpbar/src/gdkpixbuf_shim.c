#include "gdkpixbuf_shim.h"
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdlib.h>

struct SimpbarPixbuf {
    GdkPixbuf *pb;
};

SimpbarPixbuf *simpbar_pixbuf_load(const char *path, int target_size) {
    GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_size(path, target_size, target_size, NULL);
    if (!pb) return NULL;
    SimpbarPixbuf *wrapper = malloc(sizeof(SimpbarPixbuf));
    if (!wrapper) {
        g_object_unref(pb);
        return NULL;
    }
    wrapper->pb = pb;
    return wrapper;
}

void simpbar_pixbuf_free(SimpbarPixbuf *w) {
    if (!w) return;
    g_object_unref(w->pb);
    free(w);
}

int simpbar_pixbuf_width(SimpbarPixbuf *w) { return gdk_pixbuf_get_width(w->pb); }
int simpbar_pixbuf_height(SimpbarPixbuf *w) { return gdk_pixbuf_get_height(w->pb); }
int simpbar_pixbuf_rowstride(SimpbarPixbuf *w) { return gdk_pixbuf_get_rowstride(w->pb); }
int simpbar_pixbuf_channels(SimpbarPixbuf *w) { return gdk_pixbuf_get_n_channels(w->pb); }
int simpbar_pixbuf_has_alpha(SimpbarPixbuf *w) { return gdk_pixbuf_get_has_alpha(w->pb); }
const unsigned char *simpbar_pixbuf_pixels(SimpbarPixbuf *w) { return gdk_pixbuf_get_pixels(w->pb); }
