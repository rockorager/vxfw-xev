//! XevApp is a libxev based vxfw app runtime
const XevApp = @This();

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const xev = @import("xev");

const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.xev_app);

gpa: Allocator,
vx: vaxis.Vaxis,
loop: *xev.Loop,
root: vxfw.Widget,

tty: switch (xev.backend) {
    // io_uring supports asynchronous device reads
    .io_uring => AsyncTty,

    // All other backends require a threaded tty
    .epoll,
    .iocp,
    .kqueue,
    .wasi_poll,
    => ThreadedTty,
},

focus_handler: FocusHandler,
mouse_handler: MouseHandler,
wants_focus: ?vxfw.Widget,

event_context: vxfw.EventContext,

tick_pool: std.heap.MemoryPool(TickCallback),

draw_c: xev.Completion,
frame_arena: std.heap.ArenaAllocator,

/// Initializes an Application. This opens the tty and initalizes vaxis. Callbacks are added to the
/// provided loop
pub fn init(self: *XevApp, gpa: Allocator, loop: *xev.Loop, root: vxfw.Widget) !void {
    self.* = .{
        .gpa = gpa,
        .tty = undefined,
        .vx = try vaxis.init(gpa, .{
            .system_clipboard_allocator = gpa,
            .kitty_keyboard_flags = .{ .report_events = true },
        }),
        .loop = loop,
        .root = root,
        .focus_handler = undefined,
        .mouse_handler = MouseHandler.init(root),
        .wants_focus = null,
        .event_context = .{
            .redraw = true,
            .cmds = vxfw.CommandList.init(gpa),
        },
        .tick_pool = std.heap.MemoryPool(TickCallback).init(gpa),
        .draw_c = .{},
        .frame_arena = std.heap.ArenaAllocator.init(gpa),
    };

    vxfw.DrawContext.init(&self.vx.unicode, .unicode);

    try self.focus_handler.init(gpa, root);

    try self.tty.init(self, loop);
}

pub fn deinit(self: *XevApp) void {
    self.focus_handler.deinit();
    self.mouse_handler.deinit(self.gpa);
    self.event_context.cmds.deinit();
    // blocking deinit on vaxis
    self.vx.deinit(self.gpa, self.tty.tty.anyWriter());
    self.tty.deinit();
    self.tick_pool.deinit();
    self.frame_arena.deinit();
}

pub fn run(self: *XevApp) anyerror!void {
    try self.focus_handler.handleEvent(&self.event_context, .init);
    try self.handleCommands();

    try self.vx.enterAltScreen(self.tty.anyWriter());
    try self.vx.queryTerminalSend(self.tty.anyWriter());
    try self.vx.setMouseMode(self.tty.anyWriter(), true);

    // Start a draw timer
    const timer: xev.Timer = .{};
    timer.run(self.loop, &self.draw_c, 8, XevApp, self, XevApp.drawCallback);

    try self.loop.run(.until_done);
}

pub fn drawCallback(
    maybe_self: ?*XevApp,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = maybe_self orelse unreachable;
    _ = result catch |err| {
        log.err("timer error: {}", .{err});
    };

    switch (xev.backend) {
        .io_uring => {},

        .epoll,
        .iocp,
        .kqueue,
        .wasi_poll,
        => self.tty.drainQueue() catch |err| {
            log.err("drainQueue: {}", .{err});
            return .disarm;
        },
    }

    if (self.event_context.quit) return .disarm;

    _ = loop;
    _ = completion;
    if (self.event_context.redraw) {
        self.event_context.redraw = false;
        log.debug("redrawing", .{});
        _ = self.frame_arena.reset(.retain_capacity);
        const win = self.vx.window();
        win.clear();
        const ctx: vxfw.DrawContext = .{
            .min = .{ .height = 0, .width = 0 },
            .max = .{ .height = win.height, .width = win.width },
            .cell_size = .{ .height = 0, .width = 0 },
            .arena = self.frame_arena.allocator(),
        };
        const surface = self.root.draw(ctx) catch {
            log.err("out of memory", .{});
            return .disarm;
        };
        surface.render(win, self.focus_handler.focused_widget);
        self.vx.render(self.tty.anyWriter()) catch |err| {
            log.err("render error: {}", .{err});
            return .disarm;
        };

        self.focus_handler.update(surface) catch {};
        self.mouse_handler.last_frame = surface;
    }

    return .rearm;
}

pub fn resetEventContext(self: *XevApp) void {
    self.event_context.consume_event = false;
    self.event_context.phase = .at_target;
    self.event_context.quit = false;
    self.event_context.cmds.clearRetainingCapacity();

    // We don't reset redraw
}

/// Parses a stream of bytes read from a TTY into input events. Returns the number of bytes consumed
pub fn parse(self: *XevApp, buf: []const u8) !usize {
    var parser: vaxis.Parser = .{ .grapheme_data = &self.vx.unicode.width_data.g_data };
    var idx: usize = 0;
    while (idx < buf.len) {
        const result = try parser.parse(buf[idx..], self.gpa);
        if (result.n == 0) {
            return idx;
        }
        idx += result.n;
        if (result.event) |event| {
            try self.handleEvent(event);
        }
    }
    return idx;
}

pub fn handleEvent(self: *XevApp, event: vaxis.Event) !void {
    self.resetEventContext();
    switch (event) {
        .key_press => |key| {
            // Check for a cursor position response for our explicity width query. This will
            // always be an F3 key with shift = true, and we must be looking for queries
            if (key.codepoint == vaxis.Key.f3 and
                key.mods.shift and
                !self.vx.queries_done.load(.unordered))
            {
                self.vx.caps.explicit_width = true;
                self.vx.caps.unicode = .unicode;
                self.vx.screen.width_method = .unicode;
                return;
            }

            try self.focus_handler.handleEvent(&self.event_context, .{ .key_press = key });
            try self.handleCommands();
            if (self.event_context.quit) {
                self.loop.stop();
                return;
            }
        },

        .key_release => |key| {
            _ = key;
        },
        .mouse => |mouse| {
            try self.mouse_handler.handleMouse(
                self,
                &self.event_context,
                self.vx.translateMouse(mouse),
            );
        },
        .focus_out => try self.mouse_handler.mouseExit(self, &self.event_context),
        .focus_in,
        .paste_start, // bracketed paste start
        .paste_end, // bracketed paste end
        => {},
        .paste => {},
        .color_report => {},
        .color_scheme => {},
        .winsize => |ws| {
            self.event_context.redraw = true;
            if (!self.vx.state.in_band_resize) {
                self.vx.state.in_band_resize = true;
                if (@hasDecl(vaxis.Tty, "resetSignalHandler")) {
                    vaxis.Tty.resetSignalHandler();
                }
            }
            if (self.vx.screen.width != ws.cols or
                self.vx.screen.height != ws.rows or
                self.vx.screen.height_pix != ws.y_pixel or
                self.vx.screen.width_pix != ws.x_pixel)
            {
                try self.vx.resize(self.gpa, self.tty.anyWriter(), ws);
            }
        },

        // these are delivered as discovered terminal capabilities
        .cap_kitty_keyboard => self.vx.caps.kitty_keyboard = true,
        .cap_kitty_graphics => self.vx.caps.kitty_graphics = true,
        .cap_rgb => self.vx.caps.rgb = true,
        .cap_sgr_pixels => self.vx.caps.sgr_pixels = true,
        .cap_unicode => {
            self.vx.screen.width_method = .unicode;
            self.vx.caps.unicode = .unicode;
        },
        .cap_color_scheme_updates => self.vx.caps.color_scheme_updates = true,
        .cap_da1 => {
            self.vx.queries_done.store(true, .unordered);
            log.debug("queries done", .{});
            vxfw.DrawContext.init(&self.vx.unicode, self.vx.caps.unicode);
            try self.vx.enableDetectedFeatures(self.tty.anyWriter());
            try self.vx.setMouseMode(self.tty.anyWriter(), true);
        },
    }
    if (self.wants_focus) |focus| {
        self.resetEventContext();
        try self.focus_handler.focusWidget(&self.event_context, focus);
        try self.handleCommands();
        self.wants_focus = null;
    }
}

pub fn handleCommands(self: *XevApp) anyerror!void {
    const cmds = &self.event_context.cmds;
    defer cmds.clearRetainingCapacity();
    for (cmds.items) |cmd| {
        switch (cmd) {
            .tick => |tick| try self.addTick(tick),
            .set_mouse_shape => |shape| self.vx.setMouseShape(shape),
            .request_focus => |widget| self.wants_focus = widget,
            .copy_to_clipboard => |content| {
                try self.vx.copyToSystemClipboard(self.tty.anyWriter(), content, self.gpa);
            },
        }
    }
}

pub const TickCallback = struct {
    app: *XevApp,
    widget: vxfw.Widget,
    completion: xev.Completion,

    pub fn execute(
        maybe_self: ?*TickCallback,
        _: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| {
            log.err("timer error: {}", .{err});
            return .disarm;
        };
        const self = maybe_self orelse return .disarm;
        defer {
            self.app.gpa.destroy(completion);
            self.app.gpa.destroy(self);
        }

        self.app.resetEventContext();
        self.widget.handleEvent(&self.app.event_context, .tick) catch {};
        self.app.handleCommands() catch {};
        return .disarm;
    }
};

pub fn addTick(self: *XevApp, tick: vxfw.Tick) anyerror!void {
    const timer: xev.Timer = .{};
    const next_ms = tick.deadline_ms - std.time.milliTimestamp();
    if (next_ms < 0) {
        // call the callback now
        self.resetEventContext();
        try tick.widget.handleEvent(&self.event_context, .tick);
        try self.handleCommands();
    } else {
        const cb = try self.tick_pool.create();
        cb.* = .{
            .app = self,
            .widget = tick.widget,
            .completion = .{},
        };
        timer.run(self.loop, &cb.completion, @intCast(next_ms), TickCallback, cb, TickCallback.execute);
    }
}

pub const AsyncTty = struct {
    app: *XevApp,
    tty: vaxis.Tty,
    file: xev.File,

    read_c: xev.Completion,
    read_buf: [4096]u8,

    write_c: xev.Completion,
    write_list: std.ArrayList(u8),
    write_in_flight: bool,

    pub fn init(self: *AsyncTty, app: *XevApp, loop: *xev.Loop) !void {
        const tty = try vaxis.Tty.init();
        self.* = .{
            .app = app,
            .tty = tty,
            .file = xev.File.initFd(tty.fd),
            .read_c = .{},
            .read_buf = undefined,
            .write_c = .{},
            .write_list = std.ArrayList(u8).init(app.gpa),
            .write_in_flight = false,
        };

        self.file.read(
            loop,
            &self.read_c,
            .{ .slice = &self.read_buf },
            AsyncTty,
            self,
            AsyncTty.readCallback,
        );
    }

    pub fn deinit(self: *AsyncTty) void {
        self.tty.deinit();
        self.write_list.deinit();
    }

    pub fn readCallback(
        maybe_self: ?*AsyncTty,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = maybe_self orelse unreachable;
        const n = result catch |err| {
            log.err("read error: {}", .{err});
            return .disarm;
        };

        if (n == 0) return .disarm;
        const total = self.app.parse(self.read_buf[0..n]) catch @panic("TODO");

        const unread_cnt = n -| total;
        if (unread_cnt > 0) {
            // Copy the unread bytes to the beginning
            std.mem.copyForwards(u8, self.read_buf[0..unread_cnt], self.read_buf[total..n]);
        }

        // Add a new read request
        self.file.read(
            loop,
            &self.read_c,
            .{ .slice = self.read_buf[unread_cnt..] },
            AsyncTty,
            self,
            AsyncTty.readCallback,
        );
        return .disarm;
    }

    pub fn anyWriter(self: *AsyncTty) std.io.AnyWriter {
        return .{
            .context = self,
            .writeFn = AsyncTty.writeFn,
        };
    }

    pub fn writeFn(ptr: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *AsyncTty = @constCast(@ptrCast(@alignCast(ptr)));
        return self.write(bytes);
    }

    pub fn write(self: *AsyncTty, bytes: []const u8) anyerror!usize {
        try self.write_list.appendSlice(bytes);

        try self.queueWrite(self.app.loop);
        return bytes.len;
    }

    pub fn queueWrite(self: *AsyncTty, loop: *xev.Loop) Allocator.Error!void {
        // If a write is in flight, we will end up requeuing a write in the callback
        if (self.write_in_flight or self.write_list.items.len == 0) return;
        // Dupe the contents of the list
        const bytes = try self.app.gpa.dupe(u8, self.write_list.items);

        log.debug("queuing {d} bytes", .{bytes.len});
        log.debug("write capacity {d} bytes", .{self.write_list.capacity});
        self.write_in_flight = true;
        // If a write is not in flight, queue a new request
        self.file.write(
            loop,
            &self.write_c,
            .{ .slice = bytes },
            AsyncTty,
            self,
            AsyncTty.writeCallback,
        );
    }

    pub fn writeCallback(
        maybe_self: ?*AsyncTty,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        buffer: xev.WriteBuffer,
        result: xev.File.WriteError!usize,
    ) xev.CallbackAction {
        const self = maybe_self orelse unreachable;
        self.write_in_flight = false;
        const n = result catch |err| {
            log.err("write error: {}", .{err});
            return .disarm;
        };

        // Free the full buffer
        self.app.gpa.free(buffer.slice);

        // Shorten the write_list.
        self.write_list.replaceRangeAssumeCapacity(0, n, "");

        self.queueWrite(loop) catch log.err("out of memory", .{});

        return .disarm;
    }
};

pub const ThreadedTty = struct {
    const EventLoop = vaxis.Loop(vaxis.Event);

    app: *XevApp,
    tty: vaxis.Tty,
    loop: EventLoop,

    write_c: xev.Completion,
    write_list: std.ArrayList(u8),
    write_in_flight: bool,

    pub fn init(self: *ThreadedTty, app: *XevApp, _: *xev.Loop) !void {
        self.* = .{
            .app = app,
            .tty = try vaxis.Tty.init(),
            .loop = .{ .tty = &self.tty, .vaxis = &app.vx },
            .write_c = .{},
            .write_list = std.ArrayList(u8).init(app.gpa),
            .write_in_flight = false,
        };
        try self.loop.start();
    }

    pub fn deinit(self: *ThreadedTty) void {
        self.loop.stop();
        self.tty.deinit();
        self.write_list.deinit();
    }

    pub fn drainQueue(self: *ThreadedTty) !void {
        while (self.loop.tryEvent()) |event| {
            try self.app.handleEvent(event);
            if (self.app.event_context.quit) return;
        }
    }

    // pub fn anyWriter(self: *ThreadedTty) std.io.AnyWriter {
    //     return self.tty.anyWriter();
    // }
    pub fn anyWriter(self: *ThreadedTty) std.io.AnyWriter {
        return switch (builtin.os.tag) {
            .windows => self.tty.anyWriter(),
            else => .{
                .context = self,
                .writeFn = ThreadedTty.writeFn,
            },
        };
    }

    pub fn writeFn(ptr: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *ThreadedTty = @constCast(@ptrCast(@alignCast(ptr)));
        return self.write(bytes);
    }

    pub fn write(self: *ThreadedTty, bytes: []const u8) anyerror!usize {
        try self.write_list.appendSlice(bytes);

        try self.queueWrite(self.app.loop);
        return bytes.len;
    }

    pub fn queueWrite(self: *ThreadedTty, loop: *xev.Loop) Allocator.Error!void {
        // If a write is in flight, we will end up requeuing a write in the callback
        if (self.write_in_flight or self.write_list.items.len == 0) return;
        // Dupe the contents of the list
        const bytes = try self.app.gpa.dupe(u8, self.write_list.items);

        log.debug("queuing {d} bytes", .{bytes.len});
        log.debug("write capacity {d} bytes", .{self.write_list.capacity});
        self.write_in_flight = true;

        const file: xev.File = switch (builtin.os.tag) {
            .windows => .{ .fd = self.tty.stdout },
            else => .{ .fd = self.tty.fd },
        };
        file.write(
            loop,
            &self.write_c,
            .{ .slice = bytes },
            ThreadedTty,
            self,
            ThreadedTty.writeCallback,
        );
    }

    pub fn writeCallback(
        maybe_self: ?*ThreadedTty,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        buffer: xev.WriteBuffer,
        result: xev.File.WriteError!usize,
    ) xev.CallbackAction {
        const self = maybe_self orelse unreachable;
        self.write_in_flight = false;
        const n = result catch |err| {
            log.err("write error: {}", .{err});
            return .disarm;
        };

        // Free the full buffer
        self.app.gpa.free(buffer.slice);

        // Shorten the write_list.
        self.write_list.replaceRangeAssumeCapacity(0, n, "");

        self.queueWrite(loop) catch log.err("out of memory", .{});

        return .disarm;
    }
};

/// Maintains a tree of focusable nodes. Delivers events to the currently focused node, walking up
/// the tree until the event is handled
const FocusHandler = struct {
    arena: std.heap.ArenaAllocator,

    root: Node,
    focused: *Node,
    focused_widget: vxfw.Widget,
    path_to_focused: std.ArrayList(vxfw.Widget),

    const Node = struct {
        widget: vxfw.Widget,
        parent: ?*Node,
        children: []*Node,

        fn nextSibling(self: Node) ?*Node {
            const parent = self.parent orelse return null;
            const idx = for (0..parent.children.len) |i| {
                const node = parent.children[i];
                if (self.widget.eql(node.widget))
                    break i;
            } else unreachable;

            // Return null if last child
            if (idx == parent.children.len - 1)
                return null
            else
                return parent.children[idx + 1];
        }

        fn prevSibling(self: Node) ?*Node {
            const parent = self.parent orelse return null;
            const idx = for (0..parent.children.len) |i| {
                const node = parent.children[i];
                if (self.widget.eql(node.widget))
                    break i;
            } else unreachable;

            // Return null if first child
            if (idx == 0)
                return null
            else
                return parent.children[idx - 1];
        }

        fn lastChild(self: Node) ?*Node {
            if (self.children.len > 0)
                return self.children[self.children.len - 1]
            else
                return null;
        }

        fn firstChild(self: Node) ?*Node {
            if (self.children.len > 0)
                return self.children[0]
            else
                return null;
        }

        /// returns the next logical node in the tree
        fn nextNode(self: *Node) *Node {
            // If we have a sibling, we return it's first descendant line
            if (self.nextSibling()) |sibling| {
                var node = sibling;
                while (node.firstChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we don't have a sibling, we return our parent
            if (self.parent) |parent| return parent;

            // If we don't have a parent, we are the root and we return or first descendant
            var node = self;
            while (node.firstChild()) |child| {
                node = child;
            }
            return node;
        }

        fn prevNode(self: *Node) *Node {
            // If we have children, we return the last child descendant
            if (self.children.len > 0) {
                var node = self;
                while (node.lastChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we have siblings, we return the last descendant line of the sibling
            if (self.prevSibling()) |sibling| {
                var node = sibling;
                while (node.lastChild()) |child| {
                    node = child;
                }
                return node;
            }

            // If we don't have a sibling, we return our parent
            if (self.parent) |parent| return parent;

            // If we don't have a parent, we are the root and we return our last descendant
            var node = self;
            while (node.lastChild()) |child| {
                node = child;
            }
            return node;
        }
    };

    fn init(self: *FocusHandler, allocator: Allocator, root: vxfw.Widget) !void {
        self.* = .{
            .root = .{
                .widget = root,
                .parent = null,
                .children = &.{},
            },
            .focused = &self.root,
            .focused_widget = root,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .path_to_focused = std.ArrayList(vxfw.Widget).init(allocator),
        };
        try self.path_to_focused.append(root);
    }

    fn deinit(self: *FocusHandler) void {
        self.path_to_focused.deinit();
        self.arena.deinit();
    }

    /// Update the focus list
    fn update(self: *FocusHandler, root: vxfw.Surface) Allocator.Error!void {
        _ = self.arena.reset(.retain_capacity);

        var list = std.ArrayList(*Node).init(self.arena.allocator());
        for (root.children) |child| {
            try self.findFocusableChildren(&self.root, &list, child.surface);
        }

        // Update children
        self.root.children = list.items;

        // Update path
        self.path_to_focused.clearAndFree();
        if (!self.root.widget.eql(root.widget)) {
            // Always make sure the root widget (the one we started with) is the first item, even if
            // it isn't focusable or in the path
            try self.path_to_focused.append(self.root.widget);
        }
        _ = try childHasFocus(root, &self.path_to_focused, self.focused.widget);

        // reverse path_to_focused so that it is root first
        std.mem.reverse(vxfw.Widget, self.path_to_focused.items);
    }

    /// Returns true if a child of surface is the focused widget
    fn childHasFocus(
        surface: vxfw.Surface,
        list: *std.ArrayList(vxfw.Widget),
        focused: vxfw.Widget,
    ) Allocator.Error!bool {
        // Check if we are the focused widget
        if (focused.eql(surface.widget)) {
            try list.append(surface.widget);
            return true;
        }
        for (surface.children) |child| {
            // Add child to list if it is the focused widget or one of it's own children is
            if (try childHasFocus(child.surface, list, focused)) {
                try list.append(surface.widget);
                return true;
            }
        }
        return false;
    }

    /// Walks the surface tree, adding all focusable nodes to list
    fn findFocusableChildren(
        self: *FocusHandler,
        parent: *Node,
        list: *std.ArrayList(*Node),
        surface: vxfw.Surface,
    ) Allocator.Error!void {
        if (self.root.widget.eql(surface.widget)) {
            // Never add the root_widget. We will always have this as the root
            for (surface.children) |child| {
                try self.findFocusableChildren(parent, list, child.surface);
            }
        } else if (surface.focusable) {
            // We are a focusable child of parent. Create a new node, and find our own focusable
            // children
            const node = try self.arena.allocator().create(Node);
            var child_list = std.ArrayList(*Node).init(self.arena.allocator());
            for (surface.children) |child| {
                try self.findFocusableChildren(node, &child_list, child.surface);
            }
            node.* = .{
                .widget = surface.widget,
                .parent = parent,
                .children = child_list.items,
            };
            if (self.focused_widget.eql(surface.widget)) {
                self.focused = node;
            }
            try list.append(node);
        } else {
            for (surface.children) |child| {
                try self.findFocusableChildren(parent, list, child.surface);
            }
        }
    }

    fn focusWidget(self: *FocusHandler, ctx: *vxfw.EventContext, widget: vxfw.Widget) anyerror!void {
        if (self.focused_widget.eql(widget)) return;

        ctx.phase = .at_target;
        try self.focused_widget.handleEvent(ctx, .focus_out);
        self.focused_widget = widget;
        try self.focused_widget.handleEvent(ctx, .focus_in);
    }

    fn focusNode(self: *FocusHandler, ctx: *vxfw.EventContext, node: *Node) anyerror!void {
        if (self.focused.widget.eql(node.widget)) return;

        try self.focused.widget.handleEvent(ctx, .focus_out);
        self.focused = node;
        try self.focused.widget.handleEvent(ctx, .focus_in);
    }

    /// Focuses the next focusable widget
    fn focusNext(self: *FocusHandler, ctx: *vxfw.EventContext) anyerror!void {
        return self.focusNode(ctx, self.focused.nextNode());
    }

    /// Focuses the previous focusable widget
    fn focusPrev(self: *FocusHandler, ctx: *vxfw.EventContext) anyerror!void {
        return self.focusNode(ctx, self.focused.prevNode());
    }

    fn handleEvent(self: *FocusHandler, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const path = self.path_to_focused.items;
        if (path.len == 0) return;

        const target_idx = path.len - 1;

        // Capturing phase
        ctx.phase = .capturing;
        for (path[0..target_idx]) |widget| {
            try widget.captureEvent(ctx, event);
            if (ctx.consume_event) return;
        }

        // Target phase
        ctx.phase = .at_target;
        const target = path[target_idx];
        try target.handleEvent(ctx, event);
        if (ctx.consume_event) return;

        // Bubbling phase
        ctx.phase = .bubbling;
        var iter = std.mem.reverseIterator(path[0..target_idx]);
        while (iter.next()) |widget| {
            try widget.handleEvent(ctx, event);
            if (ctx.consume_event) return;
        }
    }
};

const MouseHandler = struct {
    last_frame: vxfw.Surface,
    last_hit_list: []vxfw.HitResult,

    fn init(root: vxfw.Widget) MouseHandler {
        return .{
            .last_frame = .{
                .size = .{ .width = 0, .height = 0 },
                .widget = root,
                .buffer = &.{},
                .children = &.{},
            },
            .last_hit_list = &.{},
        };
    }

    fn deinit(self: MouseHandler, gpa: Allocator) void {
        gpa.free(self.last_hit_list);
    }

    fn handleMouse(self: *MouseHandler, app: *XevApp, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) anyerror!void {
        // For mouse events we store the last frame and use that for hit testing
        const last_frame = self.last_frame;

        var hits = std.ArrayList(vxfw.HitResult).init(app.gpa);
        defer hits.deinit();
        const sub: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = last_frame,
            .z_index = 0,
        };
        const mouse_point: vxfw.Point = .{
            .row = @intCast(mouse.row),
            .col = @intCast(mouse.col),
        };
        if (sub.containsPoint(mouse_point)) {
            try last_frame.hitTest(&hits, mouse_point);
        }

        // Handle mouse_enter and mouse_leave events
        {
            // We store the hit list from the last mouse event to determine mouse_enter and mouse_leave
            // events. If list a is the previous hit list, and list b is the current hit list:
            // - Widgets in a but not in b get a mouse_leave event
            // - Widgets in b but not in a get a mouse_enter event
            // - Widgets in both receive nothing
            const a = self.last_hit_list;
            const b = hits.items;

            // Find widgets in a but not b
            for (a) |a_item| {
                const a_widget = a_item.widget;
                for (b) |b_item| {
                    const b_widget = b_item.widget;
                    if (a_widget.eql(b_widget)) break;
                } else {
                    // a_item is not in b
                    try a_widget.handleEvent(ctx, .mouse_leave);
                    try app.handleCommands();
                }
            }

            // Widgets in b but not in a
            for (b) |b_item| {
                const b_widget = b_item.widget;
                for (a) |a_item| {
                    const a_widget = a_item.widget;
                    if (b_widget.eql(a_widget)) break;
                } else {
                    // b_item is not in a.
                    try b_widget.handleEvent(ctx, .mouse_enter);
                    try app.handleCommands();
                }
            }

            // Store a copy of this hit list for next frame
            app.gpa.free(self.last_hit_list);
            self.last_hit_list = try app.gpa.dupe(vxfw.HitResult, hits.items);
        }

        const target = hits.popOrNull() orelse return;

        // capturing phase
        ctx.phase = .capturing;
        for (hits.items) |item| {
            var m_local = mouse;
            m_local.col = item.local.col;
            m_local.row = item.local.row;
            try item.widget.captureEvent(ctx, .{ .mouse = m_local });
            try app.handleCommands();

            if (ctx.consume_event) return;
        }

        // target phase
        ctx.phase = .at_target;
        {
            var m_local = mouse;
            m_local.col = target.local.col;
            m_local.row = target.local.row;
            try target.widget.handleEvent(ctx, .{ .mouse = m_local });
            try app.handleCommands();

            if (ctx.consume_event) return;
        }

        // Bubbling phase
        ctx.phase = .bubbling;
        while (hits.popOrNull()) |item| {
            var m_local = mouse;
            m_local.col = item.local.col;
            m_local.row = item.local.row;
            try item.widget.handleEvent(ctx, .{ .mouse = m_local });
            try app.handleCommands();

            if (ctx.consume_event) return;
        }
    }

    /// sends .mouse_leave to all of the widgets from the last_hit_list
    fn mouseExit(self: *MouseHandler, app: *XevApp, ctx: *vxfw.EventContext) anyerror!void {
        for (self.last_hit_list) |item| {
            try item.widget.handleEvent(ctx, .mouse_leave);
            try app.handleCommands();
        }
    }
};

test "Tty" {
    const gpa = std.testing.allocator;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var app: XevApp = undefined;
    try app.init(gpa, &loop, undefined);
    defer app.deinit();
}
