//! Wayland backend: ask the desktop for a color through the XDG Desktop
//! Portal (org.freedesktop.portal.Screenshot.PickColor). The compositor
//! draws its own picker UI, so there is no pixx loupe here.

const std = @import("std");
const c = @import("c");
const color = @import("../color.zig");
const dbus = @import("dbus.zig");

pub const Error = dbus.Error || error{ PortalUnavailable, BadResponse };

const request_iface = "org.freedesktop.portal.Request";

/// Returns the picked color, or null if the user cancelled.
pub fn pick() Error!?color.Rgb {
    const conn = try dbus.Connection.session();
    defer conn.deinit();

    // Work out the request object path up front and subscribe to its
    // Response signal *before* calling, so a fast reply can't be missed.
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrintSentinel(&token_buf, "pixx{d}", .{c.getpid()}, 0) catch unreachable;

    var sender_buf: [128]u8 = undefined;
    const sender = senderPathComponent(&sender_buf, conn.uniqueName());

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender, token }, 0) catch
        return error.BadResponse;

    var rule_buf: [512]u8 = undefined;
    const rule = std.fmt.bufPrintSentinel(&rule_buf, "type='signal',interface='" ++ request_iface ++ "',member='Response',path='{s}'", .{path}, 0) catch
        return error.BadResponse;
    try conn.addMatch(rule);

    const msg = try dbus.methodCall(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot",
        "PickColor",
    );
    defer c.dbus_message_unref(msg);
    {
        var w = dbus.Writer.init(msg);
        try w.string(""); // parent_window
        var opts = try w.open(c.DBUS_TYPE_ARRAY, "{sv}");
        var entry = try opts.open(c.DBUS_TYPE_DICT_ENTRY, null);
        try entry.string("handle_token");
        var variant = try entry.open(c.DBUS_TYPE_VARIANT, "s");
        try variant.string(token);
        try entry.close(&variant);
        try opts.close(&entry);
        try w.close(&opts);
    }

    const reply = conn.call(msg, 5000) catch return error.PortalUnavailable;
    c.dbus_message_unref(reply);

    const signal = try conn.waitSignal(request_iface, "Response", path);
    defer c.dbus_message_unref(signal);
    return parseResponse(signal);
}

/// ":1.42" -> "1_42", per the portal's request path convention.
fn senderPathComponent(buf: []u8, unique: []const u8) []const u8 {
    const name = if (unique.len > 0 and unique[0] == ':') unique[1..] else unique;
    const n = @min(name.len, buf.len);
    for (name[0..n], buf[0..n]) |ch, *out| out.* = if (ch == '.') '_' else ch;
    return buf[0..n];
}

/// Response signature: (u response, a{sv} results). results["color"] is (ddd).
fn parseResponse(msg: *c.DBusMessage) Error!?color.Rgb {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return error.BadResponse;
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_UINT32) return error.BadResponse;
    var response: u32 = 0;
    c.dbus_message_iter_get_basic(&it, @ptrCast(&response));
    if (response != 0) return null; // 1 = cancelled, 2 = other error

    if (c.dbus_message_iter_next(&it) == 0 or c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_ARRAY)
        return error.BadResponse;

    var dict: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&it, &dict);
    while (c.dbus_message_iter_get_arg_type(&dict) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&dict)) {
        var entry: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&dict, &entry);
        var key: [*c]const u8 = null;
        c.dbus_message_iter_get_basic(&entry, @ptrCast(&key));
        if (!std.mem.eql(u8, std.mem.span(key), "color")) continue;

        _ = c.dbus_message_iter_next(&entry);
        var variant: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&entry, &variant);
        if (c.dbus_message_iter_get_arg_type(&variant) != c.DBUS_TYPE_STRUCT) return error.BadResponse;

        var st: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&variant, &st);
        var rgb: [3]f64 = undefined;
        for (&rgb, 0..) |*v, i| {
            if (c.dbus_message_iter_get_arg_type(&st) != c.DBUS_TYPE_DOUBLE) return error.BadResponse;
            c.dbus_message_iter_get_basic(&st, @ptrCast(v));
            if (i < 2) _ = c.dbus_message_iter_next(&st);
        }
        return color.Rgb.fromUnit(rgb[0], rgb[1], rgb[2]);
    }
    return error.BadResponse;
}

test "sender path component" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1_42", senderPathComponent(&buf, ":1.42"));
    try std.testing.expectEqualStrings("1_2_3", senderPathComponent(&buf, ":1.2.3"));
}
