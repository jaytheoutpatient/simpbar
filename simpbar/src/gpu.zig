const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const logging = @import("logging.zig");

/// Log scope for the GPU renderer — wired to <SIMPBAR_LOG_DIR>/gpu/ by
/// init() so the renderer's lines stay out of the bar's own simpbar/ folder.
var gpu_log: logging.Scope = .{};

// Minimal EGL 1.5 + GLES2 bindings, hand-written the same way main.zig binds
// libc socket/time functions — no @cImport, so this compiles without any
// extra C-header dependencies beyond what the linker already needs.
//
// Presenter design: the bar rasterizes into a plain CPU ARGB8888 buffer
// (main.zig's existing draw code), then this module uploads that buffer to a
// GL texture, draws it as a full-screen textured quad via an EGL window
// surface, and eglSwapBuffers — moving buffer management, damage tracking and
// the final composite to the GPU / compositor's swap chain instead of
// cpumemfd + wl_shm. The alpha bytes are preserved verbatim, so rendering is
// byte-for-byte identical to the shared-memory path (the compositor already
// treated those ARGB values as premultiplied there).

const EGL_PLATFORM_WAYLAND_KHR: u32 = 0x31D8;
const EGL_OPENGL_ES_API: u32 = 0x30A0;
const EGL_NONE: u32 = 0x3038;
const EGL_SURFACE_TYPE: u32 = 0x3033;
const EGL_WINDOW_BIT: u32 = 0x0004;
const EGL_RENDERABLE_TYPE: u32 = 0x3040;
const EGL_OPENGL_ES2_BIT: u32 = 0x0004;
const EGL_RED_SIZE: u32 = 0x3024;
const EGL_GREEN_SIZE: u32 = 0x3023;
const EGL_BLUE_SIZE: u32 = 0x3022;
const EGL_ALPHA_SIZE: u32 = 0x3021;
const EGL_CONTEXT_CLIENT_VERSION: u32 = 0x3098;

const GL_TRIANGLE_STRIP: u32 = 0x0005;
const GL_ARRAY_BUFFER: u32 = 0x8892;
const GL_STATIC_DRAW: u32 = 0x88E4;
const GL_VERTEX_SHADER: u32 = 0x8B31;
const GL_FRAGMENT_SHADER: u32 = 0x8B30;
const GL_COMPILE_STATUS: u32 = 0x8B81;
const GL_LINK_STATUS: u32 = 0x8B82;
const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_TEXTURE_MIN_FILTER: u32 = 0x2801;
const GL_TEXTURE_MAG_FILTER: u32 = 0x2800;
const GL_NEAREST: u32 = 0x2600;
const GL_TEXTURE_WRAP_S: u32 = 0x2802;
const GL_TEXTURE_WRAP_T: u32 = 0x2803;
const GL_CLAMP_TO_EDGE: u32 = 0x812F;
const GL_RGBA: i32 = 0x1908;
const GL_UNSIGNED_BYTE: u32 = 0x1401;
// GL_EXT_texture_format_BGRA8888: our ARGB8888 u32 is stored little-endian
// as B,G,R,A bytes, which is exactly what GL_BGRA_EXT expects — a direct
// upload without any swizzle.
const GL_BGRA_EXT: u32 = 0x80E1;
const GL_FLOAT: u32 = 0x1406;
const GL_TEXTURE0: u32 = 0x84C0;
const GL_ACTIVE_TEXTURE: u32 = 0x84E0;

const EGLDisplay = ?*anyopaque;
const EGLConfig = ?*anyopaque;
const EGLSurface = ?*anyopaque;
const EGLContext = ?*anyopaque;

extern "c" fn eglGetPlatformDisplay(platform: u32, native_display: ?*anyopaque, attrib_list: ?[*]const isize) EGLDisplay;
extern "c" fn eglInitialize(dpy: EGLDisplay, major: ?*i32, minor: ?*i32) u32;
extern "c" fn eglBindAPI(api: u32) u32;
extern "c" fn eglChooseConfig(dpy: EGLDisplay, attrib_list: [*]const i32, configs: [*c]EGLConfig, config_size: i32, num_config: *i32) u32;
extern "c" fn eglCreateContext(dpy: EGLDisplay, config: EGLConfig, share_context: EGLContext, attrib_list: [*]const i32) EGLContext;
extern "c" fn eglCreatePlatformWindowSurface(dpy: EGLDisplay, config: EGLConfig, native_window: ?*anyopaque, attrib_list: ?[*]const isize) EGLSurface;
extern "c" fn eglMakeCurrent(dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) u32;
extern "c" fn eglSwapBuffers(dpy: EGLDisplay, surface: EGLSurface) u32;
extern "c" fn eglGetError() u32;
extern "c" fn eglTerminate(dpy: EGLDisplay) u32;
extern "c" fn eglDestroySurface(dpy: EGLDisplay, surface: EGLSurface) u32;
extern "c" fn eglDestroyContext(dpy: EGLDisplay, ctx: EGLContext) u32;
extern "c" fn eglGetCurrentContext() EGLContext;

extern "c" fn glGenTextures(n: i32, textures: [*]u32) void;
extern "c" fn glBindTexture(target: u32, texture: u32) void;
extern "c" fn glTexImage2D(target: u32, level: i32, internalformat: i32, width: i32, height: i32, border: i32, format: u32, type: u32, pixels: ?*const anyopaque) void;
extern "c" fn glTexSubImage2D(target: u32, level: i32, xoffset: i32, yoffset: i32, width: i32, height: i32, format: u32, type: u32, pixels: ?*const anyopaque) void;
extern "c" fn glTexParameteri(target: u32, pname: u32, param: i32) void;
extern "c" fn glGenBuffers(n: i32, buffers: [*]u32) void;
extern "c" fn glBindBuffer(target: u32, buffer: u32) void;
extern "c" fn glBufferData(target: u32, size: isize, data: ?*const anyopaque, usage: u32) void;
extern "c" fn glVertexAttribPointer(index: u32, size: i32, type: u32, normalized: u8, stride: i32, pointer: ?*const anyopaque) void;
extern "c" fn glEnableVertexAttribArray(index: u32) void;
extern "c" fn glCreateShader(type: u32) u32;
extern "c" fn glShaderSource(shader: u32, count: i32, string: [*c]const [*c]const u8, length: ?[*]const i32) void;
extern "c" fn glCompileShader(shader: u32) void;
extern "c" fn glGetShaderiv(shader: u32, pname: u32, params: *i32) void;
extern "c" fn glGetShaderInfoLog(shader: u32, bufSize: i32, length: ?*i32, infoLog: [*]u8) void;
extern "c" fn glCreateProgram() u32;
extern "c" fn glAttachShader(program: u32, shader: u32) void;
extern "c" fn glLinkProgram(program: u32) void;
extern "c" fn glGetProgramiv(program: u32, pname: u32, params: *i32) void;
extern "c" fn glGetProgramInfoLog(program: u32, bufSize: i32, length: ?*i32, infoLog: [*]u8) void;
extern "c" fn glUseProgram(program: u32) void;
extern "c" fn glGetAttribLocation(program: u32, name: [*:0]const u8) i32;
extern "c" fn glGetUniformLocation(program: u32, name: [*:0]const u8) i32;
extern "c" fn glUniform1i(location: i32, v: i32) void;
extern "c" fn glViewport(x: i32, y: i32, width: i32, height: i32) void;
extern "c" fn glDrawArrays(mode: u32, first: i32, count: i32) void;
extern "c" fn glActiveTexture(texture: u32) void;
extern "c" fn glDeleteBuffers(n: i32, buffers: [*]const u32) void;
extern "c" fn glDeleteTextures(n: i32, textures: [*]const u32) void;
extern "c" fn glDeleteShader(shader: u32) void;
extern "c" fn glDeleteProgram(program: u32) void;

/// A GPU-presented renderer: owns the EGL/wl_egl_window plumbing plus a CPU
/// ARGB8888 pixel buffer that main.zig paints into (same draw code as the
/// shm path), and blits it to the layer surface through the GPU on present.
pub const Renderer = struct {
    display: EGLDisplay = null,
    config: EGLConfig = null,
    context: EGLContext = null,
    surface: EGLSurface = null,
    egl_window: *wl.EglWindow = undefined,
    program: u32 = 0,
    vbo: u32 = 0,
    texture: u32 = 0,
    /// Rasterized ARGB8888 pixels, sized to width×height, painted by the
    /// caller (drawAndCommit's shading code) and uploaded by present().
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// GL texture's current storage size (tracked lazily so glTexImage2D is
    /// only re-run when the surface actually changes size).
    tex_width: i32 = 0,
    tex_height: i32 = 0,
    allocator: std.mem.Allocator = undefined,

    /// Sets up EGL + GLES2 on the given layer surface. `display` is the
    /// Wayland display (native type for EGL_PLATFORM_WAYLAND), `surface` the
    /// wl_surface the layer surface wraps. Fails cleanly (leaving nothing
    /// attached) so main.zig can fall back to the shared-memory renderer.
    pub fn init(allocator: std.mem.Allocator, display: *wl.Display, surface: *wl.Surface, width: u32, height: u32) !Renderer {
        logging.scoped(&gpu_log, "gpu");
        const egl_display = eglGetPlatformDisplay(
            EGL_PLATFORM_WAYLAND_KHR,
            @ptrCast(display),
            null,
        ) orelse return error.EglDisplayFailed;
        if (eglInitialize(egl_display, null, null) == 0) return error.EglInitFailed;
        if (eglBindAPI(EGL_OPENGL_ES_API) == 0) return error.EglBindApiFailed;

        const config_attribs = [_]i32{
            EGL_SURFACE_TYPE,  EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE,      8,
            EGL_GREEN_SIZE,    8,
            EGL_BLUE_SIZE,     8,
            EGL_ALPHA_SIZE,    8, // keep the alpha channel so transparent corners/bg work
            EGL_NONE,
        };
        var config: EGLConfig = null;
        var num_config: i32 = 0;
        if (eglChooseConfig(egl_display, &config_attribs, &config, 1, &num_config) == 0 or num_config < 1) {
            return error.NoEglConfig;
        }

        const context_attribs = [_]i32{ EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
        const context = eglCreateContext(egl_display, config, null, &context_attribs) orelse return error.EglContextFailed;

        const egl_window = wl.EglWindow.create(surface, @intCast(width), @intCast(height)) catch return error.EglWindowCreateFailed;
        const egl_surface = eglCreatePlatformWindowSurface(egl_display, config, @ptrCast(egl_window), null) orelse {
            egl_window.destroy();
            return error.EglSurfaceFailed;
        };
        if (eglMakeCurrent(egl_display, egl_surface, egl_surface, context) == 0) {
            _ = eglDestroySurface(egl_display, egl_surface);
            egl_window.destroy();
            return error.EglMakeCurrentFailed;
        }

        const program = compileProgram() catch {
            _ = eglDestroySurface(egl_display, egl_surface);
            egl_window.destroy();
            return error.ProgramCompileFailed;
        };
        glUseProgram(program);

        const pixels = allocator.alloc(u32, width * height) catch {
            glDeleteProgram(program);
            _ = eglDestroySurface(egl_display, egl_surface);
            egl_window.destroy();
            return error.OutOfMemory;
        };

        var self = Renderer{
            .display = egl_display,
            .config = config,
            .context = context,
            .surface = egl_surface,
            .egl_window = egl_window,
            .program = program,
            .pixels = pixels,
            .width = width,
            .height = height,
            .allocator = allocator,
        };
        self.setupQuadAndTexture();
        glViewport(0, 0, @intCast(width), @intCast(height));
        gpu_log.step("gpu renderer online ({d}x{d})", .{ width, height });
        return self;
    }

    /// Reallocates the CPU pixel buffer when the surface size changes.
    pub fn ensurePixels(self: *Renderer, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;
        const new_pixels = try self.allocator.realloc(self.pixels, width * height);
        self.pixels = new_pixels;
        self.width = width;
        self.height = height;
    }

    /// Uploads self.pixels to a GL texture, draws the full-screen quad, and
    /// swaps. Call after the caller has painted self.pixels.
    pub fn present(self: *Renderer) !void {
        // Re-bind current: with multiple bars on one Wayland display another
        // bar's init/makeCurrent may have stolen the current context/surface
        // since last swap — eglSwapBuffers on a non-current surface fails
        // with EGL_BAD_SURFACE on Mesa.
        if (eglMakeCurrent(self.display, self.surface, self.surface, self.context) == 0) {
            gpu_log.err("gpu: eglMakeCurrent failed, eglGetError={x}", .{eglGetError()});
            return error.EglMakeCurrentFailed;
        }
        const w: i32 = @intCast(self.width);
        const h: i32 = @intCast(self.height);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, self.texture);
        if (self.tex_width != w or self.tex_height != h) {
            // Surface resized: resize the wl_egl_window so the compositor's
            // buffer matches the new WxH, reallocate texture storage, and
            // reset the viewport — then upload the first frame at this size.
            self.egl_window.resize(w, h, 0, 0);
            glViewport(0, 0, w, h);
            glTexImage2D(
                GL_TEXTURE_2D,
                0,
                GL_RGBA,
                w,
                h,
                0,
                GL_BGRA_EXT,
                GL_UNSIGNED_BYTE,
                @ptrCast(self.pixels.ptr),
            );
            self.tex_width = w;
            self.tex_height = h;
        } else {
            glTexSubImage2D(
                GL_TEXTURE_2D,
                0,
                0,
                0,
                w,
                h,
                GL_BGRA_EXT,
                GL_UNSIGNED_BYTE,
                @ptrCast(self.pixels.ptr),
            );
        }
        glUseProgram(self.program);
        glBindBuffer(GL_ARRAY_BUFFER, self.vbo);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        if (eglSwapBuffers(self.display, self.surface) == 0) {
            gpu_log.err("gpu: eglSwapBuffers failed, eglGetError={x}", .{eglGetError()});
            return error.EglSwapBuffersFailed;
        }
        const err = eglGetError();
        if (err != 0x3000) { // EGL_SUCCESS
            gpu_log.warn("gpu: egl error after swap: {x}", .{err});
        }
    }

    pub fn deinit(self: *Renderer) void {
        if (self.program != 0) glDeleteProgram(self.program);
        if (self.vbo != 0) glDeleteBuffers(1, @ptrCast(&self.vbo));
        if (self.texture != 0) glDeleteTextures(1, @ptrCast(&self.texture));
        if (self.context != null) {
            _ = eglMakeCurrent(self.display, null, null, null);
            _ = eglDestroyContext(self.display, self.context);
        }
        if (self.surface != null) {
            _ = eglDestroySurface(self.display, self.surface);
        }
        self.egl_window.destroy();
        // Do NOT call eglTerminate: multiple bars share one Wayland display
        // and Mesa's eglGetPlatformDisplay returns the same EGLDisplay for
        // all of them, so terminating one bar's display would break every
        // other bar (the process is long-lived, so never terminating is fine).
        self.allocator.free(self.pixels);
    }

    fn setupQuadAndTexture(self: *Renderer) void {
        // Full-screen triangle strip. uv layout maps our row-0-is-top buffer
        // to the top of the screen: v=0 (first uploaded row) at geometry top.
        const quad = [_]f32{
            -1.0, -1.0, 0.0, 1.0,
             1.0, -1.0, 1.0, 1.0,
            -1.0,  1.0, 0.0, 0.0,
             1.0,  1.0, 1.0, 0.0,
        };
        glGenBuffers(1, @ptrCast(&self.vbo));
        glBindBuffer(GL_ARRAY_BUFFER, self.vbo);
        glBufferData(GL_ARRAY_BUFFER, @intCast(quad.len * @sizeOf(f32)), &quad, GL_STATIC_DRAW);

        const pos_loc = glGetAttribLocation(self.program, "a_pos");
        const uv_loc = glGetAttribLocation(self.program, "a_uv");
        const stride: i32 = @intCast(4 * @sizeOf(f32));
        if (pos_loc >= 0) {
            glVertexAttribPointer(
                @intCast(pos_loc),
                2,
                GL_FLOAT,
                0,
                stride,
                @ptrFromInt(0),
            );
            glEnableVertexAttribArray(@intCast(pos_loc));
        }
        if (uv_loc >= 0) {
            glVertexAttribPointer(
                @intCast(uv_loc),
                2,
                GL_FLOAT,
                0,
                stride,
                @ptrFromInt(2 * @sizeOf(f32)),
            );
            glEnableVertexAttribArray(@intCast(uv_loc));
        }
        const tex_loc = glGetUniformLocation(self.program, "u_tex");
        if (tex_loc >= 0) glUniform1i(tex_loc, 0);

        glGenTextures(1, @ptrCast(&self.texture));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, self.texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, @intCast(GL_NEAREST));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, @intCast(GL_NEAREST));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, @intCast(GL_CLAMP_TO_EDGE));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, @intCast(GL_CLAMP_TO_EDGE));
    }
};

fn compileProgram() !u32 {
    const vs = try compileShader(
        GL_VERTEX_SHADER,
        "precision highp float;\n" ++
            "attribute vec2 a_pos;\n" ++
            "attribute vec2 a_uv;\n" ++
            "varying vec2 v_uv;\n" ++
            "void main() { gl_Position = vec4(a_pos, 0.0, 1.0); v_uv = a_uv; }\n",
    );
    defer glDeleteShader(vs);
    const fs = try compileShader(
        GL_FRAGMENT_SHADER,
        "precision mediump float;\n" ++
            "uniform sampler2D u_tex;\n" ++
            "varying vec2 v_uv;\n" ++
            "void main() { gl_FragColor = texture2D(u_tex, v_uv); }\n",
    );
    defer glDeleteShader(fs);

    const program = glCreateProgram();
    if (program == 0) return error.ProgramCreateFailed;
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);

    var status: i32 = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == 0) {
        var log_buf: [256]u8 = undefined;
        var len: i32 = 0;
        glGetProgramInfoLog(program, @intCast(log_buf.len), &len, &log_buf);
        const log = log_buf[0..@as(usize, @intCast(@max(len, 0)))];
        gpu_log.err("gpu: program link failed: {s}", .{log});
        glDeleteProgram(program);
        return error.ProgramLinkFailed;
    }
    return program;
}

fn compileShader(kind: u32, src: [*:0]const u8) !u32 {
    const shader = glCreateShader(kind);
    if (shader == 0) return error.ShaderCreateFailed;
    var sources: [1][*:0]const u8 = .{src};
    glShaderSource(shader, 1, @ptrCast(&sources), null);
    glCompileShader(shader);

    var status: i32 = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log_buf: [256]u8 = undefined;
        var len: i32 = 0;
        glGetShaderInfoLog(shader, @intCast(log_buf.len), &len, &log_buf);
        const log = log_buf[0..@as(usize, @intCast(@max(len, 0)))];
        gpu_log.err("gpu: shader compile failed: {s}", .{log});
        glDeleteShader(shader);
        return error.ShaderCompileFailed;
    }
    return shader;
}