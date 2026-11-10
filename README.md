# skein-wallet

The wallet, a skein app (name `wallet`, 0.1.1). It keeps the record of every output an instance owns:
BSV outputs and token outputs alike. It knows nothing about tokens. It never builds or signs a
transaction. It has no spend route and no "mark spent" call, and it emits no events about coins: its
records are its own state, under the head `wallet/book`.

Why it exists: fee collection for an exchange operator. It answers which outputs are ours, which are
spent, and what is still unspent (a list and a satoshi balance per basket). Collecting is not built.
A later collector is an app that holds the basket's name and the signer's protocol grant, and builds
its transaction itself.

## Filing (in-VM, the named call)

Another app files an output inside its own step:

```
callAs(<the wallet's program CID>, "file", "<basket>", dag-cbor {
  outpoint: "<txid>.<vout>",                 txid display hex
  protocol: [<level 0..2>, "<protocol name>"],
  keyID: "<key id>",
  counterparty: "self" | "anyone" | "<66-hex key>"
})
→ dag-cbor {outpoint, basket, satoshis, state: "unspent" | "spent" | "void", filed: true | false}
```

- **The basket is the name the kernel checked** (the call input's top-level `as`, skein's call
  permissions). A call with no name is refused. The wallet never learns who called. Baskets are opaque
  names: none is hard-coded here.
- **The caller must declare the call** in its manifest: `"calls": {"wallet": ["<basket>"]}`, approved
  by root at install. The wallet itself declares no `calls` and no `services`.
- **The program CID** is in `wallet/app` → `programs.wallet`.
- **The transaction must be held by the chain state** (head `<chain>/state`). The caller ingests it at
  the chain app earlier in the same step, and a step sees its own head moves. The satoshis are read
  from the held transaction, not from the caller.
- **Not checked against the script.** The basket permission is the whole safeguard, as for a BRC-100
  basket insertion.
- **Idempotent on the outpoint.** Filing the same output again in the same basket changes nothing
  (`filed: false`). Filing it in another basket is refused.
- **What happens at filing:**
  1. The output's state is read once (below).
  2. The wallet subscribes (`on`) to `<chain>/output/<txid>.<vout>`, stepping fn `output`.
  3. It also subscribes to `<chain>/tx/<txid>`, stepping fn `tx`.
- **Errors** are the call's error, a plain message: `file: a call without a name files nothing …`,
  `file: the chain state does not hold the transaction …`, `file: the transaction has no such output`,
  `file: the output is filed in another basket`, or `file: <arg problem>`. What a caller does with a
  refusal is the caller's own business.

## States (read, never derived)

| state | when |
|---|---|
| `void` | the PAYING transaction's status is `rejected`: the output does not exist |
| `spent` | else, the latest `<chain>/output/<txid>.<vout>` says `spent`; its `spentBy` is kept on the record |
| `unspent` | else (no message, or `rolledBack`) |

On every wake, the handler reads the current state and sets the record from it. Nothing is deleted,
and there are no deltas. So the walk-backs follow:
- `rolledBack` → unspent again;
- the payer `mined`, `seen` or `pending` after `rejected` → out of void.

The payer's status comes from the latest `<chain>/tx/<txid>` fact. When there is none yet, it comes
from the chain state's own reading. That happens in the caller's ingest step, because a step does not
see its own emits.

**David to review:** the three-state index (unspent / spent / void) and the tally over unspent only
are the coordinator's reading of "the balance must reflect rejection". The event-then-chain-state
order for the payer's status is the builder's call.

## Records and maps

Each output has one record: `{kind: "wallet-output", txid, vout, protocol: [level, name], keyID,
counterparty, basket, satoshis, state, spentBy?}`.

The maps (MST, skein-sdk `chain.store`), named by `{kind: "wallet-book", outputs, index, tallies}`:

| map | key | value |
|---|---|---|
| `outputs` | txid ‖ vout | the record's CID |
| `index` | len ‖ basket ‖ state byte ‖ outpoint | null |
| `tallies` | len ‖ basket | satoshis of the basket's unspent outputs (running) |

## Reads (open, no step, nothing logged)

These are read routes: filters with no handler and no `kernel.brc104`.

- `GET /wallet/outputs?basket=<name>&after=<txid>.<vout>&limit=<1..1000, default 100>` →
  `{basket, outputs: [{outpoint, satoshis, protocol: [level, name], keyID, counterparty}], next}`.
  The basket's unspent outputs in outpoint order. `next` is the cursor, or null.
- `GET /wallet/balance?basket=<name>` → `{basket, satoshis}`.

## Configuration

`config.wallet.chain` is the chain app's installed name (default `chain`). The wallet reads
`<chain>/state`, `<chain>/tx/…` and `<chain>/output/…`, and its manifest requires `chain/1`.

## Build

```
zig build                  → zig-out/bin/wallet.wasm
zig build bin              bin/wallet.wasm (committed)
zig build test             the book and the call's pure parts, natively
zig build -Dapp=<name>     the same code installed under another name (its heads <name>/…)
```

- It depends on skein-sdk v0.21.0, pinned by tag (`chain`, and `sk` for `sk.asName`). It is built
  the way skein-chain is built.
- Its skein imports are input, get, put, putblock, keep, head, advance, take, error, edges, on and
  events.
- `-Dapp` is for tests only (skein before 0.7.0 reserved the name `wallet`). `bin/wallet.wasm` is
  always `wallet`.

## End to end (test/e2e.ts)

It needs a skein checkout at v0.7.0 with its kernel built and `npm ci` run, and skein-chain v0.11.0.
The app is installed as `wallet`:

```
SKEIN_DIR=<skein at v0.7.0> SKEIN_CHAIN_DIR=<skein-chain at v0.11.0> \
WALLET_WASM=bin/wallet.wasm [SKEIN_EQUIV_STORE=rocksdb] \
  node --experimental-strip-types --no-warnings test/e2e.ts
```

`WALLET_APP=<name>`, with a module built as `-Dapp=<name>`, installs it under another name.

## Needs from skein

- **The named call** (`callAs` and `as` in the call input): skein 0.7.0.
- **The name `wallet`:** free since skein 0.7.0.
- **The chain app's `chain/tx` and `chain/output` facts:** skein-chain 0.11.0.
