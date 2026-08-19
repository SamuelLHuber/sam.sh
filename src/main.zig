const std = @import("std");
const assert = std.debug.assert;
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
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;

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
const max_update_body_size = 32 * 1024;
const admin_lock_path = "/tmp/sam-sh-send-update.lock";
var shared_io: Io = undefined;

const Config = struct {
    port: u16,
    base_url: []const u8,
    database_path: []const u8,
    smtp_host: []const u8,
    smtp_port: u16,
    smtp_username: []const u8,
    smtp_password: []const u8,
    smtp_from: []const u8,
    admin_username: []const u8,
    admin_password: []const u8,

    fn load(allocator: Allocator) !Config {
        return .{
            .port = try envU16("PORT", 8080),
            .base_url = try envOrDup(allocator, "BASE_URL", "http://localhost:8080"),
            .database_path = try envOrDup(allocator, "DATABASE_PATH", "./sam-sh.sqlite"),
            .smtp_host = try envOrDup(allocator, "SMTP_HOST", ""),
            .smtp_port = try envU16("SMTP_PORT", 587),
            .smtp_username = try envOrDup(allocator, "SMTP_USERNAME", ""),
            .smtp_password = try envOrDup(allocator, "SMTP_PASSWORD", ""),
            .smtp_from = try envOrDup(allocator, "SMTP_FROM", "Samuel <you@example.com>"),
            .admin_username = try envOrDup(allocator, "ADMIN_USERNAME", ""),
            .admin_password = try envOrDup(allocator, "ADMIN_PASSWORD", ""),
        };
    }
};

const App = struct {
    allocator: Allocator,
    config: Config,
    db: Database,
};

const Subscriber = struct {
    email: []const u8,
    unsubscribe_token: []const u8,

    fn deinit(self: Subscriber, allocator: Allocator) void {
        allocator.free(self.email);
        allocator.free(self.unsubscribe_token);
    }
};

const Update = struct {
    subject: []const u8,
    body: []const u8,
};

const SendResult = struct {
    sent_count: u32,
    failed_count: u32,
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

    fn subscriberList(self: Database, allocator: Allocator) ![]Subscriber {
        const sql = "SELECT email, unsubscribe_token FROM subscribers WHERE status='confirmed' ORDER BY id";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = sqlite3_finalize(stmt);

        var rows: std.ArrayList(Subscriber) = .empty;
        errdefer {
            for (rows.items) |subscriber| subscriber.deinit(allocator);
            rows.deinit(allocator);
        }

        while (true) {
            const step = sqlite3_step(stmt);
            if (step == SQLITE_DONE) break;
            if (step != SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .email = try columnTextDup(allocator, stmt, 0),
                .unsubscribe_token = try columnTextDup(allocator, stmt, 1),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    fn recordSentUpdate(self: Database, subject: []const u8, body: []const u8, now: i64, recipient_count: u32) !void {
        const sql = "INSERT INTO sent_updates (subject, body, sent_at, recipient_count) VALUES (?1, ?2, ?3, ?4)";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, subject);
        try bindText(stmt.?, 2, body);
        if (sqlite3_bind_int64(stmt.?, 3, now) != SQLITE_OK) return error.SqliteBindFailed;
        if (sqlite3_bind_int64(stmt.?, 4, recipient_count) != SQLITE_OK) return error.SqliteBindFailed;
        if (sqlite3_step(stmt) != SQLITE_DONE) return error.SqliteStepFailed;
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
    if (request.head.method == .GET and std.mem.eql(u8, path, "/admin")) return admin(arena, app, request);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/admin/send-update")) return adminSendUpdate(arena, app, request);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/subscribe")) return subscribe(arena, app, request);
    if (request.head.method == .GET and std.mem.startsWith(u8, path, "/unsubscribe/")) return unsubscribe(arena, app, request, path[13..]);
    if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) return request.respond("ok", .{});

    return request.respond("not found", .{ .status = .not_found });
}

fn index(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    _ = arena;
    _ = app;
    try request.respond(index_html, .{ .extra_headers = &html_headers });
}

fn css(request: *std.http.Server.Request) !void {
    try request.respond(@embedFile("styles.css"), .{ .extra_headers = &css_headers });
}

fn admin(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    _ = arena;
    if (!adminAuthorized(app, request)) return unauthorized(request);
    try request.respond(admin_html, .{ .extra_headers = &html_headers });
}

fn adminSendUpdate(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    if (!adminAuthorized(app, request)) return unauthorized(request);
    const lock = acquireAdminSendLock() catch |err| switch (err) {
        error.PathAlreadyExists => return adminResult(arena, request, "Busy", "An update is already being sent."),
        else => |e| return e,
    };
    defer releaseAdminSendLock(lock);

    const body = try readBodyLimit(arena, request, max_update_body_size);
    const subject_raw = formValue(body, "subject") orelse return adminResult(arena, request, "Not sent", "Missing subject.");
    const message_raw = formValue(body, "body") orelse return adminResult(arena, request, "Not sent", "Missing message.");
    const update = parseAdminUpdate(arena, subject_raw, message_raw) catch {
        return adminResult(arena, request, "Not sent", "Subject or message is invalid.");
    };

    const result = sendUpdate(arena, app.config, app.db, update.subject, update.body, .send) catch |err| switch (err) {
        error.SmtpNotConfigured => return adminResult(arena, request, "Not sent", "SMTP is not configured."),
        else => |e| return e,
    };
    const message = try std.fmt.allocPrint(arena, "Sent {d} email(s), {d} failed.", .{ result.sent_count, result.failed_count });
    if (result.failed_count == 0) {
        try adminResult(arena, request, "Sent", message);
    } else {
        try adminResult(arena, request, "Partially sent", message);
    }
}

fn adminResult(arena: Allocator, request: *std.http.Server.Request, title: []const u8, message: []const u8) !void {
    const title_html = try htmlEscape(arena, title);
    const message_html = try htmlEscape(arena, message);
    const body = try std.fmt.allocPrint(arena, admin_result_html, .{ title_html, message_html });
    try request.respond(body, .{ .extra_headers = &html_headers });
}

fn subscribe(arena: Allocator, app: *App, request: *std.http.Server.Request) !void {
    const body = try readBody(arena, request);
    const raw_email = formValue(body, "email") orelse return respondDatastarPatch(request, "#subscribe-result", subscribe_error_html);
    const email = normalizeEmail(arena, raw_email) catch {
        return respondDatastarPatch(request, "#subscribe-result", subscribe_error_html);
    };
    if (!validEmail(email)) {
        return respondDatastarPatch(request, "#subscribe-result", subscribe_error_html);
    }

    var token_bytes: [32]u8 = undefined;
    try randomBytes(&token_bytes);
    const token = try hexLower(arena, &token_bytes);
    _ = try app.db.subscribe(email, token, nowSeconds());

    const email_html = try htmlEscape(arena, email);
    const fragment = try std.fmt.allocPrint(arena, subscribe_success_html, .{email_html});
    try respondDatastarPatch(request, "#subscribe-result", fragment);
}

fn unsubscribe(arena: Allocator, app: *App, request: *std.http.Server.Request, token: []const u8) !void {
    const decoded = urlDecode(arena, token) catch "";
    const ok = try app.db.unsubscribe(decoded, nowSeconds());
    const body = try std.fmt.allocPrint(arena, unsubscribe_html, .{if (ok) "You are unsubscribed." else "This unsubscribe link is unknown or already used."});
    try request.respond(body, .{ .extra_headers = &html_headers });
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
    return readBodyLimit(arena, request, max_body_size);
}

fn readBodyLimit(arena: Allocator, request: *std.http.Server.Request, limit: usize) ![]u8 {
    assert(limit > 0);
    assert(limit <= max_update_body_size);
    request.head.expect = null;
    var buffer: [4096]u8 = undefined;
    var reader = request.readerExpectNone(&buffer);
    return reader.allocRemaining(arena, .limited(limit));
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
    if (email.len < 3) return false;
    if (email.len > 254) return false;

    var at_count: u8 = 0;
    for (email) |byte| {
        if (byte <= 0x20) return false;
        if (byte >= 0x7f) return false;
        if (byte == '@') at_count += 1;
    }
    if (at_count != 1) return false;

    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0) return false;
    if (at + 1 >= email.len) return false;
    return true;
}

fn urlDecode(arena: Allocator, input: []const u8) ![]u8 {
    assert(input.len <= max_body_size);

    var out: std.ArrayList(u8) = .empty;
    var byte_index: usize = 0;
    while (byte_index < input.len) {
        const byte = input[byte_index];
        if (byte == '+') {
            try out.append(arena, ' ');
            byte_index += 1;
        } else if (byte == '%') {
            if (byte_index + 2 >= input.len) return error.InvalidPercentEncoding;
            const high = try hexNibble(input[byte_index + 1]);
            const low = try hexNibble(input[byte_index + 2]);
            try out.append(arena, (high << 4) | low);
            byte_index += 3;
        } else {
            try out.append(arena, byte);
            byte_index += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn hexNibble(byte: u8) !u8 {
    if ('0' <= byte) {
        if (byte <= '9') return byte - '0';
    }
    if ('a' <= byte) {
        if (byte <= 'f') return byte - 'a' + 10;
    }
    if ('A' <= byte) {
        if (byte <= 'F') return byte - 'A' + 10;
    }
    return error.InvalidPercentEncoding;
}

fn htmlEscape(arena: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(arena, "&amp;"),
            '<' => try out.appendSlice(arena, "&lt;"),
            '>' => try out.appendSlice(arena, "&gt;"),
            '"' => try out.appendSlice(arena, "&quot;"),
            '\'' => try out.appendSlice(arena, "&#39;"),
            else => try out.append(arena, byte),
        }
    }
    return out.toOwnedSlice(arena);
}

fn bindText(stmt: *sqlite3_stmt, idx: c_int, text: []const u8) !void {
    assert(idx > 0);
    assert(text.len <= max_update_body_size);
    if (sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT) != SQLITE_OK) return error.SqliteBindFailed;
}

fn columnTextDup(allocator: Allocator, stmt: ?*sqlite3_stmt, column_index: c_int) ![]const u8 {
    assert(column_index >= 0);
    const pointer = sqlite3_column_text(stmt, column_index) orelse return error.SqliteStepFailed;
    const byte_count: usize = @intCast(sqlite3_column_bytes(stmt, column_index));
    assert(byte_count <= max_body_size);
    return allocator.dupe(u8, pointer[0..byte_count]);
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
    const file = try std.Io.Dir.cwd().readFileAlloc(shared_io, path, allocator, .limited(max_update_body_size));
    defer allocator.free(file);
    const update = try parseUpdateFile(file);
    const result = try sendUpdate(allocator, config, db, update.subject, update.body, .dry_run);
    std.debug.print("Dry run ok: would send {d} email(s), {d} would fail.\n", .{ result.sent_count, result.failed_count });
}

const SendMode = enum { dry_run, send };

fn sendUpdate(allocator: Allocator, config: Config, db: Database, subject: []const u8, body: []const u8, mode: SendMode) !SendResult {
    if (mode == .send) validateSmtpConfig(config) catch return error.SmtpNotConfigured;

    const subscribers = try db.subscriberList(allocator);
    defer {
        for (subscribers) |subscriber| subscriber.deinit(allocator);
        allocator.free(subscribers);
    }

    var result = SendResult{ .sent_count = 0, .failed_count = 0 };
    for (subscribers) |subscriber| {
        if (mode == .send) {
            sendOne(allocator, config, subscriber, subject, body) catch |err| {
                result.failed_count += 1;
                std.log.err("email send failed for subscriber: {}", .{err});
                continue;
            };
        }
        result.sent_count += 1;
    }

    if (mode == .send) try db.recordSentUpdate(subject, body, nowSeconds(), result.sent_count);
    return result;
}

fn sendOne(allocator: Allocator, config: Config, subscriber: Subscriber, subject: []const u8, body: []const u8) !void {
    const message = try renderEmail(allocator, config, subscriber, subject, body);
    defer allocator.free(message);

    const temp_path = try tempEmailPath(allocator);
    defer allocator.free(temp_path);
    try std.Io.Dir.cwd().writeFile(shared_io, .{
        .sub_path = temp_path,
        .data = message,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    defer std.Io.Dir.cwd().deleteFile(shared_io, temp_path) catch {};

    const port = try std.fmt.allocPrint(allocator, "{d}", .{config.smtp_port});
    defer allocator.free(port);
    const url = try std.fmt.allocPrint(allocator, "smtp://{s}:{s}", .{ config.smtp_host, port });
    defer allocator.free(url);
    const from = try mailAddress(allocator, config.smtp_from);
    defer allocator.free(from);
    const netrc_path = try tempNetrcPath(allocator);
    defer allocator.free(netrc_path);
    try writeNetrc(allocator, config, netrc_path);
    defer std.Io.Dir.cwd().deleteFile(shared_io, netrc_path) catch {};

    const argv = [_][]const u8{
        "curl",  "--silent",    "--show-error",   "--fail",        "--ssl-reqd",
        "--url", url,           "--netrc-file",   netrc_path,      "--mail-from",
        from,    "--mail-rcpt", subscriber.email, "--upload-file", temp_path,
    };
    const run = try std.process.run(allocator, shared_io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    if (!run.term.success()) return error.CurlSmtpFailed;
}

fn renderEmail(allocator: Allocator, config: Config, subscriber: Subscriber, subject: []const u8, body: []const u8) ![]const u8 {
    const unsubscribe_url = try std.fmt.allocPrint(allocator, "{s}/unsubscribe/{s}", .{ config.base_url, subscriber.unsubscribe_token });
    defer allocator.free(unsubscribe_url);
    const from = try headerLineValue(allocator, config.smtp_from);
    defer allocator.free(from);
    const safe_subject = try headerLineValue(allocator, subject);
    defer allocator.free(safe_subject);

    return std.fmt.allocPrint(allocator,
        \\From: {s}
        \\To: {s}
        \\Subject: {s}
        \\MIME-Version: 1.0
        \\Content-Type: text/plain; charset=UTF-8
        \\List-Unsubscribe: <{s}>
        \\
        \\{s}
        \\
        \\
        \\--
        \\Unsubscribe: {s}
        \\
    , .{ from, subscriber.email, safe_subject, unsubscribe_url, body, unsubscribe_url });
}

fn parseUpdateFile(file: []const u8) !Update {
    if (file.len == 0) return error.InvalidUpdate;
    if (file.len > max_update_body_size) return error.InvalidUpdate;
    var lines = std.mem.splitScalar(u8, file, '\n');
    const first = lines.next() orelse return error.InvalidUpdate;
    if (!std.mem.startsWith(u8, first, "Subject:")) return error.InvalidUpdate;
    const subject = std.mem.trim(u8, first[8..], " \t\r\n");
    if (!validSubject(subject)) return error.InvalidUpdate;
    const body_start = if (std.mem.indexOfScalar(u8, file, '\n')) |i| i + 1 else return error.InvalidUpdate;
    const body = std.mem.trim(u8, file[body_start..], "\r\n");
    if (!validMessageBody(body)) return error.InvalidUpdate;
    return .{ .subject = subject, .body = body };
}

fn parseAdminUpdate(arena: Allocator, subject_raw: []const u8, message_raw: []const u8) !Update {
    const subject_decoded = try urlDecode(arena, subject_raw);
    const message_decoded = try urlDecode(arena, message_raw);
    const subject = std.mem.trim(u8, subject_decoded, " \t\r\n");
    const body = std.mem.trim(u8, message_decoded, " \t\r\n");
    if (!validSubject(subject)) return error.InvalidUpdate;
    if (!validMessageBody(body)) return error.InvalidUpdate;
    return .{ .subject = subject, .body = body };
}

fn validateSmtpConfig(config: Config) !void {
    if (config.smtp_host.len == 0) return error.SmtpNotConfigured;
    if (config.smtp_username.len == 0) return error.SmtpNotConfigured;
    if (config.smtp_password.len == 0) return error.SmtpNotConfigured;
    if (config.smtp_from.len == 0) return error.SmtpNotConfigured;
    if (config.smtp_port == 0) return error.SmtpNotConfigured;
}

fn validSubject(subject: []const u8) bool {
    if (subject.len == 0) return false;
    if (subject.len > 120) return false;
    for (subject) |byte| {
        if (byte == '\r') return false;
        if (byte == '\n') return false;
        if (byte < 0x20) return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn validMessageBody(body: []const u8) bool {
    if (body.len == 0) return false;
    if (body.len > max_update_body_size) return false;
    for (body) |byte| {
        if (byte == 0) return false;
        if (byte == '\t') continue;
        if (byte == '\n') continue;
        if (byte == '\r') continue;
        if (byte < 0x20) return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn headerLineValue(allocator: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        if (byte == '\r') continue;
        if (byte == '\n') continue;
        try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

fn mailAddress(allocator: Allocator, from: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, from, '<')) |start| {
        if (std.mem.indexOfScalarPos(u8, from, start + 1, '>')) |end| {
            const email = std.mem.trim(u8, from[start + 1 .. end], " \t\r\n");
            if (!validEmail(email)) return error.InvalidEmail;
            return allocator.dupe(u8, email);
        }
    }
    const email = std.mem.trim(u8, from, " \t\r\n");
    if (!validEmail(email)) return error.InvalidEmail;
    return allocator.dupe(u8, email);
}

fn writeNetrc(allocator: Allocator, config: Config, path: []const u8) !void {
    if (!validNetrcToken(config.smtp_host)) return error.InvalidSmtpConfig;
    if (!validNetrcToken(config.smtp_username)) return error.InvalidSmtpConfig;
    if (!validNetrcToken(config.smtp_password)) return error.InvalidSmtpConfig;
    const body = try std.fmt.allocPrint(allocator, "machine {s} login {s} password {s}\n", .{
        config.smtp_host,
        config.smtp_username,
        config.smtp_password,
    });
    defer allocator.free(body);
    try std.Io.Dir.cwd().writeFile(shared_io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

fn validNetrcToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (token.len > 512) return false;
    for (token) |byte| {
        if (byte <= 0x20) return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn tempEmailPath(allocator: Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try randomBytes(&bytes);
    const hex = try hexLower(allocator, &bytes);
    defer allocator.free(hex);
    return std.fmt.allocPrint(allocator, "/tmp/sam-sh-mail-{s}.eml", .{hex});
}

fn tempNetrcPath(allocator: Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try randomBytes(&bytes);
    const hex = try hexLower(allocator, &bytes);
    defer allocator.free(hex);
    return std.fmt.allocPrint(allocator, "/tmp/sam-sh-netrc-{s}", .{hex});
}

fn acquireAdminSendLock() !std.Io.File {
    return std.Io.Dir.cwd().createFile(shared_io, admin_lock_path, .{
        .exclusive = true,
        .read = true,
        .permissions = .fromMode(0o600),
    });
}

fn releaseAdminSendLock(file: std.Io.File) void {
    file.close(shared_io);
    std.Io.Dir.cwd().deleteFile(shared_io, admin_lock_path) catch {};
}

fn adminAuthorized(app: *const App, request: *const std.http.Server.Request) bool {
    if (app.config.admin_username.len == 0) return false;
    if (app.config.admin_password.len == 0) return false;

    const authorization = requestHeader(request, "authorization") orelse return false;
    const expected = expectedBasicAuthorization(app.allocator, app.config.admin_username, app.config.admin_password) catch return false;
    defer app.allocator.free(expected);
    return constantTimeEqual(authorization, expected);
}

fn expectedBasicAuthorization(allocator: Allocator, username: []const u8, password: []const u8) ![]const u8 {
    assert(username.len > 0);
    assert(password.len > 0);
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(raw);
    const size = std.base64.standard.Encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, size);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    var diff: usize = a.len ^ b.len;
    const count = @min(a.len, b.len);
    for (a[0..count], b[0..count]) |a_byte, b_byte| diff |= @as(usize, a_byte ^ b_byte);
    return diff == 0;
}

fn requestHeader(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request.head_buffer, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn unauthorized(request: *std.http.Server.Request) !void {
    try request.respond("admin credentials required", .{
        .status = .unauthorized,
        .extra_headers = &unauthorized_headers,
    });
}

const html_headers = [_]std.http.Header{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }};
const css_headers = [_]std.http.Header{.{ .name = "content-type", .value = "text/css; charset=UTF-8" }};
const sse_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
    .{ .name = "cache-control", .value = "no-cache" },
};
const unauthorized_headers = [_]std.http.Header{.{ .name = "www-authenticate", .value = "Basic realm=\"sam.sh admin\", charset=\"UTF-8\"" }};

const index_html = @embedFile("templates/index.html");
const admin_html = @embedFile("templates/admin.html");
const admin_result_html = @embedFile("templates/admin-result.html");
const subscribe_success_html = @embedFile("templates/subscribe-success.html");
const subscribe_error_html = @embedFile("templates/subscribe-error.html");
const unsubscribe_html = @embedFile("templates/unsubscribe.html");

fn nowSeconds() i64 {
    return @intCast(@divTrunc(Io.Clock.now(.real, shared_io).nanoseconds, std.time.ns_per_s));
}

fn randomBytes(buffer: []u8) !void {
    assert(buffer.len > 0);
    assert(buffer.len <= 1024);
    try Io.randomSecure(shared_io, buffer);
}

fn hexLower(allocator: Allocator, bytes: []const u8) ![]u8 {
    assert(bytes.len > 0);
    assert(bytes.len <= 1024);

    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}
