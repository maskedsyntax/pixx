//! X11 backend: freeze the screen into a snapshot, grab the pointer with a
//! crosshair cursor, and return the color under the click.

const std = @import("std");
const c = @import("c");
const color = @import("../color.zig");
const Loupe = @import("loupe.zig");

pub const Options = struct {
    loupe: bool = true,
};

pub const Error = error{ NoDisplay, SnapshotFailed, GrabFailed };

/// A frozen copy of the whole root window (all monitors).
pub const Snapshot = struct {
    img: *c.XImage,
    width: c_int,
    height: c_int,
    red: Channel,
    green: Channel,
    blue: Channel,

    const Channel = struct {
        mask: c_ulong,
        shift: u6,
        max: c_ulong,

        fn init(mask: c_ulong) Channel {
            if (mask == 0) return .{ .mask = 0, .shift = 0, .max = 1 };
            const shift: u6 = @intCast(@ctz(mask));
            return .{ .mask = mask, .shift = shift, .max = mask >> shift };
        }

        fn extract(self: Channel, pixel: c_ulong) u8 {
            const v = (pixel & self.mask) >> self.shift;
            if (self.max == 255) return @intCast(v);
            return @intCast((v * 255 + self.max / 2) / self.max);
        }
    };

    pub fn take(dpy: *c.Display, root: c.Window) Error!Snapshot {
        const screen = c.XDefaultScreen(dpy);
        const w = c.XDisplayWidth(dpy, screen);
        const h = c.XDisplayHeight(dpy, screen);
        const img = c.XGetImage(dpy, root, 0, 0, @intCast(w), @intCast(h), c.AllPlanes, c.ZPixmap) orelse
            return error.SnapshotFailed;
        return .{
            .img = img,
            .width = w,
            .height = h,
            .red = .init(img.*.red_mask),
            .green = .init(img.*.green_mask),
            .blue = .init(img.*.blue_mask),
        };
    }

    pub fn deinit(self: *Snapshot) void {
        _ = self.img.*.f.destroy_image.?(self.img);
    }

    pub fn inBounds(self: Snapshot, x: c_int, y: c_int) bool {
        return x >= 0 and y >= 0 and x < self.width and y < self.height;
    }

    /// Raw pixel value in the root visual's format (usable as a GC foreground).
    pub fn rawPixel(self: Snapshot, x: c_int, y: c_int) c_ulong {
        return self.img.*.f.get_pixel.?(self.img, x, y);
    }

    pub fn rgb(self: Snapshot, x: c_int, y: c_int) color.Rgb {
        const p = self.rawPixel(x, y);
        return .{ .r = self.red.extract(p), .g = self.green.extract(p), .b = self.blue.extract(p) };
    }
};

/// Returns the picked color, or null if the user cancelled.
pub fn pick(opts: Options) Error!?color.Rgb {
    const dpy = c.XOpenDisplay(null) orelse return error.NoDisplay;
    defer _ = c.XCloseDisplay(dpy);
    const root = c.XDefaultRootWindow(dpy);

    var snap = try Snapshot.take(dpy, root);
    defer snap.deinit();

    const cursor = c.XCreateFontCursor(dpy, c.XC_crosshair);
    defer _ = c.XFreeCursor(dpy, cursor);

    try grab(dpy, root, cursor);
    defer {
        _ = c.XUngrabKeyboard(dpy, c.CurrentTime);
        _ = c.XUngrabPointer(dpy, c.CurrentTime);
        _ = c.XFlush(dpy);
    }

    var loupe: ?Loupe = if (opts.loupe) Loupe.init(dpy, root, &snap) else null;
    defer if (loupe) |*l| l.deinit();

    // Draw the loupe at the starting position before the first motion event.
    if (loupe) |*l| {
        const p = queryPointer(dpy, root);
        l.update(p.x, p.y);
    }

    var ev: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(dpy, &ev);
        switch (ev.type) {
            c.MotionNotify => {
                // Coalesce queued motion so the loupe never lags behind.
                while (c.XCheckTypedEvent(dpy, c.MotionNotify, &ev) != 0) {}
                if (loupe) |*l| l.update(ev.xmotion.x_root, ev.xmotion.y_root);
            },
            c.ButtonPress => switch (ev.xbutton.button) {
                c.Button1 => return sample(&snap, ev.xbutton.x_root, ev.xbutton.y_root),
                c.Button3 => return null,
                else => {},
            },
            c.KeyPress => {
                const sym = c.XLookupKeysym(&ev.xkey, 0);
                const step: c_int = if (ev.xkey.state & c.ShiftMask != 0) 10 else 1;
                switch (sym) {
                    c.XK_Escape, c.XK_q => return null,
                    c.XK_Return, c.XK_KP_Enter, c.XK_space => {
                        const p = queryPointer(dpy, root);
                        return sample(&snap, p.x, p.y);
                    },
                    c.XK_Left, c.XK_h => nudge(dpy, -step, 0),
                    c.XK_Right, c.XK_l => nudge(dpy, step, 0),
                    c.XK_Up, c.XK_k => nudge(dpy, 0, -step),
                    c.XK_Down, c.XK_j => nudge(dpy, 0, step),
                    else => {},
                }
            },
            c.Expose => if (loupe) |*l| l.redraw(),
            else => {},
        }
    }
}

fn sample(snap: *const Snapshot, x: c_int, y: c_int) ?color.Rgb {
    const cx = std.math.clamp(x, 0, snap.width - 1);
    const cy = std.math.clamp(y, 0, snap.height - 1);
    return snap.rgb(cx, cy);
}

/// Grabbing can fail briefly right after launch (e.g. the terminal still
/// holds the Enter key-release), so retry for a short while.
fn grab(dpy: *c.Display, root: c.Window, cursor: c.Cursor) Error!void {
    const mask: c_uint = @intCast(c.ButtonPressMask | c.PointerMotionMask);
    var pointer_ok = false;
    var keyboard_ok = false;
    for (0..50) |_| {
        if (!pointer_ok) pointer_ok = c.XGrabPointer(dpy, root, c.False, mask, c.GrabModeAsync, c.GrabModeAsync, c.None, cursor, c.CurrentTime) == c.GrabSuccess;
        if (!keyboard_ok) keyboard_ok = c.XGrabKeyboard(dpy, root, c.False, c.GrabModeAsync, c.GrabModeAsync, c.CurrentTime) == c.GrabSuccess;
        if (pointer_ok and keyboard_ok) return;
        _ = c.usleep(10_000);
    }
    // A pointer grab is essential; the keyboard grab is only for Esc/arrows.
    if (!pointer_ok) return error.GrabFailed;
}

const Point = struct { x: c_int, y: c_int };

fn queryPointer(dpy: *c.Display, root: c.Window) Point {
    var root_ret: c.Window = undefined;
    var child_ret: c.Window = undefined;
    var x: c_int = 0;
    var y: c_int = 0;
    var wx: c_int = undefined;
    var wy: c_int = undefined;
    var mask: c_uint = undefined;
    _ = c.XQueryPointer(dpy, root, &root_ret, &child_ret, &x, &y, &wx, &wy, &mask);
    return .{ .x = x, .y = y };
}

fn nudge(dpy: *c.Display, dx: c_int, dy: c_int) void {
    _ = c.XWarpPointer(dpy, c.None, c.None, 0, 0, 0, 0, dx, dy);
    _ = c.XFlush(dpy);
}
