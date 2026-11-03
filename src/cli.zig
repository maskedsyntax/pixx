const std = @import("std");
const color = @import("color.zig");

pub const version = "0.1.0";

pub const Backend = enum { auto, x11, portal };

pub const Options = struct {
    format: color.Format = .hex,
    upper: bool = false,
    copy: bool = true,
    notify: bool = true,
    loupe: bool = true,
    backend: Backend = .auto,
    foreground: bool = false,
};

pub const Action = union(enum) {
    run: Options,
    help,
    version,
};

pub const usage =
    \\Usage: pixx [options]
    \\
    \\Pick a color from anywhere on screen. Prints it and copies it to the clipboard.
    \\
    \\Options:
    \\  -f, --format <hex|rgb|hsl>   Output format (default: hex)
    \\  -u, --upper                  Uppercase hex digits
    \\  -n, --no-copy                Don't copy to the clipboard
    \\      --no-notify              Don't show a desktop notification
    \\      --no-loupe               Don't show the magnifier (X11)
    \\  -b, --backend <auto|x11|portal>
    \\                               Force a backend (default: auto)
    \\      --foreground             Serve the X11 clipboard without forking (debug)
    \\  -h, --help                   Show this help
    \\  -V, --version                Show the version
    \\
    \\While picking (X11):
    \\  Left click, Enter, Space     Pick the pixel under the cursor
    \\  Arrow keys / hjkl            Move the cursor 1px (Shift: 10px)
    \\  Esc, q, right click          Cancel
    \\
    \\Exit status: 0 picked, 1 cancelled, 2 error.
    \\
;

pub const ParseError = error{ UnknownOption, MissingValue, InvalidValue };

pub fn parse(args: []const []const u8) ParseError!Action {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-h") or eq(arg, "--help")) return .help;
        if (eq(arg, "-V") or eq(arg, "--version")) return .version;

        if (eq(arg, "-u") or eq(arg, "--upper")) {
            opts.upper = true;
        } else if (eq(arg, "-n") or eq(arg, "--no-copy")) {
            opts.copy = false;
        } else if (eq(arg, "--no-notify")) {
            opts.notify = false;
        } else if (eq(arg, "--no-loupe")) {
            opts.loupe = false;
        } else if (eq(arg, "--foreground")) {
            opts.foreground = true;
        } else if (valueOf(arg, "-f", "--format")) |inline_val| {
            const v = inline_val orelse try next(args, &i);
            opts.format = std.meta.stringToEnum(color.Format, v) orelse return error.InvalidValue;
        } else if (valueOf(arg, "-b", "--backend")) |inline_val| {
            const v = inline_val orelse try next(args, &i);
            opts.backend = std.meta.stringToEnum(Backend, v) orelse return error.InvalidValue;
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .run = opts };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Matches `-x`, `--long`, or `--long=value`. Returns null if `arg` is not
/// this option, `@as(?[]const u8, null)` if the value is the next argument.
fn valueOf(arg: []const u8, short: []const u8, long: []const u8) ??[]const u8 {
    if (eq(arg, short) or eq(arg, long)) return @as(?[]const u8, null);
    if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=')
        return arg[long.len + 1 ..];
    return null;
}

fn next(args: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

test "defaults" {
    const a = try parse(&.{});
    try std.testing.expectEqual(Options{}, a.run);
}

test "flags and values" {
    const a = try parse(&.{ "-f", "rgb", "--no-copy", "--backend=portal", "-u" });
    try std.testing.expectEqual(color.Format.rgb, a.run.format);
    try std.testing.expect(!a.run.copy);
    try std.testing.expect(a.run.upper);
    try std.testing.expectEqual(Backend.portal, a.run.backend);
    try std.testing.expectEqual(color.Format.hsl, (try parse(&.{"--format=hsl"})).run.format);
}

test "errors" {
    try std.testing.expectError(error.UnknownOption, parse(&.{"--nope"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"-f"}));
    try std.testing.expectError(error.InvalidValue, parse(&.{ "-f", "cmyk" }));
    try std.testing.expectEqual(Action.help, try parse(&.{ "-n", "--help" }));
}
