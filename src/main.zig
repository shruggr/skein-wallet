//! wallet: the instance's record keeper of every output it owns (BSV and token outputs alike; it
//! knows nothing about tokens). It never builds or signs a transaction, has no spend route, no
//! "mark spent" call, and emits nothing about coins: its records are its own state (src/book.zig).
//!
//! Called:
//!   file     (in-VM, by another app's program in its own step, through the kernel's NAMED call:
//!            `callAs(<wallet program>, "file", "<basket>", arg)`). The basket IS the kernel-checked
//!            name, read from the call input's top-level `as`; a call without `as` is refused.
//!            arg (dag-cbor) {outpoint: "<txid>.<vout>", protocol: [level, name], keyID, counterparty}
//!            (counterparty: "self" | "anyone" | a 66-hex key, as written). The transaction must be
//!            one the chain state holds (the caller ingests it at the chain app earlier in the same
//!            step). Answer {outpoint, basket, satoshis, state, filed: true (new) | false (already)}.
//!            Then the wallet subscribes to `<chain>/output/<txid>.<vout>` and `<chain>/tx/<txid>`.
//!   outputs  (filter; the read route /wallet/outputs?basket=&after=&limit=): the basket's unspent
//!            outputs, each with its derivation, JSON {basket, outputs: [...], next}. Open, nothing logged.
//!   balance  (filter; the read route /wallet/balance?basket=): JSON {basket, satoshis}.
//! Stepped:
//!   tx, output   the subscriptions' steps (args {fn, event, box: <the name>, place}): the outputs the
//!                fact names are read again from the chain and their records set from it.
const std = @import("std");
const c = @import("chain");
const vm = @import("vm.zig");
const book = @import("book.zig");
const sk = @import("sk");
const options = @import("build_options");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The app's installed name: `wallet` (build option `app`, for a test build while skein reserves the name).
pub const NAME = options.app;
/// The wallet's one head: its book's record.
pub const BOOK_HEAD = NAME ++ "/book";
pub const DEFAULT_CHAIN = "chain";
pub const MAX_LIMIT = 1000;
pub const DEFAULT_LIMIT = 100;

pub fn main() u8 {
    return vm.main(NAME, run);
}

fn run(a: Allocator) anyerror!void {
    const in = try vm.input(a);
    const chain = try chainName(a);
    if (eql(u8, in.getText("kind") orelse "", "call")) {
        const func = in.getText("fn") orelse "";
        if (in.getBool("filter") orelse false) {
            const arg = try cbor.decode(a, in.getBytes("arg") orelse "");
            if (eql(u8, func, "outputs")) return vm.answer(a, try outputsRead(a, arg));
            if (eql(u8, func, "balance")) return vm.answer(a, try balanceRead(a, arg));
            return vm.refuse("the wallet's filters are outputs and balance");
        }
        if (eql(u8, func, "file")) return fileCall(a, in, chain);
        return vm.refuse("the wallet is called for file (a named call: the name is the basket); its reads are the filters outputs and balance");
    }
    // A subscription's step.
    const args = in.get("args") orelse return error.BadInput;
    const name = args.getText("box") orelse return error.BadInput;
    const func = args.getText("fn") orelse "";
    var env_impl = VmEnv{ .a = a, .chain = chain };
    const env = try env_impl.env();
    var b = try book.Book.load(a, vm.store(), try vm.head(a, BOOK_HEAD));
    var changed: usize = 0;
    const tail = name[(std.mem.lastIndexOfScalar(u8, name, '/') orelse return error.BadInput) + 1 ..];
    if (eql(u8, func, "tx")) {
        changed = try b.refreshTx(env, c.header.fromHex(tail) catch return error.BadInput);
    } else if (eql(u8, func, "output")) {
        const op = book.parseOutpoint(tail) orelse return error.BadInput;
        if (try b.refresh(env, op.txid, op.vout)) changed = 1;
    } else return vm.refuse("the wallet's subscriptions step tx and output");
    if (b.dirty()) try vm.advance(BOOK_HEAD, try b.save());
    _ = try vm.finish(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "wallet-result" } },
        .{ .key = "op", .value = .{ .text = func } },
        .{ .key = "name", .value = .{ .text = name } },
        .{ .key = "changed", .value = .{ .uint = changed } },
    }) });
}

/// `config.wallet.chain` of the app record (the chain app's installed name), else "chain".
fn chainName(a: Allocator) ![]const u8 {
    const r = (try vm.head(a, NAME ++ "/app")) orelse return DEFAULT_CHAIN;
    const rec = try vm.store().getValue(a, r);
    const conf = (rec.get("config") orelse return DEFAULT_CHAIN).get(NAME) orelse return DEFAULT_CHAIN;
    const n = conf.getText("chain") orelse return DEFAULT_CHAIN;
    return if (n.len == 0) DEFAULT_CHAIN else n;
}

// ---------------------------------------------------------------- file

pub const NO_NAME = "file: a call without a name files nothing (the name the kernel checked is the basket: callAs)";

/// The basket a filing call is made in: the name the kernel checked (the call input's `as`,
/// skein-sdk `sk.asName`); null when the call stated none (refused).
pub fn basketOf(in: sk.Value) ?[]const u8 {
    return sk.asName(in);
}

pub const FileArgs = struct { txid: [32]u8, vout: u32, d: book.Derivation };

/// The `file` arg, checked; else why not.
pub fn parseFileArgs(arg: Value) union(enum) { ok: FileArgs, bad: []const u8 } {
    const want = "want {outpoint: \"<txid>.<vout>\", protocol: [level, name], keyID, counterparty}";
    if (arg != .map) return .{ .bad = want };
    const op = book.parseOutpoint(arg.getText("outpoint") orelse return .{ .bad = want }) orelse return .{ .bad = "outpoint: <txid, 64 hex>.<vout>" };
    const p = arg.getArray("protocol") orelse return .{ .bad = want };
    if (p.len != 2 or p[0] != .uint or p[0].uint > 2 or p[1] != .text or p[1].text.len == 0) return .{ .bad = "protocol: [level 0..2, name]" };
    const key_id = arg.getText("keyID") orelse return .{ .bad = want };
    const cp = arg.getText("counterparty") orelse return .{ .bad = want };
    if (cp.len == 0) return .{ .bad = "counterparty: \"self\", \"anyone\" or a key in hex" };
    return .{ .ok = .{ .txid = op.txid, .vout = op.vout, .d = .{ .level = p[0].uint, .protocol = p[1].text, .key_id = key_id, .counterparty = cp } } };
}

fn fileCall(a: Allocator, in: Value, chain: []const u8) !void {
    const basket = basketOf(try sk.input(a)) orelse return vm.refuse(NO_NAME);
    const arg = cbor.decode(a, in.getBytes("arg") orelse "") catch return vm.refuse("file: the argument is not dag-cbor");
    const fa = switch (parseFileArgs(arg)) {
        .ok => |x| x,
        .bad => |why| return vm.refuse(try std.fmt.allocPrint(a, "file: {s}", .{why})),
    };
    var env_impl = VmEnv{ .a = a, .chain = chain };
    const env = try env_impl.env();
    var b = try book.Book.load(a, vm.store(), try vm.head(a, BOOK_HEAD));
    const f = b.file(env, basket, fa.txid, fa.vout, fa.d) catch |e| return vm.refuse(switch (e) {
        error.NotHeld => "file: the chain state does not hold the transaction (ingest it at the chain app first)",
        error.NoSuchOutput => "file: the transaction has no such output",
        error.FiledInAnotherBasket => "file: the output is filed in another basket",
        else => return e,
    });
    if (f.new) {
        try vm.advance(BOOK_HEAD, try b.save());
        try vm.on(try book.outputName(a, chain, fa.txid, fa.vout), "output");
        try vm.on(try book.txName(a, chain, fa.txid), "tx");
    }
    try vm.answer(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "outpoint", .value = .{ .text = try book.outpointText(a, fa.txid, fa.vout) } },
        .{ .key = "basket", .value = .{ .text = basket } },
        .{ .key = "satoshis", .value = .{ .uint = f.satoshis } },
        .{ .key = "state", .value = .{ .text = f.state.name() } },
        .{ .key = "filed", .value = .{ .boolean = f.new } },
    }) });
}

/// The book's view of the chain in the VM: the chain app's state (head `<chain>/state`, which a step
/// sees moved by its own ingest) and the event index.
const VmEnv = struct {
    a: Allocator,
    chain: []const u8,
    st: ?c.state.State = null,
    loaded: bool = false,

    fn env(self: *VmEnv) !book.Env {
        return .{ .ptr = self, .heldFn = held, .satoshisFn = satoshis, .chainStatusFn = chainStatus, .latestFn = latest, .chain = self.chain };
    }
    fn state(self: *VmEnv) !?*c.state.State {
        if (!self.loaded) {
            self.loaded = true;
            const h = try vm.head(self.a, try std.fmt.allocPrint(self.a, "{s}/state", .{self.chain}));
            if (h) |cid| self.st = try c.state.open(self.a, vm.store(), cid, .main);
        }
        return if (self.st) |*s| s else null;
    }
    fn held(ptr: *anyopaque, txid: [32]u8) anyerror!bool {
        const self: *VmEnv = @ptrCast(@alignCast(ptr));
        const st = (try self.state()) orelse return false;
        return st.holds(txid);
    }
    fn satoshis(ptr: *anyopaque, a: Allocator, txid: [32]u8, vout: u32) anyerror!?u64 {
        const self: *VmEnv = @ptrCast(@alignCast(ptr));
        const st = (try self.state()) orelse return null;
        const raw = (try st.txRaw(txid)) orelse return null;
        const tx = try c.bsvz.transaction.Transaction.parse(a, raw);
        if (vout >= tx.outputs.len) return null;
        return @intCast(tx.outputs[vout].satoshis);
    }
    fn chainStatus(ptr: *anyopaque, txid: [32]u8) anyerror!?[]const u8 {
        const self: *VmEnv = @ptrCast(@alignCast(ptr));
        const st = (try self.state()) orelse return null;
        if (!try st.holds(txid)) return null;
        return switch (try st.status(txid)) {
            .rejected => "rejected",
            .proven => "mined",
            .unproven => "pending",
        };
    }
    fn latest(_: *anyopaque, a: Allocator, name: []const u8) anyerror!?Value {
        return vm.latestEvent(a, name);
    }
};

// ---------------------------------------------------------------- the reads (filters, nothing logged)

pub fn queryParam(a: Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, std.mem.trimStart(u8, query, "?"), '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (!eql(u8, kv[0..eq], name)) continue;
        return try percentDecode(a, kv[eq + 1 ..]);
    }
    return null;
}

fn percentDecode(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, if (s[i] == '+') ' ' else s[i]);
    }
    return out.items;
}

pub fn jsonString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        0...0x1f => try out.appendSlice(a, try std.fmt.allocPrint(a, "\\u{x:0>4}", .{ch})),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

fn httpAnswer(a: Allocator, status: u64, body: []const u8) !Value {
    return .{ .map = try a.dupe(cbor.Entry, &.{.{ .key = "answer", .value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "status", .value = .{ .uint = status } },
        .{ .key = "type", .value = .{ .text = "application/json" } },
        .{ .key = "body", .value = .{ .bytes = body } },
    }) } }}) };
}

fn httpError(a: Allocator, status: u64, why: []const u8) !Value {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"error\":");
    try jsonString(a, &out, why);
    try out.append(a, '}');
    return httpAnswer(a, status, out.items);
}

/// The JSON of one listed output: {outpoint, satoshis, protocol: [level, name], keyID, counterparty}.
pub fn outputJson(a: Allocator, out: *std.ArrayList(u8), rec: Value) !void {
    const txid = rec.getText("txid") orelse return error.BadBook;
    const proto = rec.getArray("protocol") orelse return error.BadBook;
    try out.appendSlice(a, "{\"outpoint\":");
    try jsonString(a, out, try std.fmt.allocPrint(a, "{s}.{d}", .{ txid, rec.getUint("vout") orelse 0 }));
    try out.appendSlice(a, try std.fmt.allocPrint(a, ",\"satoshis\":{d},\"protocol\":[{d},", .{ rec.getUint("satoshis") orelse 0, proto[0].uint }));
    try jsonString(a, out, proto[1].text);
    try out.appendSlice(a, "],\"keyID\":");
    try jsonString(a, out, rec.getText("keyID") orelse "");
    try out.appendSlice(a, ",\"counterparty\":");
    try jsonString(a, out, rec.getText("counterparty") orelse "");
    try out.append(a, '}');
}

pub fn outputsJson(a: Allocator, basket: []const u8, page: book.Book.Page) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"basket\":");
    try jsonString(a, &out, basket);
    try out.appendSlice(a, ",\"outputs\":[");
    for (page.records, 0..) |r, i| {
        if (i > 0) try out.append(a, ',');
        try outputJson(a, &out, r);
    }
    try out.appendSlice(a, "],\"next\":");
    if (page.next) |n| {
        const op = try c.store.outpointOf(&n);
        try jsonString(a, &out, try book.outpointText(a, op.txid, op.vout));
    } else try out.appendSlice(a, "null");
    try out.append(a, '}');
    return out.items;
}

fn outputsRead(a: Allocator, req: Value) !Value {
    const q = req.getText("query") orelse "";
    const basket = (try queryParam(a, q, "basket")) orelse return httpError(a, 400, "want ?basket=<name>[&after=<txid>.<vout>][&limit=<1..1000>]");
    var after: ?[36]u8 = null;
    if (try queryParam(a, q, "after")) |t| {
        const op = book.parseOutpoint(t) orelse return httpError(a, 400, "after: <txid>.<vout>");
        after = c.store.outpointKey(op.txid, op.vout);
    }
    var limit: usize = DEFAULT_LIMIT;
    if (try queryParam(a, q, "limit")) |t| {
        limit = std.fmt.parseInt(usize, t, 10) catch return httpError(a, 400, "limit: 1..1000");
        if (limit == 0 or limit > MAX_LIMIT) return httpError(a, 400, "limit: 1..1000");
    }
    var b = try book.Book.load(a, vm.store(), try vm.head(a, BOOK_HEAD));
    return httpAnswer(a, 200, try outputsJson(a, basket, try b.list(basket, after, limit)));
}

fn balanceRead(a: Allocator, req: Value) !Value {
    const q = req.getText("query") orelse "";
    const basket = (try queryParam(a, q, "basket")) orelse return httpError(a, 400, "want ?basket=<name>");
    var b = try book.Book.load(a, vm.store(), try vm.head(a, BOOK_HEAD));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"basket\":");
    try jsonString(a, &out, basket);
    try out.appendSlice(a, try std.fmt.allocPrint(a, ",\"satoshis\":{d}}}", .{try b.balance(basket)}));
    return httpAnswer(a, 200, out.items);
}
