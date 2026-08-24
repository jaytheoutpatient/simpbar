//! Real Unicode/glyph rendering via FreeType, replacing the earlier
//! hand-rolled 5x7 bitmap font. Loads one font file, rasterizes glyphs on
//! demand (8-bit anti-aliased coverage), and caches them by codepoint —
//! rasterizing on every redraw would be wasteful given how often the mpris
//! scroll animation redraws.

const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

/// A Nerd Font covers both ordinary text and the icon glyphs waybar's
/// config uses (Private Use Area codepoints) — same icon set regardless of
/// which specific Nerd Font variant is installed, so this doesn't have to
/// be the exact "FiraCode Nerd Font" ~/.config/waybar/style.css names.
pub const FONT_PATH = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf";

pub const Glyph = struct {
    width: u32,
    height: u32,
    bitmap_left: i32,
    bitmap_top: i32,
    advance_x: i32,
    /// 8-bit alpha coverage, width*height bytes, owned by the cache.
    pixels: []u8,
};

pub const Font = struct {
    gpa: std.mem.Allocator,
    library: c.FT_Library,
    face: c.FT_Face,
    cache: std.AutoHashMap(u32, Glyph),
    pixel_size: u32,

    pub fn init(gpa: std.mem.Allocator, path: [:0]const u8, pixel_size: u32) !Font {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(library);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library, path.ptr, 0, &face) != 0) return error.FontLoadFailed;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.SetPixelSizeFailed;

        return Font{
            .gpa = gpa,
            .library = library,
            .face = face,
            .cache = std.AutoHashMap(u32, Glyph).init(gpa),
            .pixel_size = pixel_size,
        };
    }

    pub fn deinit(self: *Font) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.gpa.free(g.pixels);
        self.cache.deinit();
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }

    /// Ascent in pixels — how far above the baseline the font's tallest
    /// glyphs reach. Used to convert a "center this text vertically" target
    /// into a baseline y-coordinate for drawing.
    pub fn ascentPx(self: *const Font) i32 {
        return @intCast(self.face.*.size.*.metrics.ascender >> 6);
    }

    pub fn descentPx(self: *const Font) i32 {
        return @intCast(@abs(self.face.*.size.*.metrics.descender) >> 6);
    }

    /// Rasterizes (or returns the cached bitmap for) one codepoint.
    pub fn glyph(self: *Font, codepoint: u32) !*const Glyph {
        const gop = try self.cache.getOrPut(codepoint);
        if (gop.found_existing) return gop.value_ptr;
        errdefer _ = self.cache.remove(codepoint);

        if (c.FT_Load_Char(self.face, codepoint, c.FT_LOAD_RENDER) != 0) return error.GlyphLoadFailed;
        const slot = self.face.*.glyph;
        const bmp = slot.*.bitmap;

        const pixels = try self.gpa.alloc(u8, @as(usize, bmp.width) * bmp.rows);
        errdefer self.gpa.free(pixels);
        const pitch: usize = @intCast(@abs(bmp.pitch));
        var row: u32 = 0;
        while (row < bmp.rows) : (row += 1) {
            const src = bmp.buffer[row * pitch ..][0..bmp.width];
            @memcpy(pixels[row * bmp.width ..][0..bmp.width], src);
        }

        gop.value_ptr.* = Glyph{
            .width = bmp.width,
            .height = bmp.rows,
            .bitmap_left = slot.*.bitmap_left,
            .bitmap_top = slot.*.bitmap_top,
            .advance_x = @intCast(slot.*.advance.x >> 6),
            .pixels = pixels,
        };
        return gop.value_ptr;
    }
};
