// The wallet app end to end on a real kernel (skein with call permissions, branch `call-permissions`)
// and the chain app (skein-chain 0.10.0). One instance `w` on a test host with a fake Arcade and a
// regtest header chain:
//
//   - the chain app, the wallet app and a probe app (skein's programs/test/perm-probe) installed by
//     the owner's messages; the probe's manifest asks `calls: {<wallet>: ["bsv"]}` (granted at install);
//   - a funding transaction mined in block 1 and ingested at the chain app;
//   - the probe files its output 0 by the named call (callAs) as "bsv": filed unspent, the tally its
//     satoshis, both reads right;
//   - the same output again: no change; a basket the probe is not approved for: refused by the KERNEL;
//     a call with no name: refused by the wallet; a transaction the chain state does not hold: refused;
//   - a transaction spending the filed output ingested: chain/output/<op> says spent → the record
//     spent (spentBy kept), off the list, the tally 0;
//   - that spender rejected by the network: chain/output/<op> rolledBack → unspent again;
//   - a filed output whose PAYING transaction is then rejected: void, out of the tally;
//   - the store replays to itself exactly.
//
//   SKEIN_DIR=<a skein checkout at call-permissions, kernel built>  WALLET_WASM=<wallet.wasm built with -Dapp=walletx>
//   SKEIN_CHAIN_DIR=<skein-chain at v0.10.0>  node --experimental-strip-types --no-warnings test/e2e.ts
//
// The app is installed as `walletx`: skein still reserves the name `wallet` (its genesis-wired wallet
// program, src/host/manifest.ts RESERVED_NAMES). The module is the same code built with -Dapp=walletx.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const SKEIN = process.env.SKEIN_DIR ?? "";
const CHAIN_DIR = process.env.SKEIN_CHAIN_DIR ?? "";
const WALLET_WASM = process.env.WALLET_WASM ?? "";
if (!SKEIN || !CHAIN_DIR || !WALLET_WASM) throw new Error("set SKEIN_DIR, SKEIN_CHAIN_DIR and WALLET_WASM");
const APP = "walletx";
const req = createRequire(join(SKEIN, "package.json"));
const imp = async <T>(p: string): Promise<T> => await import(pathToFileURL(join(SKEIN, p)).href) as T;
/** A package's ESM entry as skein's own modules import it (its exports' `import`), so the classes are the same. */
const esm = (pkg: string) => {
  const pj = join(SKEIN, "node_modules", pkg, "package.json");
  const x = (JSON.parse(readFileSync(pj, "utf8")) as { exports: Record<string, { import: string | { default: string } }> }).exports["."]!.import;
  return pathToFileURL(join(dirname(pj), typeof x === "string" ? x : x.default)).href;
};
const { MerklePath, P2PKH, PrivateKey, Transaction, UnlockingScript } = await import(esm("@bsv/sdk")) as typeof import("@bsv/sdk");
const dagCbor = await import(esm("@ipld/dag-cbor")) as typeof import("@ipld/dag-cbor");
const { RawBox } = await imp<typeof import("../../skein/src/client/raw.ts")>("src/client/raw.ts");
const { ownerCli } = await imp<typeof import("../../skein/src/testapps.ts")>("src/testapps.ts");
const { FakeArcade } = await imp<typeof import("../../skein/src/host/fake-arcade.ts")>("src/host/fake-arcade.ts");
const { testHost, until } = await imp<typeof import("../../skein/src/host/testhost.ts")>("src/host/testhost.ts");
const { storeSpec } = await imp<typeof import("../../skein/src/runtime/index-store.ts")>("src/runtime/index-store.ts");
const { ROCKS_MODE } = await imp<typeof import("../../skein/kernel-zig/equiv/backend.ts")>("kernel-zig/equiv/backend.ts");

let failures = 0;
const check = (ok: boolean, what: string) => { process.stdout.write(`${ok ? "ok  " : "FAIL"} ${what}\n`); if (!ok) failures++; };

// ---------------------------------------------------------------- regtest (as skein's equiv/chain.ts)
const sha256d = (b: Uint8Array) => createHash("sha256").update(createHash("sha256").update(b).digest()).digest();
const internal = (displayHex: string) => Buffer.from(displayHex, "hex").reverse();
const REGTEST_GENESIS = Buffer.from("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4adae5494dffff7f2002000000", "hex");
const TARGET = 0x7fffffn << BigInt(8 * (0x20 - 3));
function mine(prev: Uint8Array, merkleRoot: Uint8Array, time: number): Uint8Array {
  const h = Buffer.alloc(80);
  h.writeInt32LE(1, 0);
  Buffer.from(prev).copy(h, 4);
  Buffer.from(merkleRoot).copy(h, 36);
  h.writeUInt32LE(time, 68);
  h.writeUInt32LE(0x207fffff, 72);
  for (let nonce = 0; ; nonce++) {
    h.writeUInt32LE(nonce, 76);
    if (BigInt("0x" + Buffer.from(sha256d(h)).reverse().toString("hex")) <= TARGET) return new Uint8Array(h);
  }
}

// ---------------------------------------------------------------- the app trees
const trees = mkdtempSync(join(tmpdir(), "skein-wallet-e2e-"));
function walletTree(): string {
  const at = join(trees, APP);
  mkdirSync(join(at, "bin"), { recursive: true });
  mkdirSync(join(at, "etc"), { recursive: true });
  copyFileSync(WALLET_WASM, join(at, "bin/wallet.wasm"));
  const m = JSON.parse(readFileSync(join(here, "../etc/app.json"), "utf8")) as Record<string, unknown>;
  writeFileSync(join(at, "etc/app.json"), JSON.stringify({ ...m, name: APP, config: { [APP]: { chain: "chain" } }, filters: { outputs: "wallet.outputs", balance: "wallet.balance" } }, null, 2));
  return at;
}
function probeTree(name: string, calls: Record<string, string[]>): string {
  const at = join(trees, name);
  mkdirSync(join(at, "bin"), { recursive: true });
  mkdirSync(join(at, "etc"), { recursive: true });
  copyFileSync(join(SKEIN, "programs/test/perm-probe/bin/perm-probe.wasm"), join(at, "bin/perm-probe.wasm"));
  writeFileSync(join(at, "etc/app.json"), JSON.stringify({
    kind: "app", name, version: "0.1.0", programs: { probe: "bin/perm-probe.wasm" }, provides: [], requires: [], calls,
    routes: [{ address: "", handler: "probe" }], description: "the wallet e2e's filer: skein's perm-probe module",
  }, null, 2));
  return at;
}

const arcade = await FakeArcade.start();
const afters: Array<() => unknown> = [];
const ownerKey = PrivateKey.fromRandom();
const h = await testHost({ after: (f) => afters.push(f) }, { ownerKey, genesis: { defaults: { walletNetwork: "regtest" } }, arc: { url: arcade.url, token: "the-wallet-arcade-token", events: arcade.eventsUrl }, arcRetry: { min: 300, max: 1000 }, rocks: ROCKS_MODE });
let store = "";
try {
  const inst = h.instance("w");
  await h.router.start();
  store = storeSpec(h.db.get("w")!);
  const k = async () => (await h.router.hydrate("w")).kernel;
  const record = async (name: string) => {
    const kk = await k();
    const root = await kk.call("head", name) as import("multiformats/cid").CID | null;
    return root ? await kk.store.get(root) as Record<string, unknown> : undefined;
  };
  const cli = async (...args: string[]) => {
    const o = await ownerCli({ home: h.home, port: h.router.port!, owner: h.owner, settled: () => h.router.settled() }, args);
    await h.router.settled();
    if (process.env.VERBOSE) for (const l of [...o.out, ...o.err]) process.stdout.write(`  | ${l}\n`);
    return o;
  };

  // ------------------------------------------------ install
  for (const [what, dir] of [["skein-chain 0.10.0", CHAIN_DIR], [`the wallet (as ${APP})`, walletTree()], ["the probe pa", probeTree("pa", { [APP]: ["bsv"] })]] as const) {
    const o = await cli("install", dir, "--instance", "w");
    check(o.code === 0, `install ${what}: exit ${o.code} ${o.err.join(" ")}`);
    if (what === "the probe pa") check(o.out.some((l) => new RegExp(`grant\\s+calls ${APP} as "bsv"`).test(l)), `the install prompt reads pa's call aloud (${o.out.filter((l) => /grant/.test(l)).join(" | ")})`);
  }
  const grants = await record("grants") as { calls?: Record<string, Record<string, string[]>> };
  check(JSON.stringify(grants.calls?.pa) === JSON.stringify({ [APP]: ["bsv"] }), `the grants: pa calls ${APP} as "bsv" (${JSON.stringify(grants.calls)})`);
  const walletProg = ((await record(`${APP}/app`))!.programs as Record<string, unknown>).wallet;

  // ------------------------------------------------ the funding, mined in block 1, ingested
  const alice = PrivateKey.fromRandom();
  const fund = new Transaction();
  fund.addInput({ sourceTXID: "72".repeat(32), sourceOutputIndex: 0, unlockingScript: UnlockingScript.fromHex("51"), sequence: 0xffffffff });
  for (let i = 0; i < 3; i++) fund.addOutput({ lockingScript: new P2PKH().lock(alice.toPublicKey().toHash()), satoshis: 10_000 });
  const fundTxid = fund.id("hex");
  fund.merklePath = new MerklePath(1, [[{ offset: 0, hash: fundTxid, txid: true }]]);
  const h1 = mine(sha256d(REGTEST_GENESIS), internal(fundTxid), 1_790_200_000);
  await h.router.chainHeaders("w", "chain", [h1]);
  await h.router.settled();
  const ownerBox = new RawBox(h.owner, `${h.base}/@w`);
  const ingest = async (tx: InstanceType<typeof Transaction>) => { await ownerBox.send(inst, "chain", { fn: "ingest", args: { beef: new Uint8Array(tx.toBEEF()) } }); await h.router.settled(); };
  const facts = async (name: string) => {
    const res = await fetch(`${h.base}/@w/events/${name}`);
    return res.status === 200 ? (await res.json() as Array<{ record: Record<string, unknown> }>).map((x) => x.record) : [];
  };
  const txStatuses = async (txid: string) => (await facts(`chain/tx/${txid}`)).map((r) => String(r.status)).join(",");
  const outStates = async (op: string) => (await facts(`chain/output/${op}`)).map((r) => `${String(r.state)}:${String(r.spentBy).slice(0, 8)}`).join(",");
  await ingest(fund);
  check(await until("fund mined", async () => (await txStatuses(fundTxid)) === "mined" || undefined, 20_000).then(() => true, () => false), `the funding ingested: chain/tx mined (${await txStatuses(fundTxid)})`);

  // ------------------------------------------------ the probe's calls
  const probeOut = async () => {
    const out: Array<Record<string, unknown>> = [];
    for (let rec = await record("pa/out"); rec; rec = rec.prev ? await (await k()).store.get(rec.prev as never) as Record<string, unknown> : undefined) out.unshift(rec);
    return out;
  };
  type Ans = { outpoint?: string; basket?: string; satoshis?: number; state?: string; filed?: boolean };
  const call = async (fn: string, arg: Record<string, unknown>, name?: string) => {
    await ownerBox.send(inst, "pa", { kind: "probe", op: "call", prog: walletProg, fn, ...(name ? { name } : {}), arg });
    await h.router.settled();
    const o = (await probeOut()).at(-1)!;
    return { ok: o.ok === true, error: String(o.error ?? ""), ans: o.answer ? dagCbor.decode(o.answer as Uint8Array) as Ans : {} as Ans };
  };
  const fileArg = (txid: string, vout: number) => ({ outpoint: `${txid}.${vout}`, protocol: [1, "amm pool"], keyID: `${txid}_${vout}`, counterparty: "anyone" });
  const reads = async () => {
    const o = await (await fetch(`${h.base}/@w/${APP}/outputs?basket=bsv`)).json() as { outputs: Array<{ outpoint: string; satoshis: number; protocol: unknown; keyID: string }>; next: unknown };
    const b = await (await fetch(`${h.base}/@w/${APP}/balance?basket=bsv`)).json() as { satoshis: number };
    return { list: o.outputs.map((x) => `${x.outpoint.slice(0, 8)}.${x.outpoint.split(".")[1]}=${x.satoshis}`).join(","), outputs: o.outputs, balance: b.satoshis };
  };
  const bookState = async (txid: string, vout: number) => {
    // The wallet's record, read through the book's head (the outputs map), via the read route's view: list and balance.
    const rec = await record(`${APP}/book`);
    return rec;
  };

  let r = await call("file", fileArg(fundTxid, 0), "bsv");
  check(r.ok && r.ans.filed === true && r.ans.state === "unspent" && r.ans.satoshis === 10_000 && r.ans.basket === "bsv", `filed by the named call as "bsv": unspent, 10000 (${JSON.stringify(r)})`);
  let v = await reads();
  check(v.balance === 10_000 && v.outputs.length === 1 && v.outputs[0]!.outpoint === `${fundTxid}.0` && JSON.stringify(v.outputs[0]!.protocol) === '[1,"amm pool"]', `/outputs lists it with its derivation, /balance 10000 (${v.list}; ${v.balance})`);
  r = await call("file", fileArg(fundTxid, 0), "bsv");
  check(r.ok && r.ans.filed === false && (await reads()).balance === 10_000, `filed again: no change (${JSON.stringify(r.ans)})`);
  r = await call("file", fileArg(fundTxid, 1), "tokens");
  check(!r.ok && new RegExp(`callAs: pa is not approved to call ${APP} as "tokens"`).test(r.error), `an unapproved basket: refused by the kernel (${r.error})`);
  r = await call("file", fileArg(fundTxid, 1));
  check(!r.ok && /a call without a name files nothing/.test(r.error), `a call with no name: refused by the wallet (${r.error})`);
  r = await call("file", fileArg("ab".repeat(32), 0), "bsv");
  check(!r.ok && /does not hold the transaction/.test(r.error), `a transaction the chain state does not hold: refused (${r.error})`);
  check((await reads()).balance === 10_000, "the refusals changed nothing");

  // ------------------------------------------------ spent, then the spender rejected: rolled back
  const spend = new Transaction();
  spend.addInput({ sourceTransaction: fund, sourceOutputIndex: 0, unlockingScriptTemplate: new P2PKH().unlock(alice), sequence: 0xffffffff });
  spend.addOutput({ lockingScript: new P2PKH().lock(alice.toPublicKey().toHash()), satoshis: 9_000 });
  await spend.sign();
  const spendTxid = spend.id("hex");
  await ingest(spend);
  const op0 = `${fundTxid}.0`;
  check(await until("spent", async () => { await h.router.settled(); return (await reads()).balance === 0 || undefined; }, 20_000).then(() => true, () => false), `a spender ingested: chain/output/${op0.slice(0, 8)}… ${await outStates(op0)}; the tally 0`);
  v = await reads();
  check(v.outputs.length === 0, `spent: off /outputs (${v.list})`);
  arcade.emit(spendTxid, { txStatus: "REJECTED" });
  check(await until("rolled back", async () => { await h.router.settled(); return (await reads()).balance === 10_000 || undefined; }, 20_000).then(() => true, () => false), `the spender rejected (chain/tx ${await txStatuses(spendTxid)}): chain/output ${await outStates(op0)} → unspent again, the tally 10000`);
  v = await reads();
  check(v.outputs.length === 1 && v.outputs[0]!.outpoint === op0, `rolled back: on /outputs again (${v.list})`);

  // ------------------------------------------------ a filed output whose payer is rejected: void
  const pay = new Transaction();
  pay.addInput({ sourceTransaction: fund, sourceOutputIndex: 1, unlockingScriptTemplate: new P2PKH().unlock(alice), sequence: 0xffffffff });
  pay.addOutput({ lockingScript: new P2PKH().lock(alice.toPublicKey().toHash()), satoshis: 7_000 });
  await pay.sign();
  const payTxid = pay.id("hex");
  await ingest(pay);
  r = await call("file", fileArg(payTxid, 0), "bsv");
  check(r.ok && r.ans.state === "unspent" && (await reads()).balance === 17_000, `an unproven payer's output filed: unspent, the tally 17000 (${JSON.stringify(r.ans)}; chain/tx ${await txStatuses(payTxid)})`);
  arcade.emit(payTxid, { txStatus: "REJECTED" });
  check(await until("void", async () => { await h.router.settled(); return (await reads()).balance === 10_000 || undefined; }, 20_000).then(() => true, () => false), `the payer rejected (chain/tx ${await txStatuses(payTxid)}): void, the tally 10000`);
  v = await reads();
  check(v.outputs.length === 1 && v.outputs[0]!.outpoint === op0, `void: off /outputs (${v.list})`);
  const book = await bookState(payTxid, 0);
  check(book?.kind === "wallet-book", `the head ${APP}/book is the book (${String(book?.kind)})`);
} catch (e) {
  check(false, `threw: ${(e as Error).stack}`);
} finally {
  const [removeHome, ...rest] = afters;
  for (const f of rest.reverse()) await f();
  await arcade.close();
  if (store) {
    const rp = spawnSync("node", ["--experimental-strip-types", "--no-warnings", join(SKEIN, "kernel-zig/equiv/replays.ts"), store], { encoding: "utf8", cwd: SKEIN });
    process.stdout.write(rp.stdout);
    if (rp.status !== 0) process.stdout.write(rp.stderr);
    check(rp.status === 0 && /identical .*the source store reproduced exactly/.test(rp.stdout), "the instance's store replays to itself exactly");
  }
  if (!process.env.KEEP) await removeHome?.();
}
process.stdout.write(failures ? `wallet e2e: ${failures} FAILED\n` : "wallet e2e: all ok\n");
process.exit(failures ? 1 : 0);
