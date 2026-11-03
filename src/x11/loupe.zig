//! Magnifier window that follows the cursor. It is drawn from the frozen
//! snapshot, so it never appears inside its own view.

const std = @import("std");
const c = @import("c");
const color = @import("../color.zig");
const Snapshot = @import("picker.zig").Snapshot;

const Loupe = @This();

/// Pixels sampled on each side of the cursor (grid is 2*radius+1 wide).
const radius = 6;
const cells = 2 * radius + 1;
const zoom = 10;
const grid_px = cells * zoom;
const strip_h = 20;
const width = grid_px;
const height = grid_px + strip_h;
const offset = 24;

dpy: *c.Display,
root: c.Window,
win: c.Window,
buf: c.Pixmap,
gc: c.GC,
snap: *const Snapshot,
black: c_ulong,
white: c_ulong,

pub fn init(dpy: *c.Display, root: c.Window, snap: *const Snapshot) Loupe {
    const screen = c.XDefaultScreen(dpy);
    const black = c.XBlackPixel(dpy, screen);
    const white = c.XWhitePixel(dpy, screen);

    var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.override_redirect = c.True;
    attrs.save_under = c.True;
    attrs.border_pixel = white;
    attrs.background_pixel = black;
    attrs.event_mask = c.ExposureMask;
    const value_mask: c_ulong = @intCast(c.CWOverrideRedirect | c.CWSaveUnder | c.CWBorderPixel | c.CWBackPixel | c.CWEventMask);

    const win = c.XCreateWindow(dpy, root, -width * 2, -height * 2, width, height, 1, c.CopyFromParent, c.InputOutput, null, value_mask, &attrs);
    const depth: c_uint = @intCast(c.XDefaultDepth(dpy, screen));
    const buf = c.XCreatePixmap(dpy, win, width, height, depth);
    const gc = c.XCreateGC(dpy, buf, 0, null);

    // Keep the window name meaningful for anyone inspecting with xprop.
    _ = c.XStoreName(dpy, win, "pixx loupe");
    _ = c.XMapRaised(dpy, win);

    return .{ .dpy = dpy, .root = root, .win = win, .buf = buf, .gc = gc, .snap = snap, .black = black, .white = white };
}

pub fn deinit(self: *Loupe) void {
    _ = c.XFreeGC(self.dpy, self.gc);
    _ = c.XFreePixmap(self.dpy, self.buf);
    _ = c.XDestroyWindow(self.dpy, self.win);
    _ = c.XFlush(self.dpy);
}

pub fn update(self: *Loupe, x: c_int, y: c_int) void {
    self.render(x, y);
    self.place(x, y);
    self.redraw();
}

/// Copy the back buffer to the window.
pub fn redraw(self: *Loupe) void {
    _ = c.XCopyArea(self.dpy, self.buf, self.win, self.gc, 0, 0, width, height, 0, 0);
    _ = c.XFlush(self.dpy);
}

/// Position beside the cursor, flipping to the other side near screen edges.
fn place(self: *Loupe, x: c_int, y: c_int) void {
    var wx = x + offset;
    var wy = y + offset;
    if (wx + width + 2 > self.snap.width) wx = x - offset - width - 2;
    if (wy + height + 2 > self.snap.height) wy = y - offset - height - 2;
    _ = c.XMoveWindow(self.dpy, self.win, wx, wy);
}

fn render(self: *Loupe, x: c_int, y: c_int) void {
    const dpy = self.dpy;
    const gc = self.gc;

    // Off-screen cells are drawn black.
    _ = c.XSetForeground(dpy, gc, self.black);
    _ = c.XFillRectangle(dpy, self.buf, gc, 0, 0, width, height);

    var row: c_int = 0;
    while (row < cells) : (row += 1) {
        var col: c_int = 0;
        while (col < cells) : (col += 1) {
            const sx = x - radius + col;
            const sy = y - radius + row;
            if (!self.snap.inBounds(sx, sy)) continue;
            _ = c.XSetForeground(dpy, gc, self.snap.rawPixel(sx, sy));
            _ = c.XFillRectangle(dpy, self.buf, gc, col * zoom, row * zoom, zoom, zoom);
        }
    }

    // Outline the centre cell in a color that contrasts with it.
    const in_bounds = self.snap.inBounds(x, y);
    const centre: color.Rgb = if (in_bounds) self.snap.rgb(x, y) else .{ .r = 0, .g = 0, .b = 0 };
    _ = c.XSetForeground(dpy, gc, if (centre.isLight()) self.black else self.white);
    _ = c.XDrawRectangle(dpy, self.buf, gc, radius * zoom - 1, radius * zoom - 1, zoom + 1, zoom + 1);

    // Hex readout strip.
    _ = c.XSetForeground(dpy, gc, self.black);
    _ = c.XFillRectangle(dpy, self.buf, gc, 0, grid_px, width, strip_h);
    if (in_bounds) {
        var text_buf: [32]u8 = undefined;
        const text = color.format(&text_buf, centre, .hex, true);
        _ = c.XSetForeground(dpy, gc, self.snap.rawPixel(x, y));
        _ = c.XFillRectangle(dpy, self.buf, gc, 4, grid_px + 4, strip_h - 8, strip_h - 8);
        _ = c.XSetForeground(dpy, gc, self.white);
        _ = c.XDrawString(dpy, self.buf, gc, strip_h + 2, grid_px + 14, text.ptr, @intCast(text.len));
    }
}
