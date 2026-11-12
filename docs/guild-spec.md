# Guild mode spec (milestone 3: security level 0)

Scope of milestone 3: the settings line is read from the guild info, a form builds the line for an
officer to paste, a token purchase (commit, nonce, seed) runs between two clients, spins land in the
account, SPIN is sent. No payout, no anchors, no witnesses yet (milestones 4 and 5).

`docs/core-spec.md` stays the reference for hashes, entries and the ledger. This file adds the wire
format and the modules around it. Names, numbers and hex values follow core-spec section 1.

## 1. Modules

| File | Kind | Job |
|---|---|---|
| `Core/Proto.lua` | pure | encode and decode messages |
| `Net/Queue.lua` | pure | send queue with the server's budget |
| `Net/Comm.lua` | WoW | prefix registration, `CHAT_MSG_ADDON`, drives the queue |
| `Game/Guild.lua` | pure | the guild session: accounts, purchase, spin, presence |
| `Guild/Roster.lua` | WoW | guild name, own name, guild info line, officer test, entropy |
| `Main.lua` | WoW | creates the session and connects Comm, Roster, Guild and the UI |
| `UI/OfficerFrame.lua` | WoW | grant tokens, settings form |

Pure files get everything from outside (clock, random text, send function) and are loaded by
`tests/run.lua` like the Core files: `loadfile(path)("GuildSlots", ns)`, exporting `ns.<Name>`.

## 2. Wire format (`Core/Proto.lua`)

One addon message is `version | type | fields…` joined with `|`. The version is the text `1`.
A message is at most 255 bytes and contains no NUL. Prefix `GSLOTS`, channel `GUILD` for every
message of this milestone.

| Type | From | Fields after the type, in order |
|---|---|---|
| `HELLO` | anyone | `version` (addon version, 1..16 bytes of `[0-9A-Za-z.-]`), `n` (own last spin number, 0 if none), `head` (own short head, or `-` without an account) |
| `BUY1` | officer | `buyId` (16 hex), `player` (name), `tokens` (1..1,000,000,000), `commit` (64 hex), `time` (server time, seconds), `lineHash` (8 hex) |
| `BUY2` | player | `buyId` (16 hex), `nonce` (32 hex), `head` (32 hex, short head before the purchase) |
| `BUY3` | officer | `buyId` (16 hex), `seed` (32 hex) |
| `SPIN` | player | `n` (1..2^31), `stake` (1..1,000,000), `level` (0..2), `head` (32 hex, before the spin), `A` (0..10000) |
| `GAM` | player | `n`, `g` (1..5), `amount` (amount at risk, 1..2^53-1), `level`, `head` (32 hex, before the step), `A` |

`lineHash` is the first 8 hex characters of `Sha256.hex(line)`, where `line` is the settings line
as `Settings.find` returns it. It lets the player's client refuse a purchase when both sides read
different guild info texts, because the line goes into the purchase entry and so into the head hash.

```
Proto.encode(type, fields) -> text or nil, code     fields is a table keyed by field name
Proto.decode(text)         -> msg or nil            msg = { type = "BUY1", buyId = …, tokens = 500, … }
Proto.lineHash(line)       -> 8 hex
Proto.VERSION = "1"   Proto.PREFIX = "GSLOTS"   Proto.MAX = 255
```

- Numeric fields are Lua numbers in `fields`/`msg` and canonical decimals on the wire
  (`Engine.dec`; no sign, no leading zeros). `decode(encode(x))` gives `x` back.
- `encode` codes: `bad_type`, `bad_field` (missing, wrong type, out of range), `too_long`.
- `decode` returns nil for anything that is not exactly a known message of version `1`: other
  version, unknown type, wrong field count, malformed field. It never raises, whatever the input.

## 3. Send queue (`Net/Queue.lua`)

The server allows 10 messages per prefix and gives one back per second; result code 0 means
"queued", 3 means throttled, 11 means addon messages are locked (boss fight).

```
Queue.new{ send = function(text, channel, target) -> code, now = function() -> seconds,
           capacity = 10, refill = 1, onDrop = function(text, code) }  -> q
q:push(text, channel, target) -> true or nil, code     code "too_long" (> 255 bytes) or "full" (> 200 waiting)
q:update()                    send what the budget allows, oldest first
q:budget()   -> whole messages that could go out now (0..capacity)
q:pending()  -> number of messages waiting
```

- The queue keeps its own count of the budget: starts at `capacity`, regains `refill` per second of
  `now()`, never above `capacity`. A message goes out only while the count is at least 1.
- Code 0: message done, count - 1. Code 3: keep the message, set the count to 0. Code 11: keep the
  message, try again one second later, count unchanged. Any other code, or an error raised by `send`:
  drop the message and call `onDrop`.
- `push` never sends by itself. Order is first in, first out.

## 4. Transport (`Net/Comm.lua`)

```
Comm.start(onMessage)     registers the prefix, listens to CHAT_MSG_ADDON, updates the queue every frame
                          onMessage(sender, text, channel) for every message with our prefix
Comm.send(text, channel, target) -> true or nil, code     channel defaults to "GUILD"
Comm.budget() -> number
```

- `sender` is passed on as the server delivers it, with one change: a `-Realm` suffix is cut off
  (the roster has names without a realm).
- Sending uses `C_ChatInfo.SendAddonMessage(prefix, text, channel, target)`; its first return value
  is the result code (`Enum.SendAddonMessageResult`: 0 success, 3 throttle, 11 lockdown). A `true`
  or `nil` return (older signature) counts as 0.
- The own GUILD message comes back as an echo. Comm passes it on like any other message; the
  session decides what to do with it.

## 5. Roster (`Guild/Roster.lua`)

```
Roster.guild()        -> guild name or nil
Roster.me()           -> own name as it appears as sender ("First Last"; GetUnitName("player", true), realm cut off)
Roster.line()         -> settings line from GetGuildInfoText() via Settings.find, or nil
Roster.settings()     -> parsed settings of Roster.line(), or nil, code
Roster.isOfficer(name)-> true when the roster lists `name` with rank index <= settings.R (rank 0 = guild leader)
Roster.members()      -> { { name =, rankIndex =, online = }, … } sorted by name
Roster.serverTime()   -> GetServerTime()
Roster.randomHex(n)   -> n hex characters
Roster.onChange(fn)   fn() after GUILD_ROSTER_UPDATE and when the guild info text changed
```

- Roster names can carry `-Realm`; it is cut off. Names are compared byte for byte.
- Without valid settings nobody is an officer.
- `randomHex` must not be plain `math.random`: a seed the player can guess breaks the purchase.
  Keep a pool text in `GuildSlotsDB.pool`; each call hashes
  `pool | counter | GetTime() | debugprofilestop() | GetServerTime() | UnitGUID("player") | four math.random(2^31-1) values`
  with `Sha256.hex`, stores the result as the new pool and returns hex from
  `Sha256.hex("out|" .. pool .. "|" .. counter)` (more blocks for more than 64 characters).

## 6. Session (`Game/Guild.lua`)

```
Guild.new(env) -> session
env = {
  guild, me,                 names
  now       = function() -> server time in seconds (may be fractional in tests),
  randomHex = function(n) -> n hex characters,
  send      = function(text) -> true or nil, code      GUILD message, already queued
  budget    = function() -> messages the queue could send now,
  isOfficer = function(name) -> boolean,
  line      = function() -> settings line of the guild info or nil,
  store     = table that survives sessions (a subtree of GuildSlotsDB),
  version   = addon version text,
  onEvent   = function(name, data)   optional; "account", "purchase", "presence", "notice"
  allowSelf = boolean                optional; an officer may grant tokens to themself (testing)
}
session:onMessage(sender, text)    every GSLOTS message, own echoes included
session:tick()                     call a few times per second: timeouts, HELLO
session:game()      -> game object for the slot window (below)
session:grant(player, tokens) -> buyId or nil, code      officer side
session:purchases() -> list of the purchases this client takes part in, newest first:
                       { buyId, role = "officer"|"player", player, officer, tokens, time,
                         status = "wait_nonce"|"wait_seed"|"done"|"timeout"|"failed", code }
session:online()    -> { { name =, version =, seen = }, … } addon users heard in the last 300 s, sorted by name
session:lastSpin(player) -> { n =, head =, time = } or nil      what this client last heard in SPIN/GAM/HELLO
```

### Storage

```
store.accounts[guild][player] = { entries = { text, text, … } }      the own account, entry text forms
store.purchases = { … }                                              finished and failed purchases of this client (keep the last 100)
store.heard[guild][player] = { n =, head =, time = }                 only kept when the listener is an officer
```

On creation the session replays the own account with `Ledger.replay`. An account that does not
replay is left untouched in the store, the game reports `broken`, and nothing is appended to it.
Every new entry is first applied with `Ledger.apply` and only then appended to the store.

### Purchase

All three messages go to `GUILD`. Each step has 30 seconds (measured with `env.now`).

Officer, `session:grant(player, tokens)`:

1. Refuse with a code: `not_officer` (the own name fails `isOfficer`), `no_settings` (no line, or it
   does not parse), `bad_tokens`, `bad_player` (invalid name; the own name unless `allowSelf`),
   `busy` (a purchase of this officer for the same player is still open), `send` (queue refused).
2. `buyId = randomHex(16)`, `seed = randomHex(32)`, `commit = Engine.commit(seed)`,
   `time = floor(now())`, `line = env.line()`. Send `BUY1`. Status `wait_nonce`.
3. On `BUY2` with this `buyId`, sent by `player`, while in `wait_nonce`: keep nonce and head, send
   `BUY3`, status `done`. Any other `BUY2` is ignored.
4. No `BUY2` within 30 s: status `timeout`. The seed is never sent.

Player, on `BUY1` whose `player` is the own name:

1. Ignore unless the sender is an officer (`isOfficer(sender)`). Ignore a `buyId` already seen
   (store and open purchases).
2. Fail (status `failed`, no reply) with `no_settings` when the own line is missing or invalid,
   `settings_differ` when `Proto.lineHash(own line) ~= lineHash`, `busy` when another purchase is
   open, `broken` when the account does not replay.
3. `nonce = randomHex(32)`. Send `BUY2` with the short head of the account (`Ledger.shortHead`).
   Status `wait_seed`.
4. On `BUY3` with this `buyId` from the same officer: build the entry
   `{ type = "B", buyId, officer = sender of BUY1, tokens, commit, seed, nonce, time (from BUY1), line (own line at BUY1) }`
   and apply it. Success: status `done`, event `account`. A ledger error (e.g. `bad_commit`):
   status `failed` with that code, nothing credited.
5. No `BUY3` within 30 s: status `timeout`, nothing credited.

The own echo of a message this client sent is ignored for that role (the officer ignores their own
`BUY1`/`BUY3`, the player their own `BUY2`). With `allowSelf` one client plays both roles: its
`BUY1` echo starts the player side, its `BUY2` echo continues the officer side, its `BUY3` echo
finishes the player side.

### Spins (level 0)

`session:game()` returns an object with the same shape as `Solo` (`Game/Solo.lua`), so the slot
window can drive both:

```
game.balance, game.stake, game.stakes, game.pending, game.maxGamble, game.cap
game:state()      -> "idle" | "gamble"
game:setStake(v)  -> true or nil, "busy" | "bad_stake"
game:spin()       -> result or nil, code
game:take()       -> { kind = "take", amount, balance } or nil, "no_gamble"
game:gamble()     -> result or nil, code
game:info()       -> same table as Solo's info()
game:status()     -> "ok" | "no_account" | "no_funds" | "level" | "broken"
```

- Rules come from the settings of the last purchase in the account (`state.settings`), not from the
  current guild info. Without a purchase: `balance = 0`, stakes from `Settings.defaults()`,
  `status()` is `no_account`.
- `spin()` codes: `no_account`, `broken`, `level` (the account's level is 1 or 2, not built yet),
  `no_funds`, `wait` (less than 1.5 s since the last spin or gamble step, or `env.budget() < 3`),
  `send`.
- A spin: take an open gamble offer first (as Solo does). Entry
  `{ type = "S", n = state.n + 1, stake, A = 0, status = "ok", contribs = "" }`. Send
  `SPIN` (`level` 0, `head` = short head before the entry, `A` 0); if the send is refused, return
  `send` and change nothing. Then apply and store the entry. The result table has the fields of
  Solo's spin result (`kind`, `stake`, `stops`, `symbols`, `window`, `multiplier`, `win`, `balance`,
  `pending`, `canGamble`, `winReels`, `anticipation`) plus `n`, filled from the `info` that
  `Ledger.apply` returns.
- A gamble step: entry `{ type = "G", n = state.n, g = state.g + 1, A = 0, status = "ok", contribs = "" }`,
  message `GAM` with `amount = state.pending` before the step. Result as Solo's gamble result
  (`kind`, `won`, `step`, `amount`, `pending`, `balance`, `canGamble`).
- `take()` writes no entry: the ledger already holds the win. The session only remembers that the
  offer was declined, so `state()` is `idle` until the next spin. `game.pending` is 0 after a take.
- There is no refill.

### Presence

- `HELLO` goes out on the first `tick()` and then every 120 s plus a random 0..20 s
  (from `randomHex`), with the own last spin number and short head.
- Every valid message from a sender counts as a sign of life; `HELLO` also stores the version.
  `online()` lists senders heard within 300 s, the own name included once the own echo arrived.
- When the listener is an officer, `SPIN`, `GAM` and `HELLO` update `store.heard` for the sender
  (SPIN/GAM: the `n` of the message; the head stored is the one in the message).
- A `HELLO` with a higher version than the own raises the event `notice` with `update` once per
  session. Versions compare numerically per dot-separated part.

### What is ignored

Messages that do not decode, `BUY1`/`BUY3` from a sender who is not an officer, `BUY2`/`BUY3` for an
unknown `buyId`, and a `BUY3` from someone other than the officer of the `BUY1`. None of these
changes any state or produces a reply.

## 7. Tests

- `tests/test_proto.lua`, `tests/test_queue.lua`, `tests/test_guild.lua` run under `tests/run.lua`
  in both bit modes (add the pure files to the runner's load list).
- `test_guild.lua` connects two or three sessions through a fake bus (every sent message is
  delivered to every session, the sender included) with a fake clock, and covers: a full purchase,
  each timeout, a non-officer `BUY1`, a wrong seed in `BUY3`, differing settings lines, a self
  grant with `allowSelf`, spins and gamble steps whose stored account replays with `Ledger.replay`
  to the same balance, the spin interval, restart from the store.
- WoW files are covered by `tests/smoke_ui.lua` with `tests/wowstub.lua`; every Lua file under
  `GuildSlots/` must be listed in the TOC.

## Deviations from the design (milestone 3)

| Topic | Design | Here | Why |
|---|---|---|---|
| Throttling | bundled ChatThrottleLib | own queue (`Net/Queue.lua`) | one prefix, small messages; the budget must be readable for the spin lock anyway |
| `BUY1` | buyId, player, tokens, commit | plus `time` and `lineHash` | the entry stores the officer's time and the settings line; both sides must hash the same text |
| `GAM` | n, step, level, head, A | plus `amount` | the witness value binds the amount at risk (core-spec) |
| Officer test | by rank flags | rank index <= `R` from the settings line | the flag order is unconfirmed in the client; `R` is already in the line |
| Self purchase | not mentioned | allowed only with a test switch | one character can test the whole flow over the GUILD echo |
