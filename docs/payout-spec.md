# Payout spec (milestone 4)

Scope: a player asks an officer for a payout, the officer's client fetches the account, recalculates
it (`Core/Verify.lua`, checks 1-6 and 8, luck index, look-ahead), the officer confirms or rejects,
the payout lands in the account, clients keep anchors, officers exchange anchors.
`docs/core-spec.md` (entries, ledger, Verify) and `docs/guild-spec.md` (wire format, session) stay
valid; this file extends them. The add-on never moves gold: the officer pays by hand and then
confirms.

## 1. Transport

Every message of this milestone goes to `GUILD` like the others, with the receiver named in a
field. Reasons: addon whispers between two characters are not measured in this client and a whisper
to oneself never arrives, while the GUILD echo is measured and lets one character test the whole
flow. Accounts are not secret (SPIN is public already).

## 2. Messages (`Core/Proto.lua`)

| Type | From | Fields after the type, in order |
|---|---|---|
| `BUY2` (changed) | player | `buyId` (16 hex), `nonce` (32 hex), `head` (**64** hex, full head before the purchase), `anchors` (number of B and P entries before the purchase, 0..2^31) |
| `PAYREQ` | player | `reqId` (16 hex), `officer` (name), `amount` (1..2^53-1), `head` (32 hex, current short head), `count` (number of entries, 1..2^31) |
| `LOGREQ` | officer | `reqId` (16 hex), `player` (name) |
| `LOG` | player | `reqId` (16 hex), `seq` (1..total), `total` (1..2^31; the officer refuses more than 200), `payload` (the rest of the message, 1..200 bytes, may contain `|`) |
| `PAY` | officer | `reqId` (16 hex), `payId` (16 hex), `player` (name), `amount`, `balanceAfter` (0..2^53-1), `time` (server seconds), `head` (32 hex, short head after the payout entry), `anchors` (B and P entries including this one) |
| `REJECT` | officer | `reqId` (16 hex), `player` (name), `reason` (`declined`, `mismatch`, `expired`, `busy`, `too_large`, `bad_log`) |
| `OSYNC` | officer | `player` (name), `anchors` (1..2^31), `head` (32 hex), `time` (server seconds of the anchored entry) |

`LOG` is the one message whose last field is free text: `decode` splits off the first five fields
and takes everything after the fifth `|` as `payload` (bytes 1..255 except NUL; newline allowed).

## 3. Packing an account (`Core/Pack.lua`, pure)

```
Pack.encode(entries)        -> text         entries = entry text forms in order
Pack.decode(text)           -> entries or nil, code
Pack.split(text, size)      -> { chunk, … }  size defaults to 200 bytes
```

The packed text is a list of items separated by newline (`\n`). Item forms:

- `=<entry text>`: one entry, verbatim.
- `s<stake>` or `s<stake>*<count>`: `count` consecutive spin entries `S|n|<stake>|0|ok|` (level-0
  form), numbered on from the last spin number seen (`n + 1`, `n + 2`, …; before any spin `n = 0`).
- `g` or `g*<count>`: `count` consecutive gamble entries `G|n|g|0|ok|` for the current spin `n`,
  with `g` continuing from the last step of that spin (1 after a spin).

`encode` uses the short forms exactly for entries whose text equals the form above with the
expected number, and `=` for everything else (purchases, payouts, void entries, entries with
contributions, any entry out of sequence). `count` is at least 2 when written. `decode(encode(x))`
returns `x` for every list of valid entry texts; `decode` returns nil for malformed input and never
raises. A raw `=S|…` or `=G|…` item sets the running `n` and `g` from its fields.

## 4. Session (`Game/Guild.lua`)

New in `env`: `stepBudget` (entries to verify per `tick()`, default 150).

```
session:requestPayout(officer, amount) -> reqId or nil, code     player side
session:payout()      -> nil or { reqId, officer, amount, status, sent, total, code }   the player's current/last request
session:requests()    -> officer side, newest first: { reqId, player, amount, time, status, received, total, progress, report, code }
session:confirm(reqId) -> payId or nil, code
session:reject(reqId, reason) -> true or nil, code
session:anchor(player) -> { anchors, head, time, by } or nil
```

Player status: `wait_officer` (PAYREQ sent), `sending` (LOG chunks going out), `wait_decision`,
`paid`, `rejected`, `expired`, `failed`. Officer status: `fetching` (LOGREQ sent, chunks arriving),
`checking` (Verify running), `ready` (report available), `paid`, `rejected`, `expired`, `failed`.

### Player

1. `requestPayout` refuses with `no_account`, `broken`, `bad_amount` (not 1..balance), `bad_officer`
   (not an officer by `env.isOfficer`; the own name unless `allowSelf`), `busy` (a request is open or
   a purchase is open), `send`. An open gamble offer is taken first. Sends `PAYREQ`.
2. While a request is open (`wait_officer`, `sending`, `wait_decision`) the game is locked:
   `spin()` and `gamble()` return `payout`, `game:status()` returns `payout`. Purchases addressed to
   the player are refused with `busy`.
3. On `LOGREQ` with the open `reqId` from the chosen officer: pack the whole account, split it into
   chunks of 200 bytes, send them as `LOG` 1..total (status `sending`, then `wait_decision`). More
   than 200 chunks: status `failed`, code `too_large`, nothing sent. A refused send keeps the chunk
   for the next `tick()`; `sent`/`total` show progress.
4. On `PAY` with the open `reqId` from the chosen officer: build
   `{ type = "P", payId, officer = sender, amount, balanceAfter, time }`, apply it. Success and the
   short head equals `PAY.head`: status `paid`, event `account`. Otherwise status `failed` with the
   ledger code or `head_mismatch`, and the account stays as it was.
5. On `REJECT` with the open `reqId` from the chosen officer: status `rejected`, `code = reason`.
6. No `PAY`/`REJECT` within 300 s of the request: status `expired`. The lock ends.

### Officer

1. On `PAYREQ` naming the own name as officer, from any sender, when the own name is an officer:
   refuse with `REJECT` `busy` when a request of that player is already open here; else store the
   request and send `LOGREQ` (status `fetching`). With `allowSelf` the own echo counts.
2. Collect `LOG` chunks for the `reqId` from that player. When all `total` chunks are there:
   `Pack.decode`; failure → `REJECT bad_log`, status `failed`. Then run `Verify.run` in a coroutine,
   resumed in `tick()` with `stepBudget` entries per tick (`onStep` yields); `progress` is the share
   done. Verify input: `amount` from the request; `anchor` = `session:anchor(player)`; `known` = ids
   in `store.seen` for that player; `heard` = `store.heard` for that player; `isOfficer(name)` from
   `env.isOfficer` (time ignored). Status `ready` with `report`.
   The request's `head`/`count` must match the fetched account (short head, number of entries),
   else `REJECT mismatch`, status `failed`.
3. `confirm(reqId)`: only in `ready` and before the request is 270 s old (`expired` otherwise, with
   a `REJECT expired`); refuses with `amount_too_high` when the amount exceeds the report's balance
   and with `no_replay` when the replay failed (the officer can still pay by hand, the add-on just
   cannot write a payout it cannot calculate). `payId = randomHex(16)`, `time = floor(now())`,
   `balanceAfter = balance - amount`; applies the payout entry to a copy of the replayed state to get
   the head after; sends `PAY`; status `paid`; stores the anchor and the id. Everything else
   (including a red report) does not block: the officer decides.
4. `reject(reqId, reason)`: sends `REJECT`, status `rejected`.
5. Requests older than 300 s without a decision become `expired`. Finished requests stay listed
   (last 50, in `store.requests`, without the account text).

### Anchors and first-hand knowledge

- Every client that hears a complete purchase (`BUY1` from an officer, `BUY2` from that player,
  `BUY3` from the same officer with a seed matching the commit) computes the entry text with its own
  settings line (only when `Proto.lineHash(own line)` equals the `lineHash` of `BUY1`), the head
  after it (`Sha256.hex(head | text)`) and stores
  `store.anchors[guild][player] = { anchors = BUY2.anchors + 1, head = short head, time, by = officer }`
  when `anchors` is higher than the stored one. It also stores `store.seen[guild][player][buyId] = true`.
- Every client that hears `PAY` from an officer stores the anchor from its `anchors`/`head`/`time`
  the same way and `seen[payId]`.
- The officer who issued a purchase or payout stores both as well (from the own messages).
- `OSYNC`: an officer's client, 20 s after its first `tick()` as an officer, sends one `OSYNC` per
  player whose stored anchor it authored (`by` = own name), newest first, at most 30. A client
  accepts an `OSYNC` from a sender who is an officer when `anchors` is higher than what it has
  (stored with `by` = sender).
- A `BUY3` without a seen `BUY2`, or a seed that does not match, stores nothing.

### Storage additions

```
store.anchors[guild][player] = { anchors, head, time, by }
store.seen[guild][player]    = { [buyId or payId] = true }
store.requests               = finished payout requests of this client (last 50)
store.payout[guild][player]  = the player's last own request (see Clarifications)
```

## 5. Tests

`tests/test_pack.lua`, additions to `tests/test_proto.lua` and `tests/test_guild.lua` (fake bus,
two or three sessions): a full payout between player and officer with a third client that ends up
with the same anchor; partial payout then spins then a second payout (anchor check green); the
player hiding a payout (replaying an older account copy) gives red `anchor_mismatch`; lock during a
request; expiry on both sides; reject; `mismatch` when the account changed between `PAYREQ` and
`LOG`; `too_large`; chunk loss (never complete → expiry); verification spread over ticks; self
payout with `allowSelf`; anchors from purchases heard by a third client; `OSYNC` to a client that was
offline; the stored account after `PAY` replays with `Ledger.replay` to `balanceAfter`.

## Clarifications

Rules fixed after the first implementation; the tests in `tests/test_guild.lua` pin them.

- **Request survives a reload.** The player's last request is kept in
  `store.payout[guild][player] = { reqId, officer, amount, time, status, code, sent, total, head, count }`
  (`head`/`count`: short head and number of entries at the request; no account text). A new session
  restores it: an open request locks the game again and still answers `LOGREQ` and accepts
  `PAY`/`REJECT`; a request restored in `sending` sends all chunks again (the officer ignores chunks it
  already has; if the rebuilt account no longer gives the same number of chunks, status `failed`,
  code `mismatch`). The record stays until a new request replaces it.
- **Late PAY.** After the 300 s the status is `expired` and the lock ends, but a `PAY` for that last
  request is still accepted. It only succeeds while the account is unchanged since the request: after
  further spins the entry fails with the ledger code (usually `bad_balance`) or `head_mismatch`, and the
  account stays as it was. A `PAY` for an older request than the last one is ignored.
- **Amount.** The player applies a `PAY` only when `amount` equals the requested amount and `player`
  is the own name; otherwise status `failed`, code `amount_mismatch`, account unchanged.
- **Size limits.** `Pack.MAX_ENTRIES = 100000` is the default limit of `Pack.decode(text, limit)`; the
  officer decodes with `limit = count`. A `PAYREQ` with `count` above `Pack.MAX_ENTRIES`, or a first
  `LOG` announcing `total > 200`, gets `REJECT too_large` and the request ends `failed`/`too_large`
  (that is the reading of the `too_large` reason). A log that unpacks to more than `count` entries is
  `mismatch`; any other unpack failure is `bad_log`.
- **Head check.** `count` is compared right after unpacking, `head` after the replay and only when the
  replay succeeded; a failed replay gives a red report and `confirm` refuses with `no_replay`.
- **`live` in `store.heard`.** `HELLO` carries the head after the last entry, check 4 needs the head
  before entry `n` (step `g`). So `store.heard[guild][player]` also holds `live = { n, g, head }` from
  the last `SPIN`/`GAM` (a `HELLO` keeps it), and Verify's `heard` is `live`.
- **Order of codes.** `requestPayout`: `broken`, `no_account`, `bad_amount`, `bad_officer`, `busy`,
  `send` (a broken account has no state, so `broken` comes first). The open gamble offer is taken only
  after the queue accepted `PAYREQ`. `game:status()`: `broken`, then `payout`, then the milestone-3
  codes. `confirm`: `unknown`, `not_ready`, `expired`, `no_replay`, `amount_too_high`, a ledger code,
  `send`. `reject`: `bad_reason`, `unknown`, `send`.

## Deviations from the design (milestone 4)

| Topic | Design | Here | Why |
|---|---|---|---|
| Channel | PAYREQ, LOGREQ, LOG, REJECT, OSYNC by whisper; LOG on its own prefix, compressed | all on GUILD, one prefix, run-length packing | whispers unmeasured, self-whisper impossible; packing needs no client API and is testable |
| Log range | entries since the last payout | the whole account | a partial replay needs the state at the cut (key, settings, numbers); packed spins cost about 1.5 bytes |
| BUY2 | short head | full head and the anchor count | listeners can then compute the anchor after the purchase |
| PAY | payId, player, amount, balance after, head, number | plus `reqId` and `time` | binds the payout to the request; the entry stores the officer's time |
| OSYNC | own purchases and payouts since a time, plus anchors | newest own anchor per player | the anchor is what check 1 needs; unknown ids only turn yellow |
| Request lifetime | 30 s per step | 300 s per request, game locked meanwhile | the officer has to look at the report and pay by hand |

## Known limits of version 1

Officers are trusted in version 1 (design, section 13). These follow from that and stay open:

- An officer can publish a wrong anchor (`PAY` or `OSYNC` with a high `anchors` value). Only a
  higher anchor replaces a stored one, so that player's check 1 then stays red on every client.
- A checking officer whose newest anchor is older than a later payout does not notice when the
  player hides that payout. `OSYNC` narrows this, it does not close it.
- With the self-test switch an officer can grant tokens to and pay out themself. The switch is
  for testing with one character and should be removed or clearly marked before a release.
