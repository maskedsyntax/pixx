//! Native X11 clipboard. An X selection is only available while its owner
//! is alive, so a forked child keeps serving the text until another client
//! takes the CLIPBOARD selection.

const std = @import("std");
const c = @import("c");

pub const Error = error{ ForkFailed, OwnershipFailed };

/// Copies `text` to CLIPBOARD and PRIMARY. Returns once the background
/// process owns the selection. With `foreground`, serves in this process and
/// only returns when the selection is lost.
pub fn copy(text: []const u8, foreground: bool) Error!void {
    if (foreground) {
        serve(text, -1) catch return error.OwnershipFailed;
        return;
    }

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.ForkFailed;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child: never return into the parent's code paths.
        _ = c.close(fds[0]);
        detach();
        serve(text, fds[1]) catch c._exit(1);
        c._exit(0);
    }

    // Parent: wait (bounded) for the child to confirm ownership.
    _ = c.close(fds[1]);
    defer _ = c.close(fds[0]);
    var pfd: c.struct_pollfd = .{ .fd = fds[0], .events = c.POLLIN, .revents = 0 };
    if (c.poll(&pfd, 1, 2000) <= 0) return error.OwnershipFailed;
    var byte: u8 = 0;
    if (c.read(fds[0], &byte, 1) != 1 or byte != 1) return error.OwnershipFailed;
}

/// Start a new session and drop the inherited stdio, so that callers like
/// `$(pixx)` see EOF and don't wait for the background child.
fn detach() void {
    _ = c.setsid();
    const devnull = c.open("/dev/null", c.O_RDWR);
    if (devnull >= 0) {
        _ = c.dup2(devnull, 0);
        _ = c.dup2(devnull, 1);
        _ = c.dup2(devnull, 2);
        if (devnull > 2) _ = c.close(devnull);
    }
}

fn serve(text: []const u8, ready_fd: c_int) !void {
    const dpy = c.XOpenDisplay(null) orelse return error.OwnershipFailed;
    defer _ = c.XCloseDisplay(dpy);
    const root = c.XDefaultRootWindow(dpy);
    const win = c.XCreateSimpleWindow(dpy, root, -10, -10, 1, 1, 0, 0, 0);

    const clipboard = c.XInternAtom(dpy, "CLIPBOARD", c.False);
    const primary: c.Atom = c.XA_PRIMARY;
    const atoms = Atoms.init(dpy);

    _ = c.XSetSelectionOwner(dpy, clipboard, win, c.CurrentTime);
    _ = c.XSetSelectionOwner(dpy, primary, win, c.CurrentTime);
    if (c.XGetSelectionOwner(dpy, clipboard) != win) return error.OwnershipFailed;

    if (ready_fd >= 0) {
        const one: u8 = 1;
        _ = c.write(ready_fd, &one, 1);
        _ = c.close(ready_fd);
    }

    var ev: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(dpy, &ev);
        switch (ev.type) {
            c.SelectionRequest => respond(dpy, &ev.xselectionrequest, text, atoms),
            // PRIMARY changes with every text selection; only losing
            // CLIPBOARD ends our job.
            c.SelectionClear => if (ev.xselectionclear.selection == clipboard) return,
            else => {},
        }
    }
}

const Atoms = struct {
    targets: c.Atom,
    utf8: c.Atom,
    text: c.Atom,
    mime_utf8: c.Atom,
    mime_plain: c.Atom,

    fn init(dpy: *c.Display) Atoms {
        return .{
            .targets = c.XInternAtom(dpy, "TARGETS", c.False),
            .utf8 = c.XInternAtom(dpy, "UTF8_STRING", c.False),
            .text = c.XInternAtom(dpy, "TEXT", c.False),
            .mime_utf8 = c.XInternAtom(dpy, "text/plain;charset=utf-8", c.False),
            .mime_plain = c.XInternAtom(dpy, "text/plain", c.False),
        };
    }
};

fn respond(dpy: *c.Display, req: *const c.XSelectionRequestEvent, text: []const u8, a: Atoms) void {
    // Obsolete clients may pass property None; ICCCM says use the target.
    const property = if (req.property == c.None) req.target else req.property;
    const target = req.target;
    const string_atom: c.Atom = c.XA_STRING;

    var reply_property: c.Atom = property;
    if (target == a.targets) {
        const list = [_]c.Atom{ a.targets, a.utf8, string_atom, a.text, a.mime_utf8, a.mime_plain };
        _ = c.XChangeProperty(dpy, req.requestor, property, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&list), list.len);
    } else if (target == a.utf8 or target == string_atom or target == a.text or target == a.mime_utf8 or target == a.mime_plain) {
        // Color strings are ASCII, so STRING (Latin-1) gets the same bytes.
        const prop_type = if (target == a.text) a.utf8 else target;
        _ = c.XChangeProperty(dpy, req.requestor, property, prop_type, 8, c.PropModeReplace, text.ptr, @intCast(text.len));
    } else {
        reply_property = c.None;
    }

    var notify: c.XEvent = std.mem.zeroes(c.XEvent);
    notify.xselection = .{
        .type = c.SelectionNotify,
        .serial = 0,
        .send_event = c.True,
        .display = dpy,
        .requestor = req.requestor,
        .selection = req.selection,
        .target = target,
        .property = reply_property,
        .time = req.time,
    };
    _ = c.XSendEvent(dpy, req.requestor, c.False, 0, &notify);
    _ = c.XFlush(dpy);
}
