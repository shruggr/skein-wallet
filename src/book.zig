//! The wallet's book: one record per output the instance owns, an index by basket and state, and a
//! running satoshi tally per basket over the UNSPENT outputs only. Pure: the chain is read through
//! `Env` (in the VM: the chain app's state and the event index, main.zig; in tests: a stand-in).
//!
//! An output's state is READ from the chain every time, never derived from deltas:
//!   void     the paying transaction's status is `rejected` (the output does not exist)
//!   spent    the latest `<chain>/output/<txid>.<vout>` message says `spent` (its `spentBy` kept)
//!   unspent  otherwise (no message, or `rolledBack`)
//! A later status walks it back the same way (rolled back → unspent; the payer mined/seen/pending
//! again after rejected → out of void). Nothing is ever deleted.
//!
//! Maps (MST, chain library `store.Map`):
//!   outputs  txid(32, internal order) ‖ vout(u32 BE)        → link to the output record
//!   index    len ‖ basket ‖ state(1 byte) ‖ outpoint(36)     → null
//!   tallies  len ‖ basket                                    → int (satoshis of its unspent outputs)
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const Map = c.store.Map;
const Maps = c.store.Maps;
const Store = c.store.Store;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const BOOK_KIND = "wallet-book";
pub const OUTPUT_KIND = "wallet-output";

pub const State = enum(u8) {
    unspent = 0,
    spent = 1,
    void = 2,

    pub fn name(s: State) []const u8 {
        return @tagName(s);
    }
};

/// What the book reads of the chain.
pub const Env = struct {
    ptr: *anyopaque,
    /// Whether the chain state holds the transaction.
    heldFn: *const fn (ptr: *anyopaque, txid: [32]u8) anyerror!bool,
    /// Output `vout`'s satoshis of a held transaction, or null (no such output).
    satoshisFn: *const fn (ptr: *anyopaque, a: Allocator, txid: [32]u8, vout: u32) anyerror!?u64,
    /// The chain state's own reading of a transaction's status: "rejected" or anything else; null if not held.
    /// Used only when the event index has no `<chain>/tx/<txid>` fact yet (the caller's own ingest step:
    /// a step does not see its own emits).
    chainStatusFn: *const fn (ptr: *anyopaque, txid: [32]u8) anyerror!?[]const u8,
    /// The latest record under an event name, or null.
    latestFn: *const fn (ptr: *anyopaque, a: Allocator, name: []const u8) anyerror!?Value,
    /// The chain app's installed name (`chain`): the prefix of the names read.
    chain: []const u8,
};

pub const Derivation = struct {
    level: u64,
    protocol: []const u8,
    key_id: []const u8,
    counterparty: []const u8,
};

pub fn txName(a: Allocator, chain: []const u8, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/tx/{s}", .{ chain, &c.header.toHex(txid) });
}

pub fn outputName(a: Allocator, chain: []const u8, txid: [32]u8, vout: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/output/{s}.{d}", .{ chain, &c.header.toHex(txid), vout });
}

pub fn outpointText(a: Allocator, txid: [32]u8, vout: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}.{d}", .{ &c.header.toHex(txid), vout });
}

/// `<txid hex, display order>.<vout>` → (txid, vout).
pub fn parseOutpoint(text: []const u8) ?struct { txid: [32]u8, vout: u32 } {
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
    if (dot != 64) return null;
    const txid = c.header.fromHex(text[0..64]) catch return null;
    const vout = std.fmt.parseInt(u32, text[dot + 1 ..], 10) catch return null;
    return .{ .txid = txid, .vout = vout };
}

/// An output's state as the chain says it is now.
pub const Reading = struct { state: State, spent_by: ?[]const u8 = null };

pub fn read(a: Allocator, env: Env, txid: [32]u8, vout: u32) !Reading {
    const payer = try env.latestFn(env.ptr, a, try txName(a, env.chain, txid));
    const status: ?[]const u8 = if (payer) |p| p.getText("status") else try env.chainStatusFn(env.ptr, txid);
    if (status) |s| if (eql(u8, s, "rejected")) return .{ .state = .void };
    if (try env.latestFn(env.ptr, a, try outputName(a, env.chain, txid, vout))) |o| {
        if (eql(u8, o.getText("state") orelse "", "spent")) return .{ .state = .spent, .spent_by = o.getText("spentBy") };
    }
    return .{ .state = .unspent };
}

pub const Book = struct {
    arena: Allocator,
    store: Store,
    maps: *Maps,
    outputs: Map,
    index: Map,
    tallies: Map,

    /// The book the head's record names (null: an empty one).
    pub fn load(arena: Allocator, s: Store, root: ?[]const u8) !Book {
        const maps = try Maps.create(arena, s);
        var rec: ?Value = null;
        if (root) |r| {
            const v = try s.getValue(arena, r);
            if (!eql(u8, v.getText("kind") orelse "", BOOK_KIND)) return error.BadBook;
            rec = v;
        }
        const get = struct {
            fn f(v: ?Value, k: []const u8) ?[]const u8 {
                return if (v) |x| x.getCid(k) else null;
            }
        }.f;
        return .{ .arena = arena, .store = s, .maps = maps, .outputs = maps.map(get(rec, "outputs")), .index = maps.map(get(rec, "index")), .tallies = maps.map(get(rec, "tallies")) };
    }

    pub fn dirty(self: *const Book) bool {
        return self.outputs.dirty or self.index.dirty or self.tallies.dirty;
    }

    /// Flush the maps and put the book's record → its CID.
    pub fn save(self: *Book) ![]const u8 {
        try self.outputs.flush();
        try self.index.flush();
        try self.tallies.flush();
        const opt = struct {
            fn f(r: ?[]const u8) Value {
                return if (r) |x| .{ .cid = x } else .null;
            }
        }.f;
        return self.store.putValue(self.arena, .{ .map = try self.arena.dupe(cbor.Entry, &.{
            .{ .key = "kind", .value = .{ .text = BOOK_KIND } },
            .{ .key = "outputs", .value = opt(self.outputs.root) },
            .{ .key = "index", .value = opt(self.index.root) },
            .{ .key = "tallies", .value = opt(self.tallies.root) },
        }) });
    }

    fn indexKey(self: *Book, basket: []const u8, st: State, op: [36]u8) ![]u8 {
        return c.store.nameKey(self.arena, basket, &.{ &[_]u8{@intFromEnum(st)}, &op });
    }

    pub fn balance(self: *Book, basket: []const u8) !u64 {
        const v = (try self.tallies.get(try c.store.nameKey(self.arena, basket, &.{}))) orelse return 0;
        return if (v == .int) @intCast(v.int) else error.BadBook;
    }

    fn addTally(self: *Book, basket: []const u8, sats: u64, plus: bool) !void {
        const k = try c.store.nameKey(self.arena, basket, &.{});
        const now = try self.balance(basket);
        const next = if (plus) now + sats else now - @min(now, sats);
        try self.tallies.put(k, .{ .int = next });
    }

    /// The output's record, or null.
    pub fn record(self: *Book, txid: [32]u8, vout: u32) !?Value {
        const l = (try self.outputs.link(&c.store.outpointKey(txid, vout))) orelse return null;
        return try self.store.getValue(self.arena, l);
    }

    fn putRecord(self: *Book, txid: [32]u8, vout: u32, basket: []const u8, d: Derivation, sats: u64, r: Reading) !void {
        var es: std.ArrayList(cbor.Entry) = .empty;
        try es.appendSlice(self.arena, &.{
            .{ .key = "kind", .value = .{ .text = OUTPUT_KIND } },
            .{ .key = "txid", .value = .{ .text = try self.arena.dupe(u8, &c.header.toHex(txid)) } },
            .{ .key = "vout", .value = .{ .uint = vout } },
            .{ .key = "protocol", .value = .{ .array = try self.arena.dupe(Value, &.{ .{ .uint = d.level }, .{ .text = d.protocol } }) } },
            .{ .key = "keyID", .value = .{ .text = d.key_id } },
            .{ .key = "counterparty", .value = .{ .text = d.counterparty } },
            .{ .key = "basket", .value = .{ .text = basket } },
            .{ .key = "satoshis", .value = .{ .uint = sats } },
            .{ .key = "state", .value = .{ .text = r.state.name() } },
        });
        if (r.state == .spent) if (r.spent_by) |s| try es.append(self.arena, .{ .key = "spentBy", .value = .{ .text = s } });
        const cid = try self.store.putValue(self.arena, .{ .map = es.items });
        try self.outputs.putLink(&c.store.outpointKey(txid, vout), cid);
    }

    pub const Filed = struct { state: State, satoshis: u64, new: bool };

    /// File an output in `basket` (the kernel-checked name the call was made under). Idempotent on the
    /// outpoint: filed again in the same basket changes nothing; in another basket it is refused.
    pub fn file(self: *Book, env: Env, basket: []const u8, txid: [32]u8, vout: u32, d: Derivation) !Filed {
        if (try self.record(txid, vout)) |old| {
            if (!eql(u8, old.getText("basket") orelse "", basket)) return error.FiledInAnotherBasket;
            return .{ .state = stateOf(old) orelse return error.BadBook, .satoshis = old.getUint("satoshis") orelse 0, .new = false };
        }
        if (!try env.heldFn(env.ptr, txid)) return error.NotHeld;
        const sats = (try env.satoshisFn(env.ptr, self.arena, txid, vout)) orelse return error.NoSuchOutput;
        const r = try read(self.arena, env, txid, vout);
        try self.putRecord(txid, vout, basket, d, sats, r);
        try self.index.add(try self.indexKey(basket, r.state, c.store.outpointKey(txid, vout)));
        if (r.state == .unspent) try self.addTally(basket, sats, true);
        return .{ .state = r.state, .satoshis = sats, .new = true };
    }

    /// Read the output's state from the chain again and set the record from it. → whether it changed.
    pub fn refresh(self: *Book, env: Env, txid: [32]u8, vout: u32) !bool {
        const old = (try self.record(txid, vout)) orelse return false;
        const was = stateOf(old) orelse return error.BadBook;
        const r = try read(self.arena, env, txid, vout);
        const old_by = old.getText("spentBy");
        const same_by = if (r.state != .spent) old_by == null else (old_by != null and r.spent_by != null and eql(u8, old_by.?, r.spent_by.?));
        if (was == r.state and same_by) return false;
        const basket = old.getText("basket") orelse return error.BadBook;
        const sats = old.getUint("satoshis") orelse return error.BadBook;
        const proto = old.getArray("protocol") orelse return error.BadBook;
        if (proto.len != 2 or proto[0] != .uint or proto[1] != .text) return error.BadBook;
        const d = Derivation{ .level = proto[0].uint, .protocol = proto[1].text, .key_id = old.getText("keyID") orelse return error.BadBook, .counterparty = old.getText("counterparty") orelse return error.BadBook };
        const op = c.store.outpointKey(txid, vout);
        if (was != r.state) {
            _ = try self.index.remove(try self.indexKey(basket, was, op));
            try self.index.add(try self.indexKey(basket, r.state, op));
            if (was == .unspent) try self.addTally(basket, sats, false);
            if (r.state == .unspent) try self.addTally(basket, sats, true);
        }
        try self.putRecord(txid, vout, basket, d, sats, r);
        return true;
    }

    /// Every output of `txid` in the book, read again (a status fact of the paying transaction).
    pub fn refreshTx(self: *Book, env: Env, txid: [32]u8) !usize {
        var n: usize = 0;
        for (try self.outputs.prefixed(&txid)) |kv| {
            const o = try c.store.outpointOf(kv.key);
            if (try self.refresh(env, o.txid, o.vout)) n += 1;
        }
        return n;
    }

    pub const Page = struct { records: []Value, next: ?[36]u8 };

    /// A basket's unspent outputs in outpoint order, strictly after `after`, at most `limit`.
    pub fn list(self: *Book, basket: []const u8, after: ?[36]u8, limit: usize) !Page {
        const pre = try c.store.nameKey(self.arena, basket, &.{&[_]u8{@intFromEnum(State.unspent)}});
        const hi = try c.store.nameKey(self.arena, basket, &.{&[_]u8{@intFromEnum(State.unspent) + 1}});
        const lo = if (after) |a| try std.mem.concat(self.arena, u8, &.{ pre, &a, &[_]u8{0} }) else pre;
        const rows = try self.index.range(lo, hi);
        const n = @min(rows.len, limit);
        const out = try self.arena.alloc(Value, n);
        var last: [36]u8 = undefined;
        for (rows[0..n], out) |kv, *o| {
            last = kv.key[kv.key.len - 36 ..][0..36].*;
            const op = try c.store.outpointOf(&last);
            o.* = (try self.record(op.txid, op.vout)) orelse return error.BadBook;
        }
        return .{ .records = out, .next = if (rows.len > n) last else null };
    }
};

pub fn stateOf(rec: Value) ?State {
    return std.meta.stringToEnum(State, rec.getText("state") orelse return null);
}
