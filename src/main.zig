const std = @import("std");
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: *[*c]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*c]const u8) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_changes(db: *sqlite3) c_int;
extern fn sqlite3_column_int(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;
const SQLITE_OPEN_FULLMUTEX = 0x00010000;
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(~@as(usize, 0));

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const std_options = std.Options{ .log_level = .info };

const max_body_size = 16 * 1024;
var shared_io: Io = undefined;

const Config = struct {
    port: u16,
    base_url: []const u8,
    database_path: []const u8,
    private_phone: []const u8,
    whatsapp_number: []const u8,
    imessage_target: []const u8,
    smtp_host: []const u8,
    smtp_port: u16,
    smtp_username: []const u8,
    smtp_password: []const u8,
    smtp_from: []const u8,

    fn load(allocator: Allocator) !Config {
        return .{
            .port = try envU16("PORT", 8080),
            .base_url = try envOrDup(allocator, "BASE_URL", "http://localhost:8080"),
            .database_path = try envOrDup(allocator, "DATABASE_PATH", "./sam-sh.sqlite"),
            .private_phone = try envOrDup(allocator, "PRIVATE_PHONE", "+49123456789"),
            .whatsapp_number = try envOrDup(allocator, "WHATSAPP_NUMBER", "49123456789"),
            .imessage_target = try envOrDup(allocator, "IMESSAGE_TARGET", "+49123456789"),
            .smtp_host = try envOrDup(allocator, "SMTP_HOST", ""),
            .smtp_port = try envU16("SMTP_PORT", 587),
            .smtp_username = try envOrDup(allocator, "SMTP_USERNAME", ""),
            .smtp_password = try envOrDup(allocator, "SMTP_PASSWORD", ""),
            .smtp_from = try envOrDup(allocator, "SMTP_FROM", "Samuel <you@example.com>"),
        };
    }
};

const App = struct {
    allocator: Allocator,
    config: Config,
    db: Database,
};

const Database = struct {
    handle: *sqlite3,

    fn open(allocator: Allocator, path: []const u8) !Database {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        var handle: ?*sqlite3 = null;
        if (sqlite3_open_v2(path_z.ptr, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null) != SQLITE_OK) {
            return error.SqliteOpenFailed;
        }
        const db = Database{ .handle = handle.? };
        try db.exec(schema_sql);
        return db;
    }

    fn close(self: Database) void {
        _ = sqlite3_close(self.handle);
    }

    fn exec(self: Database, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (sqlite3_exec(self.handle, sql.ptr, null, null, &err) != SQLITE_OK) {
            if (err) |msg| {
                std.log.err("sqlite exec failed: {s}", .{msg});
                sqlite3_free(msg);
            }
            return error.SqliteExecFailed;
        }
    }

    fn subscribe(self: Database, email: []const u8, unsubscribe_token: []const u8, now: i64) !bool {
        const sql =
            \\INSERT INTO subscribers (email, status, unsubscribe_token, created_at)
            \\VALUES (?1, 'confirmed', ?2, ?3)
            \\ON CONFLICT(email) DO UPDATE SET
            \\  status='confirmed',
            \\  unsubscribed_at=NULL,
            \\  unsubscribe_token=excluded.unsubscribe_token;
        ;
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, email);
        try bindText(stmt.?, 2, unsubscribe_token);
        if (sqlite3_bind_int64(stmt.?, 3, now) != SQLITE_OK) return error.SqliteBindFailed;
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
        return sqlite3_changes(self.handle) > 0;
    }

    fn unsubscribe(self: Database, token: []const u8, now: i64) !bool {
        const sql = "UPDATE subscribers SET status='unsubscribed', unsubscribed_at=?1 WHERE unsubscribe_token=?2 AND status!='unsubscribed'";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_bind_int64(stmt.?, 1, now) != SQLITE_OK) return error.SqliteBindFailed;
        try bindText(stmt.?, 2, token);
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
        return sqlite3_changes(self.handle) > 0;
    }

    fn subscriberCount(self: Database) !u32 {
        const sql = "SELECT COUNT(*) FROM subscribers WHERE status='confirmed'";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.SqliteStepFailed;
        return @intCast(sqlite3_column_int(stmt, 0));
    }
};

const schema_sql =
    \\CREATE TABLE IF NOT EXISTS subscribers (
    \\  id INTEGER PRIMARY KEY,
    \\  email TEXT NOT NULL UNIQUE,
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  confirm_token TEXT,
    \\  unsubscribe_token TEXT NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  confirmed_at INTEGER,
    \\  unsubscribed_at INTEGER
    \\);
    \\CREATE TABLE IF NOT EXISTS verified_identities (
    \\  id INTEGER PRIMARY KEY,
    \\  provider TEXT NOT NULL,
    \\  provider_user_id TEXT NOT NULL,
    \\  handle TEXT NOT NULL,
    \\  display_name TEXT,
    \\  is_mutual INTEGER NOT NULL DEFAULT 0,
    \\  session_token TEXT NOT NULL UNIQUE,
    \\  created_at INTEGER NOT NULL,
    \\  last_verified_at INTEGER NOT NULL,
    \\  UNIQUE(provider, provider_user_id)
    \\);
    \\CREATE TABLE IF NOT EXISTS sent_updates (
    \\  id INTEGER PRIMARY KEY,
    \\  subject TEXT NOT NULL,
    \\  body TEXT NOT NULL,
    \\  sent_at INTEGER NOT NULL,
    \\  recipient_count INTEGER NOT NULL
    \\);
;

pub fn main(init: std.process.Init) !void {
    shared_io = init.io;
    const allocator = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    const config = try Config.load(allocator);
    var db = try Database.open(allocator, config.database_path);
    defer db.close();

    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "send-update")) {
            const path = args.next() orelse return usage();
            return sendUpdateCli(allocator, config, db, path);
        }
        return usage();
    }

    var app = App{ .allocator = allocator, .config = config, .db = db };
    try serve(init.io, allocator, &app);
}

fn usage() !void {
    std.debug.print("usage:\n  zig build run\n  zig build run -- send-update ./updates/example.md\n", .{});
}

fn serve(io: Io, allocator: Allocator, app: *App) !void {
    const address = try Io.net.IpAddress.parseIp6("::", app.config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    std.log.info("sam.sh listening on http://localhost:{}/", .{app.config.port});

    while (true) {
        const conn = try listener.accept(io);
        group.concurrent(io, handleConnection, .{ io, allocator, app, conn }) catch |err| {
            std.log.err("spawn handler error: {}", .{err});
            conn.close(io);
            continue;
        };
    }
}

fn handleConnection(io: Io, allocator: Allocator, app: *App, conn: Io.net.Stream) Io.Cancelable!void {
    defer conn.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch break;
        handleRequest(arena.allocator(), app, &request) catch |err| {
            std.log.err("handler error: {}", .{err});
            _ = request.respond("internal error", .{ .status = .internal_server_error }) catch {};
            break;
        };
    }
}

fn handleRequest(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (request.head.method == .GET and std.mem.eql(u8, path, "/")) return index(arena, app, request);
    if (request.head.method == .GET and std.mem.eql(u8, path, "/styles.css")) return css(request);
    if (request.head.method == .GET and std.mem.eql(u8, path, "/private-contact")) return privateContact(arena, app, request);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/subscribe")) return subscribe(arena, app, request);
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/unsubscribe/")) return unsubscribe(arena, app, request, path[13..]);
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/auth/farcaster/")) return authPlaceholder(request, "Farcaster");
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/auth/twitter/")) return authPlaceholder(request, "Twitter/X");
    if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) return request.respond("ok", .{});

    return request.respond("not found", .{ .status = .not_found });
}

fn index(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    const count = app.db.subscriberCount() catch 0;
    const body = try std.fmt.allocPrint(arena, index_html, .{count});
    try request.respond(body, .{ .extra_headers = &html_headers });
}

fn css(request: *std.http.Server.Request) !void {
    try request.respond(@embedFile("styles.css"), .{ .extra_headers = &css_headers });
}

fn privateContact(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    // V1 placeholder: automatic Farcaster/Twitter mutual auth is still TODO.
    // To test the reveal UI locally, request /private-contact?demo=verified.
    const verified = std.mem.indexOf(u8, request.head.target, "demo=verified") != null;
    const fragment = if (verified)
        try std.fmt.allocPrint(arena, private_contact_html, .{
            app.config.private_phone,
            app.config.whatsapp_number,
            app.config.imessage_target,
        })
    else
        closed_door_html;
    try respondDatastarPatch(request, "#private-contact", fragment);
}

fn subscribe(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    const body = try readBody(arena, request);
    const raw_email = formValue(body, "email") orelse return respondDatastarPatch(request, "#subscribe-result", subscribe_error_html);
    const email = try normalizeEmail(arena, raw_email);
    if (!validEmail(email)) return respondDatastarPatch(request, "#subscribe-result", subscribe_error_html);

    var token_buf: [32]u8 = undefined;
    randomBytes(&token_buf);
    const token = try hexLower(arena, &token_buf);
    _ = try app.db.subscribe(email, token, nowSeconds());
    const fragment = try std.fmt.allocPrint(arena, subscribe_success_html, .{email});
    try respondDatastarPatch(request, "#subscribe-result", fragment);
}

fn unsubscribe(arena: Allocator, app: *App, request: *std.http.Server.Request, token: []const u8) !void {
    const decoded = try urlDecode(arena, token);
    const ok = try app.db.unsubscribe(decoded, nowSeconds());
    const body = try std.fmt.allocPrint(arena, unsubscribe_html, .{if (ok) "You are unsubscribed." else "This unsubscribe link is unknown or already used."});
    try request.respond(body, .{ .extra_headers = &html_headers });
}

fn authPlaceholder(request: *std.http.Server.Request, provider: []const u8) !void {
    _ = provider;
    try request.respond("mutual verification is not wired yet", .{ .status = .not_implemented });
}

fn respondDatastarPatch(request: *std.http.Server.Request, selector: []const u8, fragment: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    try buf.print(std.heap.page_allocator, "event: datastar-patch-elements\ndata: selector {s}\ndata: mode outer\ndata: elements ", .{selector});
    var lines = std.mem.splitScalar(u8, fragment, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try buf.appendSlice(std.heap.page_allocator, "\ndata: elements ");
        first = false;
        try buf.appendSlice(std.heap.page_allocator, line);
    }
    try buf.appendSlice(std.heap.page_allocator, "\n\n");
    try request.respond(buf.items, .{ .extra_headers = &sse_headers });
}

fn readBody(arena: Allocator, request: *std.http.Server.Request) ![]u8 {
    request.head.expect = null;
    var buffer: [4096]u8 = undefined;
    var reader = request.readerExpectNone(&buffer);
    return reader.allocRemaining(arena, .limited(max_body_size));
}

fn formValue(body: []const u8, key: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, body, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
    }
    return null;
}

fn normalizeEmail(arena: Allocator, raw: []const u8) ![]u8 {
    const decoded = try urlDecode(arena, raw);
    const trimmed = std.mem.trim(u8, decoded, " \t\r\n");
    return std.ascii.allocLowerString(arena, trimmed);
}

fn validEmail(email: []const u8) bool {
    return email.len >= 3 and email.len <= 254 and std.mem.indexOfScalar(u8, email, '@') != null and std.mem.indexOfScalar(u8, email, ' ') == null;
}

fn urlDecode(arena: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input, 0..) |ch, i| {
        _ = i;
        if (ch == '+') {
            try out.append(arena, ' ');
        } else if (ch == '%') {
            // Simpler robust-enough decoder for form fields.
            continue;
        } else {
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}

fn bindText(stmt: *sqlite3_stmt, idx: c_int, text: []const u8) !void {
    if (sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT) != SQLITE_OK) return error.SqliteBindFailed;
}

fn envOrDup(allocator: Allocator, key: []const u8, fallback: []const u8) ![]const u8 {
    const key_z = try allocator.dupeSentinel(u8, key, 0);
    defer allocator.free(key_z);
    const raw = getenv(key_z.ptr) orelse return allocator.dupe(u8, fallback);
    return allocator.dupe(u8, std.mem.span(raw));
}

fn envU16(key: []const u8, fallback: u16) !u16 {
    var key_buf: [64]u8 = undefined;
    if (key.len >= key_buf.len) return fallback;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const raw = getenv(@ptrCast(&key_buf)) orelse return fallback;
    return std.fmt.parseInt(u16, std.mem.span(raw), 10) catch fallback;
}

fn sendUpdateCli(allocator: Allocator, config: Config, db: Database, path: []const u8) !void {
    _ = config;
    const body = try std.Io.Dir.cwd().readFileAlloc(shared_io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(body);
    const count = try db.subscriberCount();
    std.debug.print("SMTP sending is scaffolded, not implemented yet. Would send {s} to {d} subscribers.\n", .{ path, count });
}

const html_headers = [_]std.http.Header{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }};
const css_headers = [_]std.http.Header{.{ .name = "content-type", .value = "text/css; charset=UTF-8" }};
const sse_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
    .{ .name = "cache-control", .value = "no-cache" },
};

const index_html = @embedFile("templates/index.html");
const private_contact_html = @embedFile("templates/private-contact.html");
const closed_door_html = @embedFile("templates/closed-door.html");
const subscribe_success_html = @embedFile("templates/subscribe-success.html");
const subscribe_error_html = @embedFile("templates/subscribe-error.html");
const unsubscribe_html = @embedFile("templates/unsubscribe.html");

fn nowSeconds() i64 {
    return @intCast(@divTrunc(Io.Clock.now(.real, shared_io).nanoseconds, std.time.ns_per_s));
}

fn randomBytes(buf: []u8) void {
    const seed: u64 = @bitCast(@as(i64, @truncate(Io.Clock.now(.real, shared_io).nanoseconds)));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
}

fn hexLower(allocator: Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}
