# Witness spec (milestone 5: security levels 1 and 2)

Scope: at level 1 and 2 a spin or gamble step needs random contributions from other clients
("witnesses"). This file adds the wire messages, the player and witness sides of the session, the
witness log, the audit at a payout (Verify check 7), a payout that transfers the account from a
checkpoint instead of from the start, and the UI changes.

`docs/core-spec.md` already fixes and tests the pure parts: `Engine.witnessValue`, `Engine.lot`,
`Engine.drawn`, `Engine.contribs`, the entry forms with `A`, `status` and `contribs`, the ledger's
contribution rules per level, and Verify's check 7 input (`audit` rows). `docs/guild-spec.md` and
`docs/payout-spec.md` stay valid where this file does not change them. Level 0 behaves exactly as
before.

Terms: **player** = the client that spins. **Witness** = another guild member's client that
answers. **Level** = `L` of the settings of the player's last purchase (the account's level), not
the current guild info.

## 1. Messages (`Core/Proto.lua`)

All on `GUILD`, prefix `GSLOTS`, like every other message.

| Type | From | Fields after the type, in order |
|---|---|---|
| `WIT` | witness | `player` (name), `kind` (`spin` or `gam`), `n` (1..2^31), `g` (0..5; 0 for a spin), `value` (16 hex) |
| `RES` | player | `kind`, `n`, `g`, `status` (`ok` or `void`), `who` (see below), `head` (32 hex, short head after the entry) |
| `AUD` | officer | `reqId` (16 hex), `witness` (name), `player` (name), `from` (0..2^31, lowest spin number of interest), `items` (see below, or `-`) |
| `AUDR` | witness | `reqId` (16 hex), `player` (name), `items` (see below, or `-`) |
| `CSYNC` | officer | `player` (name), `anchors` (1..2^31), `head` (32 hex), `balance` (0..2^53-1), `n` (0..2^31), `ck` (16 hex), `time` (server seconds) |
| `LOGREQ` (changed) | officer | `reqId`, `player`, **`from`** (0..2^31: the `anchors` number of the checkpoint the officer holds, 0 = whole account) |
| `PAY` (changed) | officer | `reqId`, `payId`, `player`, `amount`, `balanceAfter`, `time`, `head`, `anchors`, **`n`** (0..2^31, the account's spin number at the payout), **`ck`** (16 hex, section 6) |
| `LOG` (changed) | player | `payload` is 1..**220** bytes |

- `who` in `RES`: the first 4 hex characters of each included contribution's value, concatenated in
  the order of the contributions (sorted by name), 0..32 characters; `-` when there are none. A
  witness whose value starts with one of the 4-character groups counts itself as included. (Names do
  not fit: eight names can exceed 255 bytes. `WIT` is public, so the tags reveal nothing.)
- `items` in `AUD`: up to 8 items joined with `,`. An item is `s<n>` (spin) or `g<n>.<g>` (gamble
  step). Canonical decimals.
- `items` in `AUDR`: up to 8 items joined with `,`. An item is `<AUD item>=<value 16 hex><flag>` or
  `<AUD item>=-` (no record). `flag` is `+` (the witness saw a `RES` that included it), `-` (saw a
  `RES` that did not include it) or `?` (saw no `RES`).
- `decode` checks the item grammar and returns `items` as the text (the session parses it with
  `Proto.auditItems(text) -> { { kind =, n =, g =, value =, flag = }, … }` or nil; `value`/`flag`
  are nil for an `AUD` list; `-` gives an empty list).

## 2. Witness side (`Game/Guild.lua`)

New in `env` (all optional): `witnessWindow` (seconds the player collects, default 1.5),
`auditWindow` (seconds the officer waits for `AUDR`, default 12), `auditMax` (witnesses asked per
payout, default 6).

### Session secret and witness log

```
store.secret           = { S = 32 hex, time = server seconds when created }
store.witness[guild]   = { { player, kind, n, g, amount, head, value, time, res = nil | "in" | "out" | "void_in" | "void_out" }, … }
```

- `S` is created with `randomHex(32)` when missing or older than 14 days. Rows are kept 14 days and
  at most 5000 per guild (oldest dropped); the cleanup runs at session creation.
- A row is identified by `(player, kind, n, g)`.

### Answering `SPIN` / `GAM`

On a `SPIN` or `GAM` of another member (never the own echo) with `level` 1 or 2:

1. Level 2: answer only when the own name is an officer (`env.isOfficer(me)`). `A` is not looked at.
2. Level 1: `A` must be 1..10000 and not less than half or more than double the own count, where
   the own count is the number of names in `online()` other than the sender, the own name always
   included. Then `Engine.drawn(Engine.lot(me, player, kind, n, g), A, Z)` must hold, with `Z` from
   the **current guild info** settings (`2W + 3`); without valid settings: no answer.
3. `env.budget() >= 3`, and at most 2 answers per player per second (`env.now()`).
4. Look up the row. A row with the same `amount` and `head`: send the stored `value` again. A row
   with another `amount` or `head`: **no answer** (a second request for the same number with other
   terms is a retry after seeing the result). No row: `value = Engine.witnessValue(S, player, kind,
   n, g, amount, head)`, store the row.
5. Send `WIT`. `amount` is `stake` for a `SPIN` and `amount` for a `GAM`.

### Hearing `RES`

On a `RES` of another member with a stored row for `(sender, kind, n, g)`: set `res` to `in`/`out`
(status `ok`) or `void_in`/`void_out` (status `void`), by whether the first 4 characters of the own
value appear as one of the 4-character groups of `who`. The first `RES` for a row wins.

### Answering `AUD`

On an `AUD` whose `witness` is the own name, sent by an officer, at most 5 per sender per minute:
send one `AUDR` with the same `reqId` and `player`. Its items, at most 8 in total:

1. One item per `AUD` item, in order: `=<value><flag>` from the row (`+` for `in`/`void_in`, `-` for
   `out`/`void_out`, `?` without `res`), or `=-` without a row.
2. Then, while there is room: rows of that player with `n >= from` and `res` of `out`, `void_in` or
   `void_out` that the `AUD` did not name, newest first.

## 3. Player side (`Game/Guild.lua`)

At level 0 `game:spin()` and `game:gamble()` stay synchronous. At level 1 and 2 they return at once
with `{ kind = "wait", what = "spin" | "gamble", n =, g =, due = <env.now() at the end of the window> }`
and the result arrives later through `env.onEvent("result", result)`.

`game:status()` gains, after the existing codes: `few_players` (level 1: fewer than `W` other addon
users in `online()`), `no_officer` (level 2: no officer other than the own name in `online()`).
`spin()`/`gamble()` refuse with the same codes, with `wait` (interval **2.5 s** at level 1 and 2,
budget below 3), and with `collecting` while a request is open. The code `level` no longer occurs.
`game:state()` is `collecting` while a request is open. `game.level` holds the account's level
(0 without an account).

A spin at level 1 or 2:

1. Checks as at level 0. `A` = number of names in `online()` other than the own name at level 1
   (at least `W`, see above), `0` at level 2. An open gamble offer is taken first.
2. Store the open request before sending:
   `store.open[guild][player] = { kind, n, g, stake, amount, A, head, time }` (`head` = short head
   before the entry). Send `SPIN` (`level` = the account's level, `A`). A refused send removes the
   record and returns `send`.
3. Until `due`: collect `WIT` messages with the own name as `player` and the same `kind`, `n`, `g`
   from senders other than the own name. Level 1: the sender must be drawn
   (`Engine.drawn(Engine.lot(sender, me, kind, n, g), A, Z)`, `Z` from the account's settings).
   Level 2: the sender must be an officer. The first value of a sender counts.
4. At the first `tick()` at or after `due`: `contribs = Engine.contribs(list)` (it applies the limit
   of 8). Needed: `W` at level 1, 1 at level 2. With enough contributions the entry has status
   `ok`, otherwise `void` (with the contributions that did arrive). Apply and store the entry,
   remove the open record, send `RES`, raise `result`.
5. The `result` event carries the same table a level-0 spin returns (guild-spec section 6), or for a
   void `{ kind = "void", what = "spin", n, need, got, balance }`. The stake is not charged for a void.

A gamble step works the same way with `kind = "gam"`, `amount = state.pending`; its result is the
level-0 gamble result or `{ kind = "void", what = "gamble", n, g, need, got, balance, pending }`.
After a void step the offer stays open as far as the ledger allows (`state.pending`, `g <= G`); the
player can try again or take.

**Restart with an open request.** When a session is created and `store.open` holds a request whose
`head` equals the account's current short head, the entry is written as `void` with empty
contributions, and `RES` goes out on the first `tick()`. A record with another head is dropped.
(Asking again after a reload would let a modified client look at the result first.)

The spin lock during a payout request, the purchase rules and everything else stay as they are.

## 4. Guild ticker at level 1 and 2

A listener that holds the key of a player (guild-spec, "Guild ticker") keeps the `WIT` values it
hears for the newest `SPIN` of each player (`level` 1 or 2; at most 16 values, dropped after 10 s).
On that player's `RES` with `kind = spin`, status `ok`: when every 4-character group of `who`
matches exactly one kept value, the contributions text is built from those senders and values, the
round is recalculated with it and announced under the level-0 rules and limits. Otherwise nothing
happens.

## 5. Packing (`Core/Pack.lua`)

New item forms next to the existing ones (`=`, `s`, `g`):

- `@<name>`: adds a name to the dictionary of this packed text; the first gets index 1.
- `S<stake>|<A>|<o or v>|<list>`: a spin entry numbered `n + 1`, status `ok` (`o`) or `void` (`v`).
  `<list>` is `<value64><index>` joined with `,` in the entry's order; empty for no contributions.
  `<value64>` is the 16-hex value as exactly 11 characters of the alphabet `A-Z a-z 0-9 - _`
  (values 0..63 in that order): the 64 bits big-endian, 6 bits per character, the first character
  holding the top 4 bits. `<index>` is the decimal dictionary index.
- `G<A>|<o or v>|<list>`: a gamble entry for the current `n` with step `g + 1`.

`encode` uses these for spin and gamble entries that are in sequence and are not the level-0 form;
a name gets its `@` item right before the first item that uses it. `decode(encode(x)) == x` still
holds for every list of valid entry texts.

**Header for a partial log.** `Pack.encode(entries, header)` with
`header = { head = <64 hex>, n = <number>, payout = <P entry text>, purchase = <B entry text> }`
writes three lines before the items: `^<head>|<n>`, the payout text, the purchase text.
`Pack.decode(text, limit)` returns `entries, header` (`header` nil for a whole account). The
running `n` of the short forms starts at the header's `n`, `g` at 0.

`Pack.split` takes chunks of **220** bytes by default.

## 6. Checkpoints: a payout from the last payout on

An account never restarts, and entries with contributions cost 30 to 150 bytes each. So the officer
asks only for what came after the last payout it can vouch for.

### The checkpoint

When an officer confirms a payout, the replayed state after the payout entry gives

```
ck = first 16 hex of Sha256.hex("GS1|CK|" | n | K | line)
```

with `n` the account's spin number, `K` and `line` the key and the stored settings line of the
purchase in force (`Engine.dec` for `n`). `PAY` carries `n` and `ck`. Every client that stores the
anchor of a `PAY` (payout-spec, "Anchors") also stores

```
store.checks[guild][player] = { anchors, head, balance = balanceAfter, n, ck, time, by }
```

when `anchors` is higher than the stored one. `CSYNC`: with the `OSYNC` round an officer's client
also sends one `CSYNC` per stored checkpoint it authored (`by` = own name), newest first, at most
30; a client accepts a `CSYNC` from an officer when its `anchors` is higher than what it has.

### Asking and sending

- Officer: `LOGREQ.from` = `anchors` of the stored checkpoint for that player, or 0.
- Player, on `LOGREQ` with `from > 0`: when the own account's entry number `from` among the B and P
  entries is a payout, send a partial log: header `head` = full head **before** that payout entry,
  `n` = spin number at that point, `payout` = that entry's text, `purchase` = the text of the
  purchase in force at that point; then the entries after the payout. In every other case
  (`from = 0`, no such entry, not a payout) send the whole account.
- `PAYREQ.count` stays the number of entries of the whole account, `PAYREQ.head` the current short
  head.
- Transport: `LOG` chunks are spread over three prefixes, `GSLOTS`, `GSLOTS2` and `GSLOTS3`
  (round robin, each with its own send queue and budget, since the server counts per prefix).
  The extra prefixes carry nothing but `LOG`; a receiver treats a `LOG` the same whatever prefix
  brought it. `Comm.LOG_PREFIXES` is the list, so a client that gets disconnected under this load
  can be cut back to one.
- Size: at most **600** chunks (payout-spec said 200). A request lives `300 + 1.2 * total` seconds
  on both sides (with three prefixes the transfer itself takes about `total / 3` seconds) once `total` is known (the player knows it when packing, the officer from the first
  `LOG`); `confirm` is allowed until 30 s before that.

### Resuming the ledger (`Core/Ledger.lua`)

```
Ledger.resume(guild, player, cp) -> state or nil, code
cp = { head = <64 hex, before the payout>, n, payout = <P text>, purchase = <B text>, anchors = <count after the payout>, count = <entries before the suffix> or nil }
```

Decodes both texts (`bad_entry`), checks the purchase's commit (`bad_commit`) and settings line
(`bad_settings`), and returns the state right after the payout: `head = Sha256.hex(cp.head | payout
text)`, `balance = balanceAfter`, `n = cp.n`, `g = 0`, `pending = 0`, key, settings and table from
the purchase, `anchors = cp.anchors`, `count = cp.count or 0`, `payIds` holding the payout's id,
`buyIds` holding the purchase's id. Entries are then applied with `Ledger.apply` as usual.

### Verify with a checkpoint (`Core/Verify.lua`)

New input: `resume = <header from Pack.decode>` and `checkpoint = <stored checkpoint>`; `entries`
is then the suffix.

- `checkpoint` missing while `resume` is given, or `Ledger.resume` fails, or the short head after
  the payout differs from `checkpoint.head`, or the payout's `balanceAfter` differs from
  `checkpoint.balance`, or `resume.n` differs from `checkpoint.n`, or `ck` recomputed from
  `resume.n` and the purchase differs from `checkpoint.ck`: red `checkpoint_mismatch` (check 1), the
  replay does not run, `balance` and `state` are nil.
- Otherwise the replay starts from the resumed state. Entry indexes in findings count within the
  suffix. Check 1 (anchor) and the other checks work on the resumed state as before; an `anchor`
  equal to the checkpoint itself is satisfied by the header.
- Check 3 gains: `known[id]` may be a number, the anchors number at which that purchase or payout
  was first seen. A purchase or payout in the suffix whose position (the state's `anchors` after it)
  differs from that number is red `replayed`. `store.seen[guild][player][id]` stores that number
  from now on (`BUY2.anchors + 1`, `PAY.anchors`); an old `true` keeps its meaning.
- Check 4: a `heard` at or before the checkpoint's `n` is not checked.
- The purchase of the header counts as known for check 2 and 3 (the checkpoint vouches for it).

### Session (`Game/Guild.lua`)

The officer decodes the log; with a header it passes `resume` and the stored checkpoint to Verify.
`PAYREQ.count` is compared with `header count + suffix length` only for a whole account; for a
partial log the head check after the replay (`PAYREQ.head`) is the binding one. `confirm` computes
`n` and `ck` from the state after the payout entry and stores the checkpoint itself.

## 7. Audit at a payout (Verify check 7)

After the log is decoded and before Verify runs, when the account (or suffix) holds contributions:

1. Count contributions per witness name over the entries. Take the witnesses that are in `online()`
   and are not the player, most contributions first (ties by name), at most `auditMax`.
2. Send each one `AUD`: `from` = the spin number of the first entry in the log (the header's `n + 1`
   for a partial log, 1 otherwise), `items` = that witness's 8 newest contributions in the log.
   Status `auditing`.
3. Collect `AUDR` with the `reqId` from those witnesses until all answered or `auditWindow` passed.
   Each item becomes an audit row `{ kind, n, g, witness = sender, value, answered }`: for an item
   the `AUD` named, `value` as answered (nil for `=-`) and `answered = false`; for an item the
   witness added, `value` and `answered = true`.
4. Run Verify with `audit = rows`. Without contributions or without witnesses online the audit is
   skipped and `audit` is an empty list.

The report's `unconfirmed` is shown to the officer. Request status order on the officer side:
`fetching`, `auditing`, `checking`, `ready`.

## 8. UI

- **Slot window.** A `wait` result starts the round with the reels running; the stop sequence
  begins when the `result` event arrives (no extra delay when it is already there). A void result
  stops the reels on the symbols they showed before the spin, shows a notice ("Spin void: too few
  witnesses, stake kept"; at level 2 "No officer answered, stake kept") and books nothing. A gamble
  step keeps the card face down until its result arrives; a void step shows the notice and leaves
  the card open. Autoplay continues after a void spin. Closing the window while a request is open
  does not cancel it: the session finishes it, and the result is shown as settled on the next open.
- **Status line.** `few_players`: "Too few players online (need W)". `no_officer`: "Waiting for an
  officer". The spin button is disabled in both.
- **Officer window, settings form.** Level 1 and 2 can be chosen; `W` is editable at level 1. The
  note that says they are not built goes away. The self-test switch gets the label "Test only".
- **Payout review.** Status `auditing` ("Asking witnesses…"). New finding texts:
  `witness_mismatch`, `omitted`, `void_with_answers`, `witness_not_officer`, `checkpoint_mismatch`,
  `replayed`. A line "Unconfirmed spins: N" when the account has contributions.
- Texts in enUS and deDE. German terms: Würfler (witness), ungültig (void).

## 9. Tests

- `tests/test_proto.lua`: every new and changed message, item grammar, limits, round trips.
- `tests/test_pack.lua`: dictionary forms, header, round trips with mixed levels.
- `tests/test_core.lua` or a new file: `Ledger.resume`, Verify with a checkpoint (green, each
  mismatch, `replayed`).
- `tests/test_guild.lua` (fake bus, fake clock): a level-1 spin with three witnesses; the lottery
  with more clients than `Z`; too few witnesses gives a void entry and the stake stays; level 2 with
  and without an officer; a second `SPIN` for the same number with another stake gets no answer; a
  restart with an open request writes a void; gamble steps; the stored account replays with
  `Ledger.replay`; `RES` marks the witness rows; a payout at level 1 with the audit (green; a
  witness reporting another value gives `witness_mismatch`; an omitted contribution gives
  `omitted`; a void with enough answers gives `void_with_answers`); a second payout that transfers
  only the suffix and ends green; a wrong checkpoint; `CSYNC` to a client that was offline; the
  ticker at level 1.
- Smoke tests for the windows (`tests/smoke_guild.lua`, `tests/smoke_payout.lua`) at level 1.

## Deviations from the design (milestone 5)

| Topic | Design | Here | Why |
|---|---|---|---|
| `RES` | names of the included witnesses | 4-hex tags of their values | eight names can exceed 255 bytes |
| Repeated request | same answer for the same request | no answer when stake or head changed | a retry with other terms after seeing the result must not get new randomness |
| Open request at restart | not covered | written as void | same reason |
| `AUD` / `AUDR` | whisper, list per witness | GUILD, 8 items, the witness adds what `RES` left out | whisper unmeasured; one message per witness keeps the budget |
| Log range | since the last payout | since the last payout the officer holds a checkpoint for, else all | the cut needs a state both sides agree on; `PAY` now carries it |
| `Z` at the witness | from the request | from the witness's own guild info | the witness does not know the player's account |
