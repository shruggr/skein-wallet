//! The skein calls as the wallet program sees them (the preview1 `skein`
//! imports, skein docs/VM.md), over the chain library's dag-cbor values: the
//! input, the store as the library's `Store`, heads, `on` and `events`
//! (skein 0.5.2 / 0.5.0), and keep-and-print of a result record. Taken from
//! skein-chain 0.10.0's src/vm.zig, the parts the wallet uses (no emit: the
//! wallet emits nothing). wasm32-wasi only.
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;

pub const sk = struct {
    pub extern "skein" fn input(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn get(cid: [*]const u8, cid_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn put(data: [*]const u8, len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn putblock(cid: [*]const u8, cid_len: u32, data: [*]const u8, len: u32) i32;
    pub extern "skein" fn keep(cid: [*]const u8, cid_len: u32) i32;
    pub extern "skein" fn head(name: [*]const u8, name_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn advance(name: [*]const u8, name_len: u32, tree: [*]const u8, tree_len: u32) i32;
    pub extern "skein" fn take(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn @"error"(out: [*]u8, cap: u32) i32;
    pub extern "skein" fn edges(to: [*]const u8, to_len: u32, rel: [*]const u8, rel_len: u32, out: [*]u8, cap: u32) i32;
    pub extern "skein" fn on(name: [*]const u8, name_len: u32, func: [*]const u8, func_len: u32) i32;
    pub extern "skein" fn events(q: [*]const u8, len: u32, out: [*]u8, cap: u32) i32;
};

var last_error: [1024]u8 = undefined;
var last_error_len: usize = 0;

pub fn failed() error{ImportFailed} {
    const n = sk.@"error"(&last_error, last_error.len);
    last_error_len = if (n < 0) 0 else @min(@as(usize, @intCast(n)), last_error.len);
    return error.ImportFailed;
}

pub fn lastError() []const u8 {
    return last_error[0..last_error_len];
}

/// Run an import that writes (out, cap), taking the held result when it did not fit.
pub fn result(arena: std.mem.Allocator, import: anytype, args: anytype) ![]u8 {
    var buf = try arena.alloc(u8, 4096);
    const n = @call(.auto, import, args ++ .{ buf.ptr, @as(u32, @intCast(buf.len)) });
    if (n < 0) return failed();
    const len: usize = @intCast(n);
    if (len <= buf.len) return buf[0..len];
    buf = try arena.alloc(u8, len);
    if (sk.take(buf.ptr, @intCast(len)) != n) return failed();
    return buf;
}

fn getImpl(_: *anyopaque, arena: std.mem.Allocator, cid: []const u8) anyerror![]const u8 {
    return result(arena, sk.get, .{ cid.ptr, @as(u32, @intCast(cid.len)) });
}
fn putImpl(_: *anyopaque, arena: std.mem.Allocator, bytes: []const u8) anyerror![]const u8 {
    return result(arena, sk.put, .{ bytes.ptr, @as(u32, @intCast(bytes.len)) });
}
fn putBlockImpl(_: *anyopaque, cid: []const u8, bytes: []const u8) anyerror!void {
    if (sk.putblock(cid.ptr, @intCast(cid.len), bytes.ptr, @intCast(bytes.len)) < 0) return failed();
}
fn keepImpl(_: *anyopaque, cid: []const u8) anyerror!void {
    if (sk.keep(cid.ptr, @intCast(cid.len)) < 0) return failed();
}
fn edgesImpl(_: *anyopaque, arena: std.mem.Allocator, to: []const u8, rel: ?[]const u8) anyerror![]const c.store.Edge {
    const r = rel orelse "";
    return c.store.decodeEdges(arena, try result(arena, sk.edges, .{ to.ptr, @as(u32, @intCast(to.len)), r.ptr, @as(u32, @intCast(r.len)) }));
}
var dummy: u8 = 0;

/// The record store through the `skein` imports: the bitcoin blocks held are kept, so their links
/// are the kernel's edges (#42: a transaction's inputs, `spends`).
pub fn store() c.store.Store {
    return .{ .ptr = &dummy, .getFn = getImpl, .putFn = putImpl, .putBlockFn = putBlockImpl, .keepFn = keepImpl, .edgesFn = edgesImpl };
}

/// The step's (or call's) input record.
pub fn input(a: std.mem.Allocator) !Value {
    return cbor.decode(a, try result(a, sk.input, .{}));
}

/// The record a head names, or null.
pub fn head(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const r = try result(a, sk.head, .{ name.ptr, @as(u32, @intCast(name.len)) });
    return if (r.len > 0) r else null;
}

pub fn advance(name: []const u8, cid: []const u8) !void {
    if (sk.advance(name.ptr, @intCast(name.len), cid.ptr, @intCast(cid.len)) < 0) return failed();
}

pub fn keep(cid: []const u8) !void {
    if (sk.keep(cid.ptr, @intCast(cid.len)) < 0) return failed();
}





/// Subscribe this app's `func` (a function of its program) to the facts named `name` (skein 0.5.2):
/// kept when the step ends without error; each fact under the name steps it, also one this same
/// step emits.
pub fn on(name: []const u8, func: []const u8) !void {
    if (sk.on(name.ptr, @intCast(name.len), func.ptr, @intCast(func.len)) < 0) return failed();
}

/// The latest fact under `name` exactly (skein 0.5.0's event index, `latest`): its record, or null.
/// The index as it stands before this step's update (a step does not see its own emits).
pub fn latestEvent(a: std.mem.Allocator, name: []const u8) !?Value {
    const q = try cbor.encode(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "name", .value = .{ .text = name } },
        .{ .key = "latest", .value = .{ .boolean = true } },
    }) });
    const rows = try cbor.decode(a, try result(a, sk.events, .{ q.ptr, @as(u32, @intCast(q.len)) }));
    if (rows != .array or rows.array.len == 0) return null;
    return rows.array[rows.array.len - 1].get("record");
}

/// A refusal with its own message: the step (or call) ends with it on stderr.
pub fn refuse(msg: []const u8) error{Refused} {
    const n = @min(msg.len, last_error.len);
    @memcpy(last_error[0..n], msg[0..n]);
    last_error_len = n;
    return error.Refused;
}



pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The answer of a call: dag-cbor on stdout.
pub fn answer(a: std.mem.Allocator, v: Value) !void {
    try std.Io.File.stdout().writeStreamingAll(io(), try cbor.encode(a, v));
}

pub fn hexAlloc(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const out = try a.alloc(u8, b.len * 2);
    const digits = "0123456789abcdef";
    for (b, 0..) |x, i| {
        out[2 * i] = digits[x >> 4];
        out[2 * i + 1] = digits[x & 15];
    }
    return out;
}

/// Put a result record, keep it in the thread, and print its CID (hex) on stdout.
pub fn finish(a: std.mem.Allocator, rec: Value) ![]const u8 {
    const cid = try store().putValue(a, rec);
    try keep(cid);
    try std.Io.File.stdout().writeStreamingAll(io(), try std.mem.concat(a, u8, &.{ try hexAlloc(a, cid), "\n" }));
    return cid;
}

/// A program's main around `run`: an error ends the step with exit 1 and a line on stderr.
pub fn main(comptime name: []const u8, comptime run: fn (std.mem.Allocator) anyerror!void) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();
    run(arena_state.allocator()) catch |e| {
        var buf: [1400]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, name ++ ": {s}{s}{s}\n", .{ @errorName(e), if (last_error_len > 0) ": " else "", last_error[0..last_error_len] }) catch name ++ ": error\n";
        std.Io.File.stderr().writeStreamingAll(io(), msg) catch {};
        return 1;
    };
    return 0;
}
