const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = std.c;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
pub const std_options: std.Options = .{ .logFn = log, .log_level = .debug };
var log_enabled = true;
var log_threshold: std.log.Level = .info;
fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!log_enabled or @backingInt(level) > @backingInt(log_threshold)) return;
    const io = std.Options.debug_io;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var lock_buffer: [64]u8 = undefined;
    _ = std.debug.lockStderr(&lock_buffer);
    defer std.debug.unlockStderr();
    var buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const writer = &stdout.interface;
    writer.print("{s}: ", .{level.asText()}) catch return;
    if (scope != .default) writer.print("({t}) ", .{scope}) catch return;
    writer.print(format ++ "\n", args) catch return;
    writer.flush() catch {};
}
const HELP = "help:command, utility:logout, utility:lock, utility:mailbox, system:status";
const LOGIN = "https://reg.usps.com/entreg/LoginAction_input?app=Phoenix&appURL=https://www.usps.com/";
const DASHBOARD = "https://informeddelivery.usps.com/box/pages/secure/DashboardAction_input.action?restart=1";
const LIMIT = 100 * 1024;
const Reply = struct {
    type: []const u8,
    message: []const u8,
    status: bool,
    fn invalid() Reply {
        return .{ .type = "Unknown", .message = "Invalid command message", .status = false };
    }
};
const Message = struct { command: []const u8, modifier: []const u8 };
const State = struct {
    io: Io,
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    mutex: Io.Mutex = .init,
    cache: ?Reply = null,
    day: i64 = -1,
    retry: i64 = 0,
    log_requests: bool,
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n\t");
}
fn json(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
fn decode(a: Allocator, value: []const u8) ![]const u8 {
    const out = try a.alloc(u8, value.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        out[n] = switch (value[i]) {
            '+' => ' ',
            '%' => blk: {
                if (i + 2 >= value.len) return error.InvalidForm;
                const v = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.InvalidForm;
                i += 2;
                break :blk v;
            },
            else => value[i],
        };
        n += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..n])) return error.InvalidForm;
    return out[0..n];
}
fn parseMessage(a: Allocator, content_type: []const u8, body: []const u8) !Message {
    var types = std.mem.splitScalar(u8, content_type, ';');
    const typ = trim(types.first());
    if (eq(typ, "application/json")) {
        const parsed = try std.json.parseFromSlice(Message, a, body, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        return .{ .command = try a.dupe(u8, parsed.value.command), .modifier = try a.dupe(u8, parsed.value.modifier) };
    }
    if (!eq(typ, "application/x-www-form-urlencoded")) return error.InvalidContentType;
    var command: ?[]const u8 = null;
    var modifier: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const split = std.mem.findScalar(u8, field, '=') orelse field.len;
        const key = try decode(a, field[0..split]);
        const value = try decode(a, if (split < field.len) field[split + 1 ..] else "");
        if (eq(key, "command") and command == null) command = value else if (eq(key, "modifier") and modifier == null) modifier = value else return error.InvalidForm;
    }
    return .{ .command = command orelse return error.InvalidForm, .modifier = modifier orelse return error.InvalidForm };
}
fn timer(io: Io, seconds: i64) void {
    Io.sleep(io, .fromSeconds(seconds), .awake) catch {};
}
fn timed(comptime T: type, io: Io, seconds: i64, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) anyerror!T {
    const Result = union(enum) { result: anyerror!T, timeout: void };
    var buffer: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.result, func, args);
    try select.concurrent(.timeout, timer, .{ io, seconds });
    return switch (try select.await()) {
        .result => |r| r,
        .timeout => error.Timeout,
    };
}
fn runProcess(a: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8) anyerror!std.process.RunResult {
    return std.process.run(a, io, .{ .argv = argv, .environ_map = env, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
}
fn execute(a: Allocator, state: *State, kind: []const u8, argv: []const []const u8) Reply {
    const result = timed(std.process.RunResult, state.io, 10, runProcess, .{ a, state.io, state.env, argv }) catch |err| return .{ .type = kind, .message = if (err == error.Timeout) "Command timed out" else @errorName(err), .status = false };
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .type = kind, .message = if (!success) std.fmt.allocPrint(a, "Command failed ({any}): {s}", .{ result.term, trim(result.stderr) }) catch "Command failed" else if (result.stderr.len > 0) result.stderr else trim(result.stdout), .status = success and result.stderr.len == 0 };
}
fn parseMailbox(a: Allocator, items: []const std.json.Value) !Reply {
    for (items) |item| {
        if (item != .string or !std.mem.startsWith(u8, trim(item.string), "Today")) continue;
        var parts = std.mem.splitScalar(u8, item.string, '(');
        _ = parts.first();
        while (parts.next()) |part| {
            const end = std.mem.findScalar(u8, part, ')') orelse continue;
            if (end == 0) continue;
            var digits = true;
            for (part[0..end]) |ch| {
                if (!std.ascii.isDigit(ch)) digits = false;
            }
            if (!digits) continue;
            const count = std.fmt.parseInt(u64, part[0..end], 10) catch continue;
            return .{ .type = "mailbox", .message = switch (count) {
                0 => "No Mails",
                1 => "You have 1 mail",
                else => try std.fmt.allocPrint(a, "You have {d} mails", .{count}),
            }, .status = true };
        }
    }
    return .{ .type = "mailbox", .message = "Nothing.", .status = false };
}
const Driver = struct {
    a: Allocator,
    io: Io,
    client: *std.http.Client,
    base: []const u8,
    session: []const u8 = "",
    fn call(d: *Driver, method: std.http.Method, path: []const u8, payload: ?[]const u8) anyerror!std.json.Value {
        const url = try std.fmt.allocPrint(d.a, "{s}{s}", .{ d.base, path });
        // Fixed response limit also bounds untrusted driver allocations.
        const buf = try d.client.allocator.alloc(u8, 1024 * 1024);
        defer d.client.allocator.free(buf);
        var writer: Io.Writer = .fixed(buf);
        const response = try d.client.fetch(.{ .location = .{ .url = url }, .method = method, .payload = payload, .response_writer = &writer, .headers = .{ .content_type = .{ .override = "application/json" } }, .redirect_behavior = .unhandled });
        if (@backingInt(response.status) < 200 or @backingInt(response.status) >= 300) return error.WebDriverFailed;
        const parsed = try std.json.parseFromSlice(std.json.Value, d.a, writer.buffered(), .{ .allocate = .alloc_always });
        if (parsed.value != .object) return error.InvalidWebDriverResponse;
        const value = parsed.value.object.get("value") orelse return error.InvalidWebDriverResponse;
        if (value == .object and value.object.contains("error")) return error.WebDriverFailed;
        return value;
    }
    fn command(d: *Driver, method: std.http.Method, suffix: []const u8, payload: ?[]const u8) anyerror!std.json.Value {
        return d.call(method, try std.fmt.allocPrint(d.a, "/session/{s}{s}", .{ d.session, suffix }), payload);
    }
    fn navigate(d: *Driver, url: []const u8) !void {
        _ = try d.command(.POST, "/url", try json(d.a, .{ .url = url }));
    }
    fn element(d: *Driver, selector: []const u8, wait: bool) ![]const u8 {
        while (true) {
            const value = d.command(.POST, "/element", try json(d.a, .{ .using = "css selector", .value = selector })) catch |err| {
                if (!wait or err != error.WebDriverFailed) return err;
                try Io.sleep(d.io, .fromMilliseconds(200), .awake);
                continue;
            };
            if (value != .object) return error.InvalidElement;
            const id = value.object.get("element-6066-11e4-a52e-4f735466cecf") orelse return error.InvalidElement;
            if (id != .string) return error.InvalidElement;
            return id.string;
        }
    }
    fn keys(d: *Driver, id: []const u8, text: []const u8) !void {
        _ = try d.command(.POST, try std.fmt.allocPrint(d.a, "/element/{s}/value", .{id}), try json(d.a, .{ .text = text }));
    }
};
fn connect(d: *Driver, browser: ?[]const u8) anyerror!void {
    // Omit binary entirely when ChromeDriver should select the browser.
    const payload = if (browser) |path| try json(d.a, .{ .capabilities = .{ .alwaysMatch = .{ .@"goog:chromeOptions" = .{ .args = [_][]const u8{"--headless=new"}, .binary = path } } } }) else try json(d.a, .{ .capabilities = .{ .alwaysMatch = .{ .@"goog:chromeOptions" = .{ .args = [_][]const u8{"--headless=new"} } } } });
    const value = try d.call(.POST, "/session", payload);
    if (value != .object) return error.InvalidSession;
    const session = value.object.get("sessionId") orelse return error.InvalidSession;
    if (session != .string) return error.InvalidSession;
    d.session = session.string;
}
fn scrape(d: *Driver, user: []const u8, password: []const u8) anyerror!Reply {
    try d.navigate(LOGIN);
    try d.keys(try d.element("#username", true), user);
    try d.keys(try d.element("#password", false), password);
    _ = try d.command(.POST, try std.fmt.allocPrint(d.a, "/element/{s}/click", .{try d.element("#btn-submit", false)}), "{}");
    while (true) {
        const url = try d.command(.GET, "/url", null);
        if (url != .string) return error.InvalidUrl;
        const uri = try std.Uri.parse(url.string);
        if (uri.host == null or !eq(uri.host.?.percent_encoded, "reg.usps.com")) break;
        try Io.sleep(d.io, .fromMilliseconds(200), .awake);
    }
    try d.navigate(DASHBOARD);
    _ = try d.element("#cp_week li", true);
    const value = try d.command(.POST, "/execute/sync", try json(d.a, .{ .script = "return Array.from(document.querySelectorAll('#cp_week li'), e => e.textContent.trim());", .args = [_]u8{} }));
    if (value != .array) return .{ .type = "mailbox", .message = "Nothing.", .status = false };
    return parseMailbox(d.a, value.array.items);
}
fn closeSession(d: *Driver) anyerror!void {
    _ = try d.command(.DELETE, "", null);
}
fn fetchMailbox(a: Allocator, state: *State, user: []const u8, password: []const u8) !Reply {
    var client: std.http.Client = .{ .allocator = state.gpa, .io = state.io };
    defer client.deinit();
    var driver: Driver = .{ .a = a, .io = state.io, .client = &client, .base = std.mem.trimEnd(u8, state.env.get("WEBDRIVER_URL") orelse "http://127.0.0.1:9515", "/") };
    defer if (driver.session.len > 0) {
        const protection = state.io.swapCancelProtection(.blocked);
        defer _ = state.io.swapCancelProtection(protection);
        timed(void, state.io, 10, closeSession, .{&driver}) catch {};
    };
    try timed(void, state.io, 20, connect, .{ &driver, state.env.get("BROWSER_PATH") });
    return timed(Reply, state.io, 90, scrape, .{ &driver, user, password });
}
fn mailbox(a: Allocator, state: *State) !Reply {
    try state.mutex.lock(state.io);
    defer state.mutex.unlock(state.io);
    const day = @divFloor(Io.Timestamp.now(state.io, .real).toSeconds(), 86400);
    const now = Io.Timestamp.now(state.io, .awake).toSeconds();
    if (state.cache) |cached| {
        if (state.day == day and (cached.status or now < state.retry)) return .{ .type = cached.type, .message = try a.dupe(u8, cached.message), .status = cached.status };
    }
    const user = state.env.get("USPS_USR") orelse "";
    const password = state.env.get("USPS_PW") orelse "";
    const reply: Reply = if (user.len == 0 or password.len == 0) .{ .type = "mailbox", .message = "Something is not right", .status = false } else fetchMailbox(a, state, user, password) catch |err| blk: {
        if (err == error.Canceled) return err;
        // Error names never include driver response bodies or credentials.
        std.log.warn("USPS fetch failed: {s}", .{@errorName(err)});
        break :blk .{ .type = "mailbox", .message = "Error while fetching data from USPS", .status = false };
    };
    const owned = try state.gpa.dupe(u8, reply.message);
    if (state.cache) |old| state.gpa.free(old.message);
    state.cache = .{ .type = reply.type, .message = owned, .status = reply.status };
    state.day = day;
    state.retry = Io.Timestamp.now(state.io, .awake).toSeconds() + 30;
    return reply;
}
fn dispatch(a: Allocator, state: *State, message: Message) !Reply {
    if (eq(message.command, "help") and eq(message.modifier, "command")) return .{ .type = "help", .message = HELP, .status = true };
    if (eq(message.command, "system") and eq(message.modifier, "status")) return execute(a, state, "uptime", &.{"uptime"});
    if (eq(message.command, "utility")) {
        if (eq(message.modifier, "logout") or eq(message.modifier, "lock")) return execute(a, state, "shutdown /l", &.{ "shutdown", "/l" });
        if (eq(message.modifier, "mailbox")) return mailbox(a, state);
    }
    return Reply.invalid();
}
fn handle(state: *State, request: *std.http.Server.Request) !std.http.Status {
    var arena = std.heap.ArenaAllocator.init(state.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = std.mem.sliceTo(request.head.target, '?');
    if (!eq(path, "/utilities_local")) {
        try request.respond("", .{ .status = .not_found });
        return .not_found;
    }
    if (request.head.method != .POST) {
        try request.respond("", .{ .status = .method_not_allowed, .extra_headers = &.{.{ .name = "allow", .value = "POST" }} });
        return .method_not_allowed;
    }
    if ((request.head.content_length orelse 0) > LIMIT) {
        try request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        return .payload_too_large;
    }
    // Header slices refer to the input buffer, which body reads may overwrite.
    const content_type = try a.dupe(u8, request.head.content_type orelse "");
    const reader = try request.readerExpectContinue(&.{});
    const body = reader.allocRemaining(a, .limited(LIMIT)) catch {
        try request.respond("", .{ .status = .payload_too_large, .keep_alive = false });
        return .payload_too_large;
    };
    const message = parseMessage(a, content_type, body) catch {
        try request.respond(try json(a, Reply.invalid()), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return .ok;
    };
    const reply = try dispatch(a, state, message);
    try request.respond(try json(a, reply), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    return .ok;
}
fn connection(state: *State, stream: Io.net.Stream) void {
    defer stream.close(state.io);
    var input: [16384]u8 = undefined;
    var output: [8192]u8 = undefined;
    var reader = stream.reader(state.io, &input);
    var writer = stream.writer(state.io, &output);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        const started = Io.Timestamp.now(state.io, .awake);
        // Copy before responding: the HTTP reader can reuse the header buffer.
        var path_buffer: [16384]u8 = undefined;
        const path = std.mem.sliceTo(request.head.target, '?');
        @memcpy(path_buffer[0..path.len], path);
        const method = request.head.method;
        const status = handle(state, &request) catch return;
        if (state.log_requests) std.log.info("timestamp={d} method={s} path={f} status={d} duration_ms={d}", .{ Io.Timestamp.now(state.io, .real).toSeconds(), @tagName(method), std.json.fmt(path_buffer[0..path.len], .{}), @backingInt(status), started.untilNow(state.io, .awake).toMilliseconds() });
        if (server.reader.state == .closing) return;
    }
}
fn dotenv(init: std.process.Init) !void {
    const data = Io.Dir.cwd().readFileAlloc(init.io, ".env", init.gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer init.gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var text = trim(line);
        if (text.len == 0 or text[0] == '#') continue;
        if (std.mem.startsWith(u8, text, "export ")) text = trim(text[7..]);
        const split = std.mem.findScalar(u8, text, '=') orelse continue;
        const key = trim(text[0..split]);
        if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
        var value = trim(text[split + 1 ..]);
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
        if (init.environ_map.get(key) == null) try init.environ_map.put(key, value);
    }
}
// A self-pipe keeps the signal handler limited to async-signal-safe operations.
var signal_pipe: c_int = -1;
fn interrupted(_: c_int) callconv(.c) void {
    const byte = [_]u8{1};
    _ = c.write(signal_pipe, &byte, 1);
}
fn waitSignal(io: Io, file: Io.File) void {
    var byte: [1]u8 = undefined;
    var reader = file.reader(io, &byte);
    _ = reader.interface.takeByte() catch {};
}
fn acceptLoop(state: *State, server: *Io.net.Server, group: *Io.Group) anyerror!void {
    while (true) {
        const stream = try server.accept(state.io);
        group.concurrent(state.io, connection, .{ state, stream }) catch |err| {
            stream.close(state.io);
            return err;
        };
    }
}
pub fn main(init: std.process.Init) !void {
    try dotenv(init);
    var state: State = .{ .io = init.io, .gpa = init.gpa, .env = init.environ_map, .log_requests = true };
    const logging = init.environ_map.get("LOG_LEVEL") orelse init.environ_map.get("RUST_LOG") orelse "info";
    var directives = std.mem.splitScalar(u8, logging, ',');
    const default_level = directives.first();
    log_enabled = !eq(default_level, "off");
    log_threshold = if (eq(default_level, "error")) .err else if (eq(default_level, "warn")) .warn else if (eq(default_level, "debug") or eq(default_level, "trace")) .debug else .info;
    state.log_requests = !eq(logging, "off") and !eq(logging, "error") and !eq(logging, "warn") and std.mem.find(u8, logging, "notesongo_api::requests=off") == null;
    defer if (state.cache) |cached| init.gpa.free(cached.message);
    const address = try Io.net.IpAddress.parseLiteral(init.environ_map.get("BIND_ADDR") orelse "0.0.0.0:8081");
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    var pipes: [2]c_int = undefined;
    if (c.pipe(&pipes) != 0) return error.SignalPipeFailed;
    defer {
        _ = c.close(pipes[0]);
        _ = c.close(pipes[1]);
    }
    signal_pipe = pipes[1];
    _ = signal(@backingInt(c.SIG.INT), interrupted);
    _ = signal(@backingInt(c.SIG.TERM), interrupted);
    std.log.info("Listening on {f}", .{server.socket.address});
    var group: Io.Group = .init;
    defer group.cancel(init.io);
    const Result = union(enum) { server: anyerror!void, signal: void };
    var buffer: [2]Result = undefined;
    var select = Io.Select(Result).init(init.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.server, acceptLoop, .{ &state, &server, &group });
    try select.concurrent(.signal, waitSignal, .{ init.io, Io.File{ .handle = pipes[0], .flags = .{ .nonblocking = false } } });
    switch (try select.await()) {
        .server => |result| try result,
        .signal => {},
    }
}
test "strict JSON and form messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try parseMessage(a, "application/json; charset=utf-8", "{\"command\":\"help\",\"modifier\":\"command\"}");
    try std.testing.expectEqualStrings("help", good.command);
    const form = try parseMessage(a, "application/x-www-form-urlencoded", "command=h%65lp&modifier=command");
    try std.testing.expectEqualStrings("help", form.command);
    for ([_][]const u8{ "{}", "null", "[]", "{", "{\"command\":\"help\",\"modifier\":1}", "{\"command\":\"help\",\"modifier\":\"command\",\"extra\":1}", "{\"command\":\"help\",\"command\":\"help\",\"modifier\":\"command\"}" }) |body| {
        if (parseMessage(a, "application/json", body)) |_| return error.AcceptedInvalidMessage else |_| {}
    }
    for ([_][]const u8{ "command=help", "command=help&modifier=command&extra=1", "command=help&command=help&modifier=command", "command=%ZZ&modifier=command" }) |body| {
        if (parseMessage(a, "application/x-www-form-urlencoded", body)) |_| return error.AcceptedInvalidForm else |_| {}
    }
}
test "mailbox counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = [_][]const u8{ "Today Mail(0)", "Today Mail(1)", "Today Mail(42)", "Yesterday Mail(2)", "Today Mail(x)" };
    const expected = [_][]const u8{ "No Mails", "You have 1 mail", "You have 42 mails", "Nothing.", "Nothing." };
    for (inputs, expected) |input, output| {
        const reply = try parseMailbox(a, &.{.{ .string = input }});
        try std.testing.expectEqualStrings(output, reply.message);
    }
}

test "process output, failures and deadline cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var state: State = .{ .io = std.testing.io, .gpa = std.testing.allocator, .env = &env, .log_requests = false };
    const success = execute(a, &state, "test", &.{ "/bin/echo", "hello" });
    try std.testing.expect(success.status);
    try std.testing.expectEqualStrings("hello", success.message);
    try std.testing.expect(!execute(a, &state, "test", &.{"/usr/bin/false"}).status);
    try std.testing.expect(!execute(a, &state, "test", &.{"/nonexistent/notesongo-api"}).status);
    try std.testing.expectError(error.Timeout, timed(std.process.RunResult, state.io, 1, runProcess, .{ a, state.io, &env, &.{ "/bin/sleep", "30" } }));
}

test "mailbox cache expires by UTC day and failed retry deadline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var state: State = .{ .io = std.testing.io, .gpa = std.testing.allocator, .env = &env, .log_requests = false };
    defer if (state.cache) |cached| state.gpa.free(cached.message);
    state.day = @divFloor(Io.Timestamp.now(state.io, .real).toSeconds(), 86400);
    state.cache = .{ .type = "mailbox", .message = try state.gpa.dupe(u8, "You have 2 mails"), .status = true };
    try std.testing.expectEqualStrings("You have 2 mails", (try mailbox(a, &state)).message);
    state.cache.?.status = false;
    state.retry = Io.Timestamp.now(state.io, .awake).toSeconds() + 30;
    try std.testing.expectEqualStrings("You have 2 mails", (try mailbox(a, &state)).message);
    state.retry = 0;
    try std.testing.expectEqualStrings("Something is not right", (try mailbox(a, &state)).message);
    state.cache.?.status = true;
    state.day -= 1;
    try std.testing.expect(!(try mailbox(a, &state)).status);
}
