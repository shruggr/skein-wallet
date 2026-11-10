//! The book, natively: filing, every state the chain's two event kinds drive (with the walk-backs),
//! the tally, the late filer, paging, and the call's arg and answer shapes. The chain is a stand-in
//! (`Fake`): what the chain state holds and the latest fact under each name.
const std = @import("std");
const c = @import("chain");
const book = @import("src/book.zig");
const main = @import("src/main.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Fake = struct {
    a: Allocator,
    /// txid → its outputs' satoshis (held).
    held: std.AutoHashMapUnmanaged([32]u8, []const u64) = .empty,
    /// event name → latest record.
    latest: std.StringHashMapUnmanaged(Value) = .empty,
    /// The chain state's own status (used when the index has no tx fact yet).
    chain_status: std.AutoHashMapUnmanaged([32]u8, []const u8) = .empty,

    fn env(self: *Fake) book.Env {
        return .{ .ptr = self, .heldFn = heldF, .satoshisFn = satsF, .chainStatusFn = statusF, .latestFn = latestF, .chain = "chain" };
    }
    fn heldF(p: *anyopaque, txid: [32]u8) anyerror!bool {
        const s: *Fake = @ptrCast(@alignCast(p));
        return s.held.contains(txid);
    }
    fn satsF(p: *anyopaque, _: Allocator, txid: [32]u8, vout: u32) anyerror!?u64 {
        const s: *Fake = @ptrCast(@alignCast(p));
        const outs = s.held.get(txid) orelse return null;
        return if (vout < outs.len) outs[vout] else null;
    }
    fn statusF(p: *anyopaque, txid: [32]u8) anyerror!?[]const u8 {
        const s: *Fake = @ptrCast(@alignCast(p));
        return s.chain_status.get(txid);
    }
    fn latestF(p: *anyopaque, _: Allocator, name: []const u8) anyerror!?Value {
        const s: *Fake = @ptrCast(@alignCast(p));
        return s.latest.get(name);
    }
    fn hold(self: *Fake, txid: [32]u8, outs: []const u64) !void {
        try self.held.put(self.a, txid, outs);
    }
    fn txFact(self: *Fake, txid: [32]u8, status: []const u8) !void {
        const n = try book.txName(self.a, "chain", txid);
        try self.latest.put(self.a, n, .{ .map = try self.a.dupe(cbor.Entry, &.{.{ .key = "status", .value = .{ .text = status } }}) });
    }
    fn outFact(self: *Fake, txid: [32]u8, vout: u32, state: []const u8, by: [32]u8) !void {
        const n = try book.outputName(self.a, "chain", txid, vout);
        try self.latest.put(self.a, n, .{ .map = try self.a.dupe(cbor.Entry, &.{
            .{ .key = "state", .value = .{ .text = state } },
            .{ .key = "spentBy", .value = .{ .text = try self.a.dupe(u8, &c.header.toHex(by)) } },
        }) });
    }
};

fn tx(n: u8) [32]u8 {
    var t: [32]u8 = @splat(0);
    t[0] = n;
    t[31] = n;
    return t;
}

const d = book.Derivation{ .level = 1, .protocol = "amm pool", .key_id = "abc_0", .counterparty = "anyone" };

const Setup = struct {
    arena: std.heap.ArenaAllocator,
    ms: c.store.MemStore,
    fake: Fake,
    fn init(self: *Setup) void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ms = c.store.MemStore.init(testing.allocator);
        self.fake = .{ .a = self.arena.allocator() };
    }
    fn deinit(self: *Setup) void {
        self.ms.deinit();
        self.arena.deinit();
    }
    fn book_(self: *Setup, root: ?[]const u8) !book.Book {
        return book.Book.load(self.arena.allocator(), self.ms.store(), root);
    }
};

fn stateOf(b: *book.Book, t: [32]u8, v: u32) !book.State {
    return book.stateOf((try b.record(t, v)).?).?;
}

test "file: once per outpoint; again in the same basket changes nothing; another basket refused; tx not held refused" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    try testing.expectError(error.NotHeld, b.file(env, "fees", tx(1), 0, d));
    try s.fake.hold(tx(1), &.{ 500, 7 });
    try testing.expectError(error.NoSuchOutput, b.file(env, "fees", tx(1), 5, d));
    const f = try b.file(env, "fees", tx(1), 0, d);
    try testing.expect(f.new);
    try testing.expectEqual(@as(u64, 500), f.satoshis);
    try testing.expectEqual(book.State.unspent, f.state);
    const again = try b.file(env, "fees", tx(1), 0, d);
    try testing.expect(!again.new);
    try testing.expectEqual(@as(u64, 500), try b.balance("fees"));
    try testing.expectError(error.FiledInAnotherBasket, b.file(env, "other", tx(1), 0, d));
    // The record keeps the derivation as given.
    const r = (try b.record(tx(1), 0)).?;
    try testing.expectEqualStrings("amm pool", r.getArray("protocol").?[1].text);
    try testing.expectEqualStrings("abc_0", r.getText("keyID").?);
    try testing.expectEqualStrings("anyone", r.getText("counterparty").?);
    try testing.expectEqualStrings("fees", r.getText("basket").?);
    // Persisted: saved and loaded again.
    const root = try b.save();
    var b2 = try s.book_(root);
    try testing.expectEqual(@as(u64, 500), try b2.balance("fees"));
    try testing.expectEqual(@as(u64, 0), try b2.balance("other"));
}

test "states: spent by T (kept), rolled back → unspent; payer rejected → void; mined again → out of void; the tally follows unspent only" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    try s.fake.hold(tx(1), &.{ 100, 200 });
    _ = try b.file(env, "bsv", tx(1), 0, d);
    _ = try b.file(env, "bsv", tx(1), 1, d);
    try testing.expectEqual(@as(u64, 300), try b.balance("bsv"));

    // spent by tx 9
    try s.fake.outFact(tx(1), 0, "spent", tx(9));
    try testing.expect(try b.refresh(env, tx(1), 0));
    try testing.expectEqual(book.State.spent, try stateOf(&b, tx(1), 0));
    try testing.expectEqualStrings(&c.header.toHex(tx(9)), (try b.record(tx(1), 0)).?.getText("spentBy").?);
    try testing.expectEqual(@as(u64, 200), try b.balance("bsv"));
    try testing.expect(!try b.refresh(env, tx(1), 0)); // read again: nothing new

    // spent by another (the live spender changed): the record follows, the tally does not move
    try s.fake.outFact(tx(1), 0, "spent", tx(8));
    try testing.expect(try b.refresh(env, tx(1), 0));
    try testing.expectEqualStrings(&c.header.toHex(tx(8)), (try b.record(tx(1), 0)).?.getText("spentBy").?);
    try testing.expectEqual(@as(u64, 200), try b.balance("bsv"));

    // rolled back → unspent again, spentBy gone
    try s.fake.outFact(tx(1), 0, "rolledBack", tx(8));
    try testing.expect(try b.refresh(env, tx(1), 0));
    try testing.expectEqual(book.State.unspent, try stateOf(&b, tx(1), 0));
    try testing.expect((try b.record(tx(1), 0)).?.getText("spentBy") == null);
    try testing.expectEqual(@as(u64, 300), try b.balance("bsv"));

    // the paying tx rejected: both outputs void, the tally 0 — also the spent one
    try s.fake.outFact(tx(1), 1, "spent", tx(7));
    _ = try b.refresh(env, tx(1), 1);
    try testing.expectEqual(@as(u64, 100), try b.balance("bsv"));
    try s.fake.txFact(tx(1), "rejected");
    try testing.expectEqual(@as(usize, 2), try b.refreshTx(env, tx(1)));
    try testing.expectEqual(book.State.void, try stateOf(&b, tx(1), 0));
    try testing.expectEqual(book.State.void, try stateOf(&b, tx(1), 1));
    try testing.expectEqual(@as(u64, 0), try b.balance("bsv"));

    // mined after all → out of void: output 0 unspent, output 1 spent (its fact still says so)
    try s.fake.txFact(tx(1), "mined");
    try testing.expectEqual(@as(usize, 2), try b.refreshTx(env, tx(1)));
    try testing.expectEqual(book.State.unspent, try stateOf(&b, tx(1), 0));
    try testing.expectEqual(book.State.spent, try stateOf(&b, tx(1), 1));
    try testing.expectEqual(@as(u64, 100), try b.balance("bsv"));

    // seen / pending after rejected walk back the same way
    try s.fake.txFact(tx(1), "rejected");
    _ = try b.refreshTx(env, tx(1));
    try s.fake.txFact(tx(1), "seen");
    _ = try b.refreshTx(env, tx(1));
    try testing.expectEqual(@as(u64, 100), try b.balance("bsv"));
    try s.fake.txFact(tx(1), "rejected");
    _ = try b.refreshTx(env, tx(1));
    try s.fake.txFact(tx(1), "pending");
    _ = try b.refreshTx(env, tx(1));
    try testing.expectEqual(@as(u64, 100), try b.balance("bsv"));
}

test "late filer: a spend fact or a rejection already there at filing is read once" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    try s.fake.hold(tx(2), &.{ 50, 60 });
    try s.fake.outFact(tx(2), 0, "spent", tx(9));
    const f = try b.file(env, "k", tx(2), 0, d);
    try testing.expectEqual(book.State.spent, f.state);
    try testing.expectEqual(@as(u64, 0), try b.balance("k"));
    try s.fake.hold(tx(3), &.{70});
    try s.fake.txFact(tx(3), "rejected");
    try testing.expectEqual(book.State.void, (try b.file(env, "k", tx(3), 0, d)).state);
    try testing.expectEqual(@as(u64, 0), try b.balance("k"));
    // No tx fact visible yet (the caller's own ingest step): the chain state's own reading.
    try s.fake.hold(tx(4), &.{80});
    try s.fake.chain_status.put(s.fake.a, tx(4), "rejected");
    try testing.expectEqual(book.State.void, (try b.file(env, "k", tx(4), 0, d)).state);
    try s.fake.chain_status.put(s.fake.a, tx(5), "pending");
    try s.fake.hold(tx(5), &.{90});
    try testing.expectEqual(book.State.unspent, (try b.file(env, "k", tx(5), 0, d)).state);
    try testing.expectEqual(@as(u64, 90), try b.balance("k"));
}

test "baskets are apart; list pages a basket's unspent outputs in outpoint order with a cursor" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    var i: u8 = 1;
    while (i <= 7) : (i += 1) {
        try s.fake.hold(tx(i), &.{@as(u64, i) * 10});
        _ = try b.file(env, if (i % 2 == 0) "even" else "odd", tx(i), 0, d);
    }
    try testing.expectEqual(@as(u64, 10 + 30 + 50 + 70), try b.balance("odd"));
    try testing.expectEqual(@as(u64, 20 + 40 + 60), try b.balance("even"));
    // one of "odd" spent: not listed
    try s.fake.outFact(tx(3), 0, "spent", tx(99));
    _ = try b.refresh(env, tx(3), 0);
    const root = try b.save();
    var r = try s.book_(root);
    const p1 = try r.list("odd", null, 2);
    try testing.expectEqual(@as(usize, 2), p1.records.len);
    try testing.expectEqual(@as(u64, 10), p1.records[0].getUint("satoshis").?);
    try testing.expectEqual(@as(u64, 50), p1.records[1].getUint("satoshis").?);
    try testing.expect(p1.next != null);
    const p2 = try r.list("odd", p1.next, 2);
    try testing.expectEqual(@as(usize, 1), p2.records.len);
    try testing.expectEqual(@as(u64, 70), p2.records[0].getUint("satoshis").?);
    try testing.expect(p2.next == null);
    try testing.expectEqual(@as(usize, 3), (try r.list("even", null, 100)).records.len);
    try testing.expectEqual(@as(usize, 0), (try r.list("none", null, 100)).records.len);
    // the JSON of a page
    const json = try main.outputsJson(s.arena.allocator(), "odd", p2);
    try testing.expect(std.mem.indexOf(u8, json, "\"protocol\":[1,\"amm pool\"]") != null);
    try testing.expect(std.mem.endsWith(u8, json, "\"next\":null}"));
}

test "the file arg" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    const a = s.arena.allocator();
    const op = try book.outpointText(a, tx(1), 3);
    const good: Value = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "outpoint", .value = .{ .text = op } },
        .{ .key = "protocol", .value = .{ .array = try a.dupe(Value, &.{ .{ .uint = 2 }, .{ .text = "3241645161d8" } }) } },
        .{ .key = "keyID", .value = .{ .text = "p s" } },
        .{ .key = "counterparty", .value = .{ .text = "02aa" } },
    }) };
    const p = main.parseFileArgs(good);
    try testing.expect(p == .ok);
    try testing.expectEqual(@as(u32, 3), p.ok.vout);
    try testing.expectEqual(tx(1), p.ok.txid);
    try testing.expect(main.parseFileArgs(.{ .map = good.map[0..2] }) == .bad);
    try testing.expect(book.parseOutpoint("zz.1") == null);
    try testing.expectEqualStrings("a b", (try main.queryParam(a, "?basket=a%20b&x=1", "basket")).?);
}

test "the basket is the call input's `as` (sk.asName); a call without it has none (refused)" {
    const sk = @import("sk");
    const named: sk.Value = .{ .map = &.{ .{ .key = "kind", .value = .{ .string = "call" } }, .{ .key = "fn", .value = .{ .string = "file" } }, .{ .key = "as", .value = .{ .string = "bsv" } } } };
    try testing.expectEqualStrings("bsv", main.basketOf(named).?);
    const plain: sk.Value = .{ .map = &.{ .{ .key = "kind", .value = .{ .string = "call" } }, .{ .key = "fn", .value = .{ .string = "file" } } } };
    try testing.expect(main.basketOf(plain) == null);
}

/// A `chain/tx` fact with a reason (and `by`), as skein-chain 0.11.0 raises a rejection.
fn rejectedFact(f: *Fake, txid: [32]u8, reason: []const u8, by: ?[32]u8) !void {
    const n = try book.txName(f.a, "chain", txid);
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.append(f.a, .{ .key = "status", .value = .{ .text = "rejected" } });
    try es.append(f.a, .{ .key = "reason", .value = .{ .text = reason } });
    if (by) |b| try es.append(f.a, .{ .key = "by", .value = .{ .text = try f.a.dupe(u8, &c.header.toHex(b)) } });
    try f.latest.put(f.a, n, .{ .map = es.items });
}

test "no terminal void: rejected → void → mined → unspent again, the tally back (a later chain/tx fact re-read on its wake)" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    try s.fake.hold(tx(1), &.{ 400, 600 });
    _ = try b.file(env, "bsv", tx(1), 0, d);
    _ = try b.file(env, "bsv", tx(1), 1, d);
    // output 1 spent before the rejection
    try s.fake.outFact(tx(1), 1, "spent", tx(9));
    _ = try b.refresh(env, tx(1), 1);
    try testing.expectEqual(@as(u64, 400), try b.balance("bsv"));
    // a wrong rejection: both void, out of the tally
    try rejectedFact(&s.fake, tx(1), "REJECTED", null);
    try testing.expectEqual(@as(usize, 2), try b.refreshTx(env, tx(1)));
    try testing.expectEqual(book.State.void, try stateOf(&b, tx(1), 0));
    try testing.expectEqual(book.State.void, try stateOf(&b, tx(1), 1));
    try testing.expectEqual(@as(u64, 0), try b.balance("bsv"));
    try testing.expectEqual(@as(usize, 0), (try b.list("bsv", null, 10)).records.len);
    // later mined (a proof overrides the rejection): output 0 unspent, output 1 spent again, the tally back
    try s.fake.txFact(tx(1), "mined");
    const root = try b.save();
    var b2 = try s.book_(root); // the wake is a later step: the book loaded from its head
    try testing.expectEqual(@as(usize, 2), try b2.refreshTx(env, tx(1)));
    try testing.expectEqual(book.State.unspent, try stateOf(&b2, tx(1), 0));
    try testing.expectEqual(book.State.spent, try stateOf(&b2, tx(1), 1));
    try testing.expectEqual(@as(u64, 400), try b2.balance("bsv"));
    try testing.expectEqual(@as(usize, 1), (try b2.list("bsv", null, 10)).records.len);
}

test "no terminal void: input-rejected → void → revived (pending) → unspent again, the tally back" {
    var s: Setup = undefined;
    s.init();
    defer s.deinit();
    var b = try s.book_(null);
    const env = s.fake.env();
    try s.fake.hold(tx(2), &.{250});
    try s.fake.txFact(tx(2), "pending");
    _ = try b.file(env, "bsv", tx(2), 0, d);
    try testing.expectEqual(@as(u64, 250), try b.balance("bsv"));
    // its parent rejected: the chain app's parents step raises input-rejected for it
    try rejectedFact(&s.fake, tx(2), "input-rejected", tx(7));
    try testing.expect(try b.refresh(env, tx(2), 0));
    try testing.expectEqual(book.State.void, try stateOf(&b, tx(2), 0));
    try testing.expectEqual(@as(u64, 0), try b.balance("bsv"));
    // the parent's rejection no longer holds: revived, pending again
    try s.fake.txFact(tx(2), "pending");
    const root = try b.save();
    var b2 = try s.book_(root);
    try testing.expectEqual(@as(usize, 1), try b2.refreshTx(env, tx(2)));
    try testing.expectEqual(book.State.unspent, try stateOf(&b2, tx(2), 0));
    try testing.expectEqual(@as(u64, 250), try b2.balance("bsv"));
    // and seen again after a reorg keeps it unspent
    try s.fake.txFact(tx(2), "seen");
    try testing.expect(!try b2.refresh(env, tx(2), 0));
    try testing.expectEqual(@as(u64, 250), try b2.balance("bsv"));
}
