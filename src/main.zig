const std = @import("std");
const color = @import("color.zig");
const cli = @import("cli.zig");
const clipboard = @import("clipboard.zig");
const notify = @import("notify.zig");
const x11_picker = @import("x11/picker.zig");
const portal_picker = @import("portal/picker.zig");

const exit_cancelled = 1;
const exit_error = 2;

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch fail("out of memory", .{});

    const opts = switch (cli.parse(args[1..]) catch |err| {
        std.debug.print("pixx: {s}\n\n{s}", .{ parseErrorText(err), cli.usage });
        std.process.exit(exit_error);
    }) {
        .help => {
            writeStdout(init.io, cli.usage);
            return;
        },
        .version => {
            writeStdout(init.io, "pixx " ++ cli.version ++ "\n");
            return;
        },
        .run => |o| o,
    };

    const env = init.environ_map;
    const on_wayland = env.get("WAYLAND_DISPLAY") != null;
    const backend: cli.Backend = switch (opts.backend) {
        .auto => if (on_wayland)
            .portal
        else if (env.get("DISPLAY") != null)
            .x11
        else
            fail("no display found (neither WAYLAND_DISPLAY nor DISPLAY is set)", .{}),
        else => |b| b,
    };

    const picked = switch (backend) {
        .x11 => x11_picker.pick(.{ .loupe = opts.loupe }) catch |err| fail("X11 picker failed: {s}", .{x11ErrorText(err)}),
        .portal => portal_picker.pick() catch |err| fail("portal picker failed: {s}", .{portalErrorText(err)}),
        .auto => unreachable,
    };
    const rgb = picked orelse std.process.exit(exit_cancelled);

    var buf: [32]u8 = undefined;
    const text = color.format(&buf, rgb, opts.format, opts.upper);

    // Print before forking the clipboard server so output isn't duplicated.
    var line_buf: [40]u8 = undefined;
    writeStdout(init.io, std.fmt.bufPrint(&line_buf, "{s}\n", .{text}) catch unreachable);

    const session: clipboard.Session = if (on_wayland) .wayland else .x11;
    // --foreground blocks until the selection is lost, so it runs last.
    const serve_in_foreground = opts.copy and opts.foreground and session == .x11;

    var copied = serve_in_foreground;
    if (opts.copy and !serve_in_foreground) {
        if (clipboard.copy(session, text, false)) {
            copied = true;
        } else |err| {
            std.debug.print("pixx: could not copy to clipboard: {s}\n", .{clipboardErrorText(err)});
        }
    }

    if (opts.notify) {
        const body = if (copied) "Copied to clipboard" else if (opts.copy) "Could not copy to clipboard" else "Picked color";
        notify.send(rgb, text, body) catch {};
    }

    if (serve_in_foreground) {
        clipboard.copy(.x11, text, true) catch |err|
            fail("could not copy to clipboard: {s}", .{clipboardErrorText(err)});
    }
}

fn writeStdout(io: std.Io, bytes: []const u8) void {
    var out_buf: [1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    fw.interface.writeAll(bytes) catch {};
    fw.interface.flush() catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("pixx: " ++ fmt ++ "\n", args);
    std.process.exit(exit_error);
}

fn parseErrorText(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown option",
        error.MissingValue => "option is missing its value",
        error.InvalidValue => "invalid option value",
    };
}

fn x11ErrorText(err: x11_picker.Error) []const u8 {
    return switch (err) {
        error.NoDisplay => "cannot open X display",
        error.SnapshotFailed => "cannot read the screen",
        error.GrabFailed => "cannot grab the pointer (another app may hold it)",
    };
}

fn portalErrorText(err: portal_picker.Error) []const u8 {
    return switch (err) {
        error.DBusConnect => "cannot connect to the D-Bus session bus",
        error.PortalUnavailable => "the desktop portal does not support PickColor",
        else => @errorName(err),
    };
}

fn clipboardErrorText(err: clipboard.Error) []const u8 {
    return switch (err) {
        error.WlCopyMissing => "wl-copy not found (install wl-clipboard)",
        error.OwnershipFailed => "could not take ownership of the X selection",
        else => @errorName(err),
    };
}

test {
    _ = color;
    _ = cli;
    _ = portal_picker;
}
