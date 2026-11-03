//! Desktop notification (org.freedesktop.Notifications) with a swatch of the
//! picked color. Best effort: callers ignore failures.

const std = @import("std");
const c = @import("c");
const color = @import("color.zig");
const dbus = @import("portal/dbus.zig");

const swatch_size = 64;

pub fn send(rgb: color.Rgb, summary: []const u8, body: []const u8) dbus.Error!void {
    const conn = try dbus.Connection.session();
    defer conn.deinit();

    const msg = try dbus.methodCall(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
    );
    defer c.dbus_message_unref(msg);

    var summary_buf: [64]u8 = undefined;
    var body_buf: [128]u8 = undefined;
    const summary_z = std.fmt.bufPrintSentinel(&summary_buf, "{s}", .{summary}, 0) catch return error.OutOfMemory;
    const body_z = std.fmt.bufPrintSentinel(&body_buf, "{s}", .{body}, 0) catch return error.OutOfMemory;

    var pixels: [swatch_size * swatch_size * 3]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 3) {
        pixels[i] = rgb.r;
        pixels[i + 1] = rgb.g;
        pixels[i + 2] = rgb.b;
    }

    // Notify(s app_name, u replaces_id, s app_icon, s summary, s body,
    //        as actions, a{sv} hints, i expire_timeout)
    var w = dbus.Writer.init(msg);
    try w.string("pixx");
    try w.uint32(0);
    try w.string("");
    try w.string(summary_z);
    try w.string(body_z);
    var actions = try w.open(c.DBUS_TYPE_ARRAY, "s");
    try w.close(&actions);

    var hints = try w.open(c.DBUS_TYPE_ARRAY, "{sv}");
    {
        var entry = try hints.open(c.DBUS_TYPE_DICT_ENTRY, null);
        try entry.string("image-data");
        var variant = try entry.open(c.DBUS_TYPE_VARIANT, "(iiibiiay)");
        var st = try variant.open(c.DBUS_TYPE_STRUCT, null);
        try st.int32(swatch_size); // width
        try st.int32(swatch_size); // height
        try st.int32(swatch_size * 3); // rowstride
        try st.boolean(false); // has_alpha
        try st.int32(8); // bits_per_sample
        try st.int32(3); // channels
        try st.bytes(&pixels);
        try variant.close(&st);
        try entry.close(&variant);
        try hints.close(&entry);
    }
    try w.close(&hints);
    try w.int32(3000);

    const reply = try conn.call(msg, 1000);
    c.dbus_message_unref(reply);
}
