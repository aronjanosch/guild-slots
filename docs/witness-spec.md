# Witness spec (milestone 5: security levels 1 and 2)

Scope: at level 1 and 2 a spin or gamble step needs random contributions from other clients
("witnesses"). This file adds the wire messages, the player and witness sides of the session, the
witness log, the checkpoint key a payout carries, and the UI changes.

`docs/follow-spec.md` changes this file (commits, following, alerts, payouts from a followed state);
where both speak, follow-spec wins.

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
| `PAY` (changed) | officer | `reqId`, `payId`, `player`, `amount`, `balanceAfter`, `time`, `head`, `anchors`, **`n`** (0..2^31, the account's spin number at the payout), **`ck`** (16 hex, section 6) |
| `LOG` (changed) | player | `payload` is 1..**220** bytes |

- `who` in `RES`: the first 4 hex characters of each included contribution's value, concatenated in
  the order of the contributions (sorted by name), 0..32 characters; `-` when there are none. A
  witness whose value starts with one of the 4-character groups counts itself as included. (Names do
  not fit: eight names can exceed 255 bytes. `WIT` is public, so the tags reveal nothing.)
- `HELLO`, `PAY.head`, `LOGREQ` and the new `ALERT`: see `docs/follow-spec.md` section 1.

## 2. Witness side (`Game/Guild.lua`)

New in `env` (optional): `witnessWindow` (seconds the player collects, default 1.5).

### Session secret and witness log

```
store.secret           = { S = 32 hex, time = server seconds when created }
store.witness[guild]   = { { player, kind, n, g, amount, head, value, time, res = nil | "in" | "out" | "void_in" | "void_out" }, … }
```

- `S` is created with `randomHex(32)` when missing or older than 14 days (follow-spec section 2:
  at session creation, at most 24 hours). Rows are kept 14 days and
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

Removed; see `docs/follow-spec.md`.

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

**Partial log.** The header is removed; see `docs/follow-spec.md` section 5 (`from` marker).

`Pack.split` takes chunks of **220** bytes by default.

## 6. Checkpoint key and payout size

Checkpoints (`store.checks`, `CSYNC`, the partial-log header, `Ledger.resume`, Verify
`resume`/`checkpoint`) are replaced by `docs/follow-spec.md` sections 3 to 5. What stays:

- When an officer confirms a payout, the replayed state after the payout entry gives

  ```
  ck = first 16 hex of Sha256.hex("GS1|CK|" | n | K | line)
  ```

  with `n` the account's spin number, `K` and `line` the key and the stored settings line of the
  purchase in force (`Engine.dec` for `n`): `Ledger.checkpointKey(n, K, line) -> 16 hex`, which
  hashes the text `"GS1|CK|" .. dec(n) .. "|" .. K .. "|" .. line`. `PAY` carries `n` and `ck`.
- Check 3: `known[id]` may be a number, the anchors number at which that purchase or payout was
  first seen. A purchase or payout whose position (the state's `anchors` after it) differs from
  that number is red `replayed`. `store.seen[guild][player][id]` stores that number from now on
  (`BUY2.anchors + 1`, `PAY.anchors`); an old `true` keeps its meaning.
- Size: at most **600** chunks (payout-spec said 200). A request lives `300 + 1.2 * total` seconds
  on both sides once `total` is known (the player knows it when packing, the officer from the first
  `LOG`); `confirm` is allowed until 30 s before that.

## 7. Audit at a payout

Replaced by alerts; see `docs/follow-spec.md` section 4. Verify's `audit` input stays and gets an
empty list.

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
- **Payout review.** See `docs/follow-spec.md` section 7.
- Texts in enUS and deDE. German terms: Würfler (witness), ungültig (void).

## 9. Tests

- `tests/test_proto.lua`: every new and changed message, limits, round trips.
- `tests/test_pack.lua`: dictionary forms, round trips with mixed levels.
- `tests/test_verify.lua`: `replayed`.
- `tests/test_guild.lua` (fake bus, fake clock): a level-1 spin with three witnesses; the lottery
  with more clients than `Z`; too few witnesses gives a void entry and the stake stays; level 2 with
  and without an officer; a second `SPIN` for the same number with another stake gets no answer; a
  restart with an open request writes a void; gamble steps; the stored account replays with
  `Ledger.replay`; `RES` marks the witness rows; the ticker at level 1. Payouts with a followed
  state: `docs/follow-spec.md` section 8.
- Smoke tests for the windows (`tests/smoke_guild.lua`, `tests/smoke_payout.lua`) at level 1.

## Deviations from the design (milestone 5)

| Topic | Design | Here | Why |
|---|---|---|---|
| `RES` | names of the included witnesses | 4-hex tags of their values | eight names can exceed 255 bytes |
| Repeated request | same answer for the same request | no answer when stake or head changed | a retry with other terms after seeing the result must not get new randomness |
| Open request at restart | not covered | written as void | same reason |
| Log range | since the last payout | see `docs/follow-spec.md` section 5 | |
| `Z` at the witness | from the request | from the witness's own guild info | the witness does not know the player's account |

## Clarifications (core)

Decisions made while building the pure core (sections 1, 5 and 6); the tests pin them. Those about
the removed audit messages, the partial-log header and `Ledger.resume` are gone with them.

- **`ck` text.** `"GS1|CK|" .. dec(n) .. "|" .. K .. "|" .. line` (one bar after `CK`, `K` as 64 hex), exported as `Ledger.checkpointKey`.
- **`LOG` size.** A 220-byte payload fits in 255 bytes while `total` has at most five digits; `seq`/`total` still decode up to 2^31 so a too large log can be refused.
- **Dictionary forms.** `S`/`G` items are used only when the decoder rebuilds the text byte for byte (canonical numbers, `ok`/`void`, contributions `name:16 lowercase hex` with valid names, in any order); everything else stays `=`. A level-0 `void` spin uses `S`.
- **Pack checks.** Pack does not range-check `A` or stakes (the ledger does); a repeated `@` name, an index outside the dictionary, or a value whose first character is above `P` (15) is `bad_pack`.
- **`replayed` everywhere.** A numeric `known[id]` is checked on whole accounts as well; a number equal to the position counts as known, `true` keeps its meaning.
- **Session numbers for now.** `Game/Guild.lua` keeps 200 chunks per request until the session ticket raises it to 600; `Pack.split` already cuts 220 bytes.

## Clarifications (session)

- `store.secret` is created at session creation (follow-spec section 2); a stale one is replaced there.
- Witness rows are also capped at 5000 when a row is added, not only at creation.
- Witness count check: `count` = names in `online()` other than the sender, plus the own name if missing; `A` passes when `2A >= count` and `A <= 2 * count`.
- The witness rate limit counts sent answers per player per whole second (`floor(env.now())`).
- Level 2: a witness answers whatever level its own guild info shows; level 1 needs its own valid settings for `Z`.
- The player caps `A` at 10000 and takes it from `online()` at the moment of the spin.
- A `WIT` counts while `env.now() <= due`; later ones are ignored.
- If the `ok` entry fails the ledger, the session writes `void` with the same contributions, then `void` with none.
- A `RES` refused by the queue is retried on every `tick()`; one that cannot be encoded is dropped.
- `status()` order: `broken`, `payout`, `no_account`, `no_funds`, `few_players` / `no_officer`, `ok`; `collecting` is only a refusal code and a `state()`.
- While collecting: `setStake` gives `busy`, `take` gives `no_gamble`, `gamble`/`spin` give `collecting`.
- While collecting, `requestPayout` gives `busy` and a `BUY1` for the player fails with `busy` (the head must not change under the witness values).
- A level 1/2 spin takes an open gamble offer when it is sent: `game.pending` is 0 while collecting.
- After a void step at `g == G` the ledger keeps `pending`, but `game.pending` is 0 and `state()` is `idle`: no step can follow.
- A restart void raises no `result` event; only `RES` goes out (the UI shows the account as it is).
- Ticker at level 1/2: WIT values are kept only for players whose key is held; the listener's own `WIT` echo counts; any `RES` for the spin ends the record.
