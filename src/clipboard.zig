//! Picks the clipboard mechanism for the current session.

const std = @import("std");
const c = @import("c");
const x11 = @import("x11/clipboard.zig");

pub const Session = enum { x11, wayland };

pub const Error = x11.Error || error{ WlCopyMissing, WlCopyFailed };

pub fn copy(session: Session, text: []const u8, foreground: bool) Error!void {
    switch (session) {
        .x11 => try x11.copy(text, foreground),
        .wayland => try wlCopy(text),
    }
}

/// Wayland has no portable way for a window-less client to set the
/// clipboard (GNOME lacks data-control), so v1 delegates to wl-copy.
fn wlCopy(text: []const u8) Error!void {
    // Check first: writing to a pipe whose reader never started would SIGPIPE.
    if (c.system("command -v wl-copy >/dev/null 2>&1") != 0) return error.WlCopyMissing;
    // wl-copy forks to serve; detach its stdio so `$(pixx)` doesn't hang.
    const pipe = c.popen("wl-copy >/dev/null 2>&1", "w") orelse return error.WlCopyFailed;
    const written = c.fwrite(text.ptr, 1, text.len, pipe);
    if (c.pclose(pipe) != 0 or written != text.len) return error.WlCopyFailed;
}
