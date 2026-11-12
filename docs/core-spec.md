# Core spec (milestone 1)

Byte-exact rules for everything under `GuildSlots/Core/`. The design document describes the game and
the protocol; this file pins down what the design leaves open, so that two independent implementations
produce the same hashes. Where this file and the design differ, the difference is listed in
[Deviations from the design](#deviations-from-the-design).

Core code is pure Lua 5.1 plus the `bit` library. It never touches the WoW API, the clock or
`math.random`: times, random bytes, names and guild data are passed in.

## 1. Conventions

- All hash inputs are ASCII/UTF-8 **text**. Binary values (hashes, seeds, nonces, witness values) are
  always handled as **lowercase hex text**, also when they are hashed again or used as an HMAC key.
  Raw bytes appear in exactly one place: reading the HMAC output `R` in section 5.
- `a | b | c` below means the texts joined with the single character `|`.
- Numbers in text are decimal integers without sign, leading zeros or decimals (`0`, `57`, `1000`).
- Names (players, officers, witnesses, guild) are used byte for byte as the server delivers them.
  No case folding, no trimming. A name is valid when it is 1..48 bytes and contains none of
  `|` `,` `:` `;` and no byte below 32. Names are compared and sorted by byte value
  (plain `<` on Lua strings under the C locale).
- `hex(n)` = n random bytes written as 2n hex characters. Core never generates them.
- Limits: stake 1..1,000,000; tokens per purchase 1..1,000,000,000; payout amount ≥ 1;
  balance always < 2^53; spin numbers 1..2^31.

Sizes: seed, nonce, session secret `S`: 32 hex chars. Purchase id, payout id: 16 hex chars.
Commit, `K`, full head hash: 64 hex chars. Head hash on the wire and in anchors: first 32 hex chars
("short head"). Witness value: 16 hex chars.

## 2. Loading and module layout

Every Core file starts with `local _, ns = ...` and attaches one table to `ns`
(`ns.Sha256`, `ns.Tables`, `ns.Settings`, `ns.Engine`, `ns.Ledger`, `ns.Verify`). Files are loaded in
that order; a file may use the modules before it. `tests/run.lua` loads them the same way the game does.

Functions report bad input as `nil, code` (code = short lowercase text such as `"bad_stake"`), never
by raising, unless stated otherwise. Programming errors (wrong argument type) may raise.

## 3. `Core/Sha256.lua`

```
Sha256.hex(msg)        -> 64 hex chars
Sha256.raw(msg)        -> 32-byte string
Sha256.hmac(key, msg)  -> 64 hex chars      HMAC-SHA256 (RFC 2104), block size 64
Sha256.hmacRaw(key, msg) -> 32-byte string
Sha256.keyed(key)      -> function(msg, raw) -> hex (or 32-byte string when raw is true)
                          same result as hmac/hmacRaw, with the two key blocks hashed once
Sha256.toHex(bytes)    -> hex text
Sha256.fromHex(hex)    -> bytes, or nil when hex is not an even number of [0-9a-f]
```

Constraints from the target client: `bit` returns **unsigned** values there and signed ones under
LuaJIT, so every result is normalised (`% 2^32`). Only `band`, `bor`, `bxor`, `bnot`, `lshift`,
`rshift` exist (no `ror`, `rol`, `tobit`, `tohex`, `bswap`). `string.format("%x")` must not see
values ≥ 2^31. The probe's `probe/GuildSlotsProbe/Sha256.lua` is correct and is the starting point.
Speed matters (about 270 µs per block in the client today): avoid per-block allocations and
function calls in the inner loop where that is cheap to do.

## 4. `Core/Tables.lua` and `Core/Settings.lua`

### Tables

Table `T1`: all three reels use this 34-stop strip, stop 0 first:

```
K,S,G,K,T,S,K,W,G,S,K,M,T,K,S,G,W,K,S,D,G,K,T,S,K,G,M,S,K,W,T,G,K,S
```

| Symbol | Pair (reels 1 and 2 equal, reel 3 different) | Triple |
|---|---|---|
| K | 1 | 5 |
| S | 2 | 10 |
| G | 3 | 15 |
| T | 5 | 30 |
| W | 10 | 60 |
| M | 20 | 150 |
| D | 50 | 500 |

```
Tables.get(id)                     -> table or nil     { id, reels = {strip, strip, strip}, pair = {...}, triple = {...} }
Tables.symbols(tbl, s1, s2, s3)    -> sym1, sym2, sym3 stops are 0-based
Tables.multiplier(tbl, s1, s2, s3) -> integer
Tables.window(tbl, reel, stop)     -> above, centre, below   neighbours wrap around the strip
Tables.win(tbl, stake, cap, s1, s2, s3) -> integer     min(stake * multiplier, cap); cap 0 = no cap
Tables.stats(tbl, stake, cap)      -> { rtp, hit, variance, combos }   cached per (id, stake, cap)
```

`stats` enumerates all stop combinations. It describes the **effective multiplier** `win / stake`,
so a cap lowers `rtp` and `variance`. Without a cap, T1 gives rtp 4594/4913 (0.935070…),
hit 0.198962…, variance 22.057864…, combos 39304.

### Settings

The guild settings are one line of the guild info text:

```
GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000
```

| Field | Meaning | Valid | Default |
|---|---|---|---|
| L | security level | 0, 1, 2 | 0 |
| W | witnesses needed at level 1 | 1..5 | 2 |
| R | highest rank index that counts as officer | 0..9 | 1 |
| E | allowed stakes | 1..5 distinct integers, each 1..1,000,000 | 10,50,100 |
| G | maximum gamble steps, 0 = off | 0..5 | 3 |
| C | maximum win per spin, 0 = none | 0..1,000,000,000 | 0 |
| T | table id | a known table | T1 |
| X | tokens per gold, display only | 1..1,000,000,000 | 1000 |

```
Settings.find(infoText) -> line or nil    first line that, after trimming spaces/tabs/CR, starts with "GSLOTS1;" or equals "GSLOTS1"
Settings.parse(line)    -> settings or nil, code
Settings.format(settings) -> canonical line, all fields in the order above
Settings.defaults()     -> settings
```

`settings` = `{ L, W, R, E = {..ascending..}, G, C, T, X, Z }` with `Z = 2*W + 3`.
The line is at most 120 bytes and must not contain `|` or a byte below 32. Fields are separated by
`;`, each `key=value`. Missing fields take the default, unknown keys are ignored, a repeated key or
an invalid value makes the whole line invalid. A purchase stores the trimmed line exactly as found
(not the canonical form), and `parse` of that stored text decides the rules.

## 5. `Core/Engine.lua`

```
commit        = Sha256.hex(seed)
K             = Sha256.hex("GS1|K" | buyId | seed | nonce)
witnessValue  = first 16 hex chars of Sha256.hmac(S, player | kind | n | g | amount | head)
lot           = first 8 hex chars of Sha256.hex(witness | player | kind | n | g), read as a number 0..2^32-1
```

- `kind` is `spin` or `gam`. `n` is the spin number, `g` the gamble step (`0` for a spin).
- `amount` is the stake for a spin and the amount at risk for a gamble step. `head` is the player's
  short head before the entry. Both come from the SPIN/GAM message, so a witness value belongs to
  exactly one request.
- HMAC keys are the hex texts themselves (`S` 32 chars, `K` 64 chars).

**Lottery (level 1).** With `A` = number of addon users the player reports and `Z = 2W + 3`:
a witness is drawn when `A <= Z` or `lot < floor(Z * 2^32 / A)`. `A` is 1..10000.
At level 2 there is no lottery (`A` is written as `0`), at level 0 there are no witnesses (`A` = `0`).

**Contributions.** `contribs` is the text `name:value,name:value,…` sorted by name, without
duplicates; empty text when there are none. At most 8 contributions count. When more valid ones
arrive in time, the 8 with the lowest lot are kept (ties: smaller name first).

**Spin.**

```
R     = Sha256.hmacRaw(K, "spin" | n | contribs)
stop1 = uint32be(R[1..4])  mod #reel1
stop2 = uint32be(R[5..8])  mod #reel2
stop3 = uint32be(R[9..12]) mod #reel3
```

**Gamble step.**

```
R   = Sha256.hmacRaw(K, "gam" | n | g | contribs)
won = R[1] < 128
```

```
Engine.commit(seed)                         -> hex
Engine.purchaseKey(buyId, seed, nonce)      -> K
Engine.witnessValue(S, player, kind, n, g, amount, head) -> 16 hex
Engine.lot(witness, player, kind, n, g)     -> number
Engine.drawn(lot, A, Z)                     -> boolean
Engine.contribs(list)                       -> text    list = { {name=, value=, lot=}, ... }, applies sort and the limit of 8
Engine.parseContribs(text)                  -> { {name=, value=}, ... } or nil, code   rejects unsorted/duplicate/malformed
Engine.spin(K, n, contribs, tbl)            -> stop1, stop2, stop3
Engine.gamble(K, n, g, contribs)            -> boolean
```

`Engine.spin`/`Engine.gamble` accept either `K` text or a function from `Sha256.keyed(K)`.

## 6. `Core/Ledger.lua`

An account is the list of entries of one player in one guild. It is never restarted: after a payout
down to zero the same chain continues.

### Text forms

| Entry | Text form |
|---|---|
| purchase | `B` \| buyId \| officer \| tokens \| commit \| seed \| nonce \| time \| settingsLine |
| spin | `S` \| n \| stake \| A \| status \| contribs |
| gamble step | `G` \| n \| g \| A \| status \| contribs |
| payout | `P` \| payId \| officer \| amount \| balanceAfter \| time |

`status` is `ok` or `void`. `time` is server time in seconds, taken from the message of the officer
(BUY1 / PAY carry it), never from the local clock. Results, wins and balances are not stored.

As Lua tables: `{ type = "B", buyId, officer, tokens, commit, seed, nonce, time, line }`,
`{ type = "S", n, stake, A, status, contribs }`, `{ type = "G", n, g, A, status, contribs }`,
`{ type = "P", payId, officer, amount, balanceAfter, time }` (numbers as Lua numbers, the rest text).

### Head hash

```
h0 = Sha256.hex("GS1|KONTO" | guild | player)
hi = Sha256.hex(h(i-1) | text(entry i))
```

The chain uses the full 64-char value; messages and anchors carry the first 32 chars.

### State and rules

`state` after replaying entries 1..i:

```
{ guild, player, head (64 hex), count (entries applied), anchors (number of B and P entries),
  balance, n (last spin number, 0 at start), g (last gamble step of spin n, 0 if none),
  pending (amount a gamble step would risk, 0 when no gamble is possible),
  K, keyed (Sha256.keyed(K)), settings, line, tbl, buyIds = {set}, payIds = {set} }
```

Rules, checked in this order; the first violation gives the code:

- Any entry: well-formed fields and limits (`bad_entry`).
- Before the first purchase only a purchase is allowed (`no_purchase`).
- **Purchase.** `commit == Sha256.hex(seed)` (`bad_commit`); buyId not used before in this account
  (`dup_buy`); the line parses (`bad_settings`). Then balance += tokens, `K`, settings and table
  switch to this purchase, pending = 0.
- **Spin.** `n == state.n + 1` (`bad_number`); stake is in `E` (`bad_stake`); `A` and contributions fit
  the level (`bad_contribs`, see below). With status `ok`: balance >= stake (`no_funds`); stops from
  `Engine.spin`; win = `Tables.win`; balance = balance - stake + win; pending = win if gambling is
  possible (`G > 0`, win > 0, and `C == 0` or `2 * win <= C`), else 0. With status `void`: balance
  unchanged, pending = 0. In both cases state.n = n, state.g = 0.
- **Gamble step.** `n == state.n`, `g == state.g + 1`, `g <= G`, pending > 0 (`bad_gamble`);
  contributions fit the level (`bad_contribs`). With `ok`: if won, balance += pending, then
  `p = 2 * pending` (the amount now at risk) and pending = p, except pending = 0 when `g == G` or
  when `C > 0` and `2 * p > C`; if lost, balance -= pending and pending = 0. With `void`: nothing changes except state.g = g.
- **Payout.** payId not used before (`dup_pay`); 1 <= amount <= balance (`no_funds`);
  balanceAfter == balance - amount (`bad_balance`). Then balance = balanceAfter, pending = 0.

Contributions per level (`L` from the settings of the last purchase), for status `ok`:

- Level 0: `A == 0`, `contribs` empty. `void` is not allowed at level 0.
- Level 1: `A` 1..10000; W..8 contributions; none from the player; each contributor drawn by the
  lottery for this `A`.
- Level 2: `A == 0`; 1..8 contributions; none from the player. Whether a contributor was an officer
  is checked by Verify, which knows the roster.

For status `void` at level 1 and 2 the same shape rules apply, except that fewer contributions than
needed are allowed (that is the normal reason for a void).

```
Ledger.encode(entry)            -> text
Ledger.decode(text)             -> entry or nil, code
Ledger.start(guild, player)     -> state
Ledger.apply(state, entry)      -> info or nil, code     mutates state only on success
Ledger.copy(state)              -> state                 a checkpoint
Ledger.shortHead(state)         -> 32 hex
Ledger.replay(guild, player, entries [, onStep]) -> state or nil, code, index
```

`info` from `apply` tells the caller what happened, so the UI and Verify need no second calculation:
`{ type, stops = {s1,s2,s3}, multiplier, win, won (gamble), balance, pending, head }` (fields that
apply to the entry type). `onStep(i)` is called after every entry so a caller can yield from a coroutine.

## 7. `Core/Verify.lua`

Recalculates an account for a payout and reports findings. It blocks nothing.

```
Verify.run(input) -> report
```

`input`:

```
{ guild, player, entries,
  amount,                         -- requested payout
  anchor   = { anchors = <number of B and P entries>, head = <short head after that entry> } or nil,
  known    = { [buyId or payId] = true },   -- purchases and payouts the checking officer saw first-hand or got from their author
  heard    = { n =, g =, head = <short head before that entry> } or nil,  -- last SPIN/GAM heard live
  isOfficer = function(name, time) -> true/false/nil,   -- nil = unknown
  audit    = { { kind=, n=, g=, witness=, value= or nil, answered = true/false }, ... } or nil,
  onStep   = function(i) end }
```

`report`:

```
{ findings = { { check = 1..8, level = "red"|"yellow", code =, index = entry index or nil }, ... },
  light = "green"|"yellow"|"red",          -- worst finding
  balance, state,                           -- from the replay, nil when the replay failed
  luck = { spins, steps, maxWin, total = { z, light, enough }, timing = { z, light, enough } or nil,
           risk = { z, light, enough } or nil },
  lookahead = { count = 20, sum, expected } or nil,   -- level 0 only
  unconfirmed = number of ok spins/steps with a contribution nobody confirmed }
```

Checks (numbers as in the design, section 10):

1. **Anchor.** The account has at least `anchor.anchors` B/P entries and the short head after that
   entry matches. Else red `anchor_mismatch`. No anchor given: yellow `no_anchor`.
2. **Purchases.** Commit, unique id (from the replay) and `isOfficer(officer, time)`: false is red
   `not_officer`, nil is yellow `officer_unknown`.
3. **Known.** A purchase or payout not in `known`: yellow `not_seen` when the anchor covers it,
   red `unconfirmed` when it lies after the anchor or there is no anchor.
4. **Chain.** `heard` must lie on the chain: the short head before spin `heard.n` (step `heard.g`)
   equals `heard.head`, else red `rewritten`. If `heard.n` is beyond the account: yellow `incomplete`.
5. **Spins** and 6. **Replay.** Any `Ledger.apply` failure is red with the ledger's code and the
   entry index; the replay stops there. At level 2, a contributor for whom `isOfficer` is false is
   red `witness_not_officer`.
7. **Audit.** For each audit row: `value` differs from the contribution in the account: red
   `witness_mismatch`. `answered` but not included in an `ok` entry: yellow `omitted`. A `void`
   entry for which at least the needed number of witnesses answered: yellow `void_with_answers`.
8. **Amount.** `amount` > balance: red `amount_too_high`.

**Luck index** over the `ok` spins since the last payout (all spins when there is none). For spin
`i`: stake `e`, effective multiplier `m = win / e`, and `mu`, `var` from
`Tables.stats(tbl, e, C)` of the settings in force at that spin.

```
total  = sum(e * (m - mu)) / sqrt(sum(e^2 * var))
timing = sum((e - ebar) * (m - mu)) / sqrt(sum((e - ebar)^2 * var))      ebar = mean stake; nil when all stakes are equal
risk   = (won - steps / 2) / sqrt(steps / 4)                             over ok gamble steps; nil without steps
```

Light per value: below 2 green, below 3 yellow, else red; only upward deviations count.
`enough` is false below 30 spins (risk: below 10 steps); the light is then green and the UI shows
"too little data". Luck lights do not change `report.light`.

**Look-ahead** (level 0 only): the multipliers of spins `state.n + 1 .. state.n + 20` with the
current `K` and empty contributions; `sum` and `expected = 20 * rtp` (uncapped).

## 8. Tests

`luajit tests/run.lua` and `luajit tests/run.lua --unsigned` must both pass.

- SHA-256 and HMAC: FIPS/RFC 4231 vectors plus the length boundaries 55, 56, 63, 64, 119, 120 and
  bytes ≥ 0x80.
- `tests/vectors.lua` is generated by the independent Python reference `tools/ref/` from this spec.
  Engine and Ledger must reproduce every value in it.
- Table statistics as in section 4.
- One fixed account with a known final balance and head.
- One manipulated account per check of section 7.

## Clarifications

Readings fixed after the Lua implementation and the Python reference were compared. The vectors
pin all of them.

- `a | b` always inserts the `|`, also after a literal: `K` hashes `GS1|K|<buyId>|<seed>|<nonce>`,
  `h0` hashes `GS1|KONTO|<guild>|<player>`, `hi` hashes `<h(i-1), 64 hex>|<text>`.
- Empty contributions leave a trailing `|`: `spin|5|`, `gam|5|1|`, entry text `S|1|10|0|ok|`.
- `lot` takes the witness **name**. For a gamble step it uses kind `gam` with that step's `n` and `g`.
- Numbers have at most 16 digits and must be below 2^53. Decoding is canonical:
  `encode(decode(text)) == text`.
- `decode` rejects malformed, unsorted or duplicate contributions, `g = 0`, payout amount 0 and a
  settings line outside 1..120 bytes with `bad_entry`. More than 8 contributions is `bad_contribs`
  in `apply`. Whether the settings line parses is `bad_settings`, after `bad_commit` and `dup_buy`.
- `n` and `g` carry across purchases; a purchase only resets pending. Purchase ids and payout ids
  are separate sets.
- A void gamble step advances `g` and nothing else, so a step beyond `G` is `bad_gamble`. A void spin
  still needs a stake from `E`; the balance is not checked. The level shape rules (range of `A`, no
  contribution from the player, lottery) apply to void entries too; only the minimum count is waived.
- Limit of 8 contributions: sort by (lot, name), take 8, sort by name. `Engine.contribs` keeps one
  entry per name (lowest lot).
- `info.head` from `Ledger.apply` is the full 64-char head. `Ledger.replay` accepts entries as
  tables or as text forms.
- `Tables.window`: above = stop - 1, below = stop + 1, both wrapping.
- Settings: an empty segment (`;;`, trailing `;`) and a repeated key (known or unknown) make the
  line invalid.

## Deviations from the design

Decided for milestone 1; to be confirmed and carried back into the design document.

| Topic | Design | Here | Why |
|---|---|---|---|
| Witness value | `HMAC(S, player, kind, n, g)` | also binds amount and head | a repeated request with another stake must not get the same value |
| Lottery | `lot mod A < Z` | `lot < Z * 2^32 / A` | with `mod`, each reported `A` reshuffles who is drawn; the player picks `A` |
| `A` | only in SPIN/GAM | stored in the entry | the lottery must be checkable from the account |
| Contributions | all that arrive | at most 8, lowest lots | RES must fit 255 bytes |
| Entry text | field lists | type tag, fixed order, time in the entry and on the wire | spin and gamble entries had the same shape |
| Names | compared case-insensitively | byte for byte | names are hashed; `string.lower` is ASCII-only |
| Account end | archived at balance 0, new account | chain continues | a restart makes "newest anchor" ambiguous |
| Unknown purchase after the anchor | yellow | red `unconfirmed` | an anchor only proves what came before it |
| Luck index | fixed mu and variance | per stake and cap | a cap changes both |
| Settings parser | under `Guild/` | `Core/Settings.lua` (pure); reading the guild info stays in `Guild/` | the replay needs it |
