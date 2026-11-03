//! Thin helpers over libdbus-1 for the few calls pixx makes.

const std = @import("std");
const c = @import("c");

pub const Error = error{ DBusConnect, DBusCall, OutOfMemory };

/// Mirror of C `DBusError`. Its bitfields make translate-c emit an opaque
/// type, which can't live on the stack, so the layout is spelled out here.
const DBusError = extern struct {
    name: [*c]const u8,
    message: [*c]const u8,
    dummy_bits: c_uint, // dummy1..dummy5 : 1
    padding1: ?*anyopaque,

    fn init() DBusError {
        var e: DBusError = undefined;
        c.dbus_error_init(e.ptr());
        return e;
    }

    fn ptr(self: *DBusError) *c.DBusError {
        return @ptrCast(self);
    }

    fn isSet(self: *DBusError) bool {
        return c.dbus_error_is_set(self.ptr()) != 0;
    }

    fn deinit(self: *DBusError) void {
        c.dbus_error_free(self.ptr());
    }
};

pub const Connection = struct {
    raw: *c.DBusConnection,

    pub fn session() Error!Connection {
        var err = DBusError.init();
        defer err.deinit();
        const raw = c.dbus_bus_get(c.DBUS_BUS_SESSION, err.ptr()) orelse return error.DBusConnect;
        // A short-lived CLI must not be killed by libdbus on disconnect.
        c.dbus_connection_set_exit_on_disconnect(raw, 0);
        return .{ .raw = raw };
    }

    pub fn deinit(self: Connection) void {
        c.dbus_connection_unref(self.raw);
    }

    pub fn uniqueName(self: Connection) []const u8 {
        return std.mem.span(c.dbus_bus_get_unique_name(self.raw));
    }

    pub fn addMatch(self: Connection, rule: [*:0]const u8) Error!void {
        var err = DBusError.init();
        defer err.deinit();
        c.dbus_bus_add_match(self.raw, rule, err.ptr());
        if (err.isSet()) return error.DBusCall;
    }

    /// Sends `msg` and waits for the reply. Prints the D-Bus error name, if
    /// any, to help diagnose portal problems.
    pub fn call(self: Connection, msg: *c.DBusMessage, timeout_ms: c_int) Error!*c.DBusMessage {
        var err = DBusError.init();
        defer err.deinit();
        const reply = c.dbus_connection_send_with_reply_and_block(self.raw, msg, timeout_ms, err.ptr());
        if (reply) |r| return r;
        if (err.isSet()) {
            std.debug.print("pixx: D-Bus error: {s}: {s}\n", .{ std.mem.span(err.name), std.mem.span(err.message) });
        }
        return error.DBusCall;
    }

    /// Blocks until a signal matching `iface.member` on `path` arrives.
    pub fn waitSignal(self: Connection, iface: [*:0]const u8, member: [*:0]const u8, path: [*:0]const u8) Error!*c.DBusMessage {
        while (true) {
            while (c.dbus_connection_pop_message(self.raw)) |msg| {
                if (c.dbus_message_is_signal(msg, iface, member) != 0 and
                    c.dbus_message_has_path(msg, path) != 0)
                {
                    return msg;
                }
                c.dbus_message_unref(msg);
            }
            if (c.dbus_connection_read_write(self.raw, -1) == 0) return error.DBusConnect;
        }
    }
};

pub fn methodCall(dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8) Error!*c.DBusMessage {
    return c.dbus_message_new_method_call(dest, path, iface, method) orelse error.OutOfMemory;
}

/// Wraps a DBusMessageIter for appending arguments.
pub const Writer = struct {
    iter: c.DBusMessageIter,

    pub fn init(msg: *c.DBusMessage) Writer {
        var w: Writer = undefined;
        c.dbus_message_iter_init_append(msg, &w.iter);
        return w;
    }

    fn basic(self: *Writer, dbus_type: c_int, value: *const anyopaque) Error!void {
        if (c.dbus_message_iter_append_basic(&self.iter, dbus_type, value) == 0) return error.OutOfMemory;
    }

    pub fn string(self: *Writer, s: [*:0]const u8) Error!void {
        const ptr: [*c]const u8 = s;
        try self.basic(c.DBUS_TYPE_STRING, @ptrCast(&ptr));
    }

    pub fn uint32(self: *Writer, v: u32) Error!void {
        try self.basic(c.DBUS_TYPE_UINT32, @ptrCast(&v));
    }

    pub fn int32(self: *Writer, v: i32) Error!void {
        try self.basic(c.DBUS_TYPE_INT32, @ptrCast(&v));
    }

    pub fn boolean(self: *Writer, v: bool) Error!void {
        const b: c.dbus_bool_t = @intFromBool(v);
        try self.basic(c.DBUS_TYPE_BOOLEAN, @ptrCast(&b));
    }

    pub fn bytes(self: *Writer, data: []const u8) Error!void {
        var sub = try self.open(c.DBUS_TYPE_ARRAY, "y");
        const ptr: [*c]const u8 = data.ptr;
        if (c.dbus_message_iter_append_fixed_array(&sub.iter, c.DBUS_TYPE_BYTE, @ptrCast(&ptr), @intCast(data.len)) == 0)
            return error.OutOfMemory;
        try self.close(&sub);
    }

    pub fn open(self: *Writer, dbus_type: c_int, signature: ?[*:0]const u8) Error!Writer {
        var sub: Writer = undefined;
        if (c.dbus_message_iter_open_container(&self.iter, dbus_type, signature, &sub.iter) == 0) return error.OutOfMemory;
        return sub;
    }

    pub fn close(self: *Writer, sub: *Writer) Error!void {
        if (c.dbus_message_iter_close_container(&self.iter, &sub.iter) == 0) return error.OutOfMemory;
    }
};
