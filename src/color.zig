const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Build from 0.0–1.0 channel values (as returned by the XDG portal).
    pub fn fromUnit(r: f64, g: f64, b: f64) Rgb {
        return .{ .r = unitToByte(r), .g = unitToByte(g), .b = unitToByte(b) };
    }

    /// Relative luminance approximation, used to pick a contrasting overlay.
    pub fn isLight(self: Rgb) bool {
        const y = 299 * @as(u32, self.r) + 587 * @as(u32, self.g) + 114 * @as(u32, self.b);
        return y > 128_000;
    }
};

fn unitToByte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}

pub const Format = enum { hex, rgb, hsl };

pub const Hsl = struct { h: u16, s: u8, l: u8 };

pub fn toHsl(c: Rgb) Hsl {
    const r = @as(f64, @floatFromInt(c.r)) / 255.0;
    const g = @as(f64, @floatFromInt(c.g)) / 255.0;
    const b = @as(f64, @floatFromInt(c.b)) / 255.0;
    const max = @max(r, g, b);
    const min = @min(r, g, b);
    const l = (max + min) / 2.0;
    const d = max - min;

    var h: f64 = 0;
    var s: f64 = 0;
    if (d > 0) {
        s = d / (1.0 - @abs(2.0 * l - 1.0));
        if (max == r) {
            h = 60.0 * @mod((g - b) / d, 6.0);
        } else if (max == g) {
            h = 60.0 * ((b - r) / d + 2.0);
        } else {
            h = 60.0 * ((r - g) / d + 4.0);
        }
    }
    const hue: u16 = @intFromFloat(@round(h));
    return .{
        .h = hue % 360,
        .s = @intFromFloat(@round(s * 100.0)),
        .l = @intFromFloat(@round(l * 100.0)),
    };
}

/// Writes the color in the requested format into `buf` and returns the slice.
/// 32 bytes is always enough.
pub fn format(buf: []u8, c: Rgb, fmt: Format, upper: bool) []const u8 {
    const out = switch (fmt) {
        .hex => if (upper)
            std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b })
        else
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }),
        .rgb => std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ c.r, c.g, c.b }),
        .hsl => blk: {
            const v = toHsl(c);
            break :blk std.fmt.bufPrint(buf, "hsl({d}, {d}%, {d}%)", .{ v.h, v.s, v.l });
        },
    };
    return out catch unreachable;
}

const testing = std.testing;

fn expectFmt(expected: []const u8, c: Rgb, fmt: Format, upper: bool) !void {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(expected, format(&buf, c, fmt, upper));
}

test "hex" {
    try expectFmt("#1e90ff", .{ .r = 30, .g = 144, .b = 255 }, .hex, false);
    try expectFmt("#1E90FF", .{ .r = 30, .g = 144, .b = 255 }, .hex, true);
    try expectFmt("#000000", .{ .r = 0, .g = 0, .b = 0 }, .hex, false);
    try expectFmt("#0a0b0c", .{ .r = 10, .g = 11, .b = 12 }, .hex, false);
}

test "rgb" {
    try expectFmt("rgb(30, 144, 255)", .{ .r = 30, .g = 144, .b = 255 }, .rgb, false);
}

test "hsl" {
    try expectFmt("hsl(210, 100%, 56%)", .{ .r = 30, .g = 144, .b = 255 }, .hsl, false);
    try expectFmt("hsl(0, 0%, 0%)", .{ .r = 0, .g = 0, .b = 0 }, .hsl, false);
    try expectFmt("hsl(0, 0%, 100%)", .{ .r = 255, .g = 255, .b = 255 }, .hsl, false);
    try expectFmt("hsl(0, 0%, 50%)", .{ .r = 128, .g = 128, .b = 128 }, .hsl, false);
    try expectFmt("hsl(0, 100%, 50%)", .{ .r = 255, .g = 0, .b = 0 }, .hsl, false);
    try expectFmt("hsl(120, 100%, 50%)", .{ .r = 0, .g = 255, .b = 0 }, .hsl, false);
    try expectFmt("hsl(240, 100%, 50%)", .{ .r = 0, .g = 0, .b = 255 }, .hsl, false);
    // Hue just below 360 must wrap to 0, not print 360.
    try expectFmt("hsl(0, 100%, 50%)", .{ .r = 255, .g = 0, .b = 1 }, .hsl, false);
}

test "fromUnit" {
    const c = Rgb.fromUnit(0.1176, 0.5647, 1.0);
    try testing.expectEqual(Rgb{ .r = 30, .g = 144, .b = 255 }, c);
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, Rgb.fromUnit(-0.5, 0, 2));
}
