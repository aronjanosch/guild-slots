# Follow spec (milestone 5, part 2: everyone witnesses, everyone follows)

Decision of 2026-11-13: the guild runs either **open** (level 0) or **witnessed** (level 1). In the
witnessed mode every addon client, officers included, contributes randomness, commits to its
secret beforehand, and recalculates every spin it hears. One honest client online during a spin is
enough to make the result unpredictable and to notice manipulation. Officer clients keep the
checked state of every account, so a payout needs no transfer when the officer was listening.

This file changes `docs/witness-spec.md`. Where both speak, this file wins:

| witness-spec | Now |
|---|---|
| Section 1: `AUD`, `AUDR`, `CSYNC` | removed (also `Proto.auditItems`) |
| Section 1: `LOGREQ.from` as an anchors number | `from` is an entry count, plus `head` (below) |
| Section 2, "Answering AUD" | removed |
| Section 5, header for a partial log | removed (`Pack.encode(entries)`, `Pack.decode` returns entries only); the dictionary forms stay |
| Section 6, checkpoints (`store.checks`, `CSYNC`, header, `Ledger.resume`, Verify `resume`/`checkpoint`, `checkpoint_mismatch`, three prefixes) | replaced by sections 3 to 5 here. `PAY.n`, `PAY.ck`, `Ledger.checkpointKey`, the numeric `known[id]` with `replayed`, 600 chunks and the lifetime `300 + 1.2 * total` stay |
| Section 7, audit round | replaced by alerts (section 4 here) |
| Level 2 | still valid in the core and the session; the settings form no longer offers it |

Sections 2 (witness side without AUD), 3 (player side) and 4 (ticker) of witness-spec stay.

## 1. Messages (`Core/Proto.lua`)

| Type | From | Fields after the type, in order |
|---|---|---|
| `HELLO` (changed) | anyone | `version`, `n`, `head`, **`commit`** (32 hex), **`reveal`** (32 hex, or `-`) |
| `PAY` (changed) | officer | `reqId`, `payId`, `player`, `amount`, `balanceAfter`, `time`, **`head` (64 hex, full head after the payout entry)**, `anchors`, `n`, `ck` |
| `LOGREQ` (changed) | officer | `reqId`, `player`, `from` (0..2^31, number of entries the officer already holds; 0 = whole account), `head` (32 hex short head after entry `from`, or `-` when `from` is 0) |
| `ALERT` | anyone | `reqId` (16 hex), `player` (name), `code` (below), `n` (0..2^31), `g` (0..5), `time` (server seconds) |

`ALERT` codes: `rewritten`, `bad_entry`, `bad_res`, `omitted`, `bad_value`.

## 2. Witness commit

```
Engine.witnessCommit(S) = first 32 hex of Sha256.hex("GS1|WC|" | S)
```

- The secret `S` now lives at most 24 hours: at session creation a secret older than that is
  replaced, and the old one moves to `store.secret.prev` (`{ S, time }`, kept 14 days).
  `store.secret` is created at session creation (not on the first answer), because `HELLO` carries
  its commit.
- Every `HELLO` carries `commit` = commit of the current secret and `reveal` = the previous secret,
  or `-`.
- Each client keeps for every other sender the commit of its latest `HELLO`
  (`store.commits[guild][name] = { commit, time }`).
- **Player:** a `WIT` counts only when the sender has a known commit (it sent a `HELLO` this client
  heard). `witnessesOnline` counts only such names.
- **Samples.** Every client keeps a random sample of the `WIT` values it hears from others, to
  check them once the secret is revealed: per `(witness, commit)` a reservoir of 20 rows
  `{ player, kind, n, g, amount, head, value }` (reservoir sampling with `env.randomHex`; the terms
  come from the `SPIN`/`GAM` heard before the `WIT`; a `WIT` without a heard request is not
  sampled). `store.samples[guild][witness] = { commit, seen, rows }`; a new commit of that witness
  starts a new reservoir and keeps the old one as `old` until it is checked or 14 days pass.
- **Check on reveal.** On a `HELLO` whose `reveal` hashes to a commit this client holds samples for:
  recompute each row with `Engine.witnessValue(reveal, …)`. Any difference stores an alert
  `bad_value` for the **player** of that row (with `n`, `g`) and an event `notice` with
  `witness_cheat` and the witness's name. The samples are then dropped.
- What this gives: a witness can no longer pick its value after seeing the others. It can still
  stay silent; that shows in the luck index.

## 3. Following (`Game/Guild.lua`, every client)

Every client recalculates the accounts it can follow and stores the result:

```
store.follow[guild][player] = {
  snap    = <Ledger.snapshot of the checked state>,
  count   = <number of entries of the whole account at that state> or nil,
  lost    = nil or true,                 -- the stream broke; snap is still a true state of the past
  entries = { text, … } or nil,          -- officers only: entries since the base
  base    = <Ledger.snapshot> or nil,    -- officers only: the state the entries start from
}
```

```
Ledger.snapshot(state)                -> plain table (numbers and texts only, safe for SavedVariables)
Ledger.restore(guild, player, snap)   -> state or nil, code
```

`snapshot` holds head, count, anchors, balance, n, g, pending, the text of the purchase in force
and the lists of purchase and payout ids; `restore` rebuilds key, settings and table from the
purchase text. `restore(snapshot(s))` behaves like `s` for every later entry.

**Starting points.** A client starts (or restarts) following a player at:

- a complete purchase it hears whose `BUY2.anchors` is 0: the account starts there
  (`Ledger.start`, then the purchase entry; `count` = 1);
- a `PAY` from an officer, when the client holds the key of that player's last purchase
  (`store.keys`) and `Ledger.checkpointKey(PAY.n, K, line)` equals `PAY.ck`: the state after the
  payout is built from `PAY.head`, `balanceAfter`, `PAY.n`, `PAY.anchors` and that purchase
  (`count` = the `count` of the `PAYREQ` with the same `reqId` plus 1 when it was heard, else nil);
- on an officer's client, a payout check that replayed the account without a red finding of
  checks 1 to 6: the replayed state.

**Steps.** While following (not `lost`):

- Purchase of that player (complete `BUY1`/`BUY2`/`BUY3`): `BUY2.head` must equal the followed full
  head and `BUY2.anchors` the followed anchors; then the entry is applied. A different head is an
  alert `rewritten`; the stream is then `lost`.
- `SPIN`/`GAM` at level 0: `n` (and `g`) must be the next one, else `lost` without an alert (the
  client missed something). The message's short head must equal the followed one, else alert
  `rewritten` and `lost`. The entry (`S|n|stake|0|ok|`, `G|n|g|0|ok|`) is applied; a ledger error
  is an alert `bad_entry` and `lost`.
- `SPIN`/`GAM` at level 1 or 2: same number and head checks; the client keeps the request and the
  `WIT` values it hears for it. On the `RES`: the contributions are rebuilt from the kept values
  whose 4-character tags match `who` (each tag exactly one value, else `lost`, no alert); the entry
  is applied with the status of the `RES` (ledger error: alert `bad_entry`, `lost`); the short head
  after it must equal `RES.head`, else alert `bad_res` and `lost`. A new request before the `RES`
  is `lost`.
- `PAY` from an officer for that player: `PAY.anchors` must be the followed anchors plus 1 and the
  payout entry must apply and give `PAY.head`; else the client restarts from the `PAY` as a starting
  point if it can, or is `lost`.
- `HELLO` of that player: when its `n` equals the followed `n` and the heads differ: alert
  `rewritten`, `lost`. (A higher `n` means missed spins: `lost`, no alert.)
- A witness that answered a request and sees a `RES` with status `ok` or `void` whose `who` lacks
  its tag, although its `WIT` went out at least 0.5 s before the `RES` arrived: alert `omitted`.

`lost` ends at the next starting point. The snapshot of a lost stream is kept: it is still a
checked state of that account.

**Officers** (`env.isOfficer(me)`) also keep `entries` (the entry texts since `base`) for the luck
index. `base` is the state at the last starting point; a followed `PAY` moves `base` to the state
after it and empties `entries`. Above 3000 entries the list is dropped (`entries = nil`); the state
is still followed.

**Load.** At most 8 followed steps per `tick()` are applied; requests wait in a queue per player
(at most 50 per player, more is `lost`). The own account is never followed.

The guild ticker keeps its own path (witness-spec section 4).

## 4. Alerts

```
store.alerts[guild] = { { player, code, n, g, time, by = nil }, … }      own observations, 14 days, at most 200
```

- An alert is stored once per `(player, code, n, g)`.
- On a `PAYREQ` of a player this client holds alerts for (not the own request): after a delay of
  0..3 s (from `randomHex`), with `env.budget() >= 3`, send up to 3 `ALERT` messages, newest first,
  with the `reqId` of the request.
- The officer handling the request collects `ALERT` messages with that `reqId` from any sender
  (and adds its own stored alerts for the player) until it builds the report, at least 4 s after
  the request arrived.
- `Verify.run` gets `alerts = { { by =, code =, n =, g =, time = }, … }`; each distinct `code`
  becomes one yellow finding of check 7 with code `alert_<code>`; the report carries the list as
  `report.alerts`. The existing `audit` input stays and gets an empty list.
- Alerts are claims of one member. They are yellow, name their sender, and block nothing.

## 5. Payout with a followed state

`Verify.run` gets a new input **`start`** = a ledger state the officer trusts (its own). With
`start`, `entries` are the entries after it, the replay begins there, entry indexes in findings
count from the first entry given, the luck index runs over the given entries, and check 4 skips a
`heard` at or before `start.n`. The `resume`/`checkpoint` inputs and `checkpoint_mismatch` go away.

Officer, on `PAYREQ(head, count)` for a player with a follow record:

1. **Nothing missing**: the record's short head equals `PAYREQ.head` (and `count`, when known,
   equals `PAYREQ.count`). No `LOGREQ`. With `entries` and `base`: Verify with `start = base` and
   those entries. Without them: Verify with `start` = the followed state and no entries (no luck
   index; the report says so with `luck = nil`).
2. **Something missing**, `count` known and below `PAYREQ.count`: `LOGREQ` with `from = count` and
   `head` = the record's short head. The player answers with the entries after `from` when its own
   short head after entry `from` equals `head`, otherwise with the whole account (the first `LOG`
   payload then starts as a whole account does; the officer tells the two apart by a first line
   `>` + `from` that a partial log carries before the items, see below). A partial log is verified
   with `start = base` and `entries` = stored entries + received ones when the officer has
   `entries`, else with `start` = the followed state and the received entries.
3. **No record, `count` unknown, or the partial log does not fit**: `LOGREQ` with `from = 0`, the
   whole account, as in payout-spec.

Partial log marker: `Pack.encode(entries, from)` writes a first line `>` followed by the decimal
`from` when `from` is given; `Pack.decode` returns `entries, from` (`from` nil for a whole
account). The running `n` of the short forms cannot be known from a partial log alone, so `decode`
takes it as an argument: `Pack.decode(text, limit, n)` (default 0); the officer passes the followed
state's `n`, the player packs with the same value (`Pack.encode(entries, from, n)`).

After the check: the head after the replay must equal `PAYREQ.head` (else `REJECT mismatch` as
before). A check without red findings of checks 1 to 6 updates the follow record (starting point
3). `confirm` writes the payout, sends `PAY` with the full head, and moves the record to the state
after the payout with `base` there and empty `entries`.

The player's side: `LOGREQ.from > 0` is honoured as described; the player needs the short head
after entry `from`, which it gets by replaying its own account up to there (spread over ticks when
the account is long: at most 500 entries per tick).

## 6. Faster spins: settle early

The player knows who should answer: the names in `online()` with a known commit, other than itself,
that are drawn for this request (all of them when `A <= Z`). The request settles as soon as every
one of them has answered, and at `due` otherwise, but never earlier than 0.3 s after the request
(so the reels have started). The result is the same as waiting.

## 7. UI

Replaces witness-spec section 8 where they differ:

- **Settings form.** Two modes: "Open" (`L=0`) and "Witnessed" (`L=1`, with `W`). A guild info that
  already says `L=2` is shown as it is and keeps working.
- **Slot window.** As witness-spec section 8 (running reels until the result, void notice, status
  line). **Turbo** has no effect on a witnessed account and its button is hidden there; it stays for
  solo and open accounts.
- **Payout review.** No `auditing` status. The report lists the alerts (sender, what, spin number);
  finding texts for `alert_rewritten`, `alert_bad_entry`, `alert_bad_res`, `alert_omitted`,
  `alert_bad_value`, `replayed`, `witness_not_officer`. When the officer's client had followed the
  whole account, a line says "Followed live, nothing transferred".
- **Notice.** `witness_cheat` shows "A witness's revealed secret does not match its answers: <name>".

## 8. Tests

- Core: `Engine.witnessCommit`; `Ledger.snapshot`/`restore` (every later entry behaves the same,
  mid-gamble too); Verify with `start` (green, findings indexed from the first given entry, luck
  over the given entries) and with `alerts`; Pack with the `from` marker and a start `n`; Proto for
  the changed and new messages.
- Session (`tests/test_guild.lua`, fake bus): commit and reveal across a restart with a rotated
  secret; a witness that answers with a value not matching its secret is caught on reveal by a
  sampling client; a `WIT` from a sender without a commit does not count; early settle; following
  from account creation at level 0 and 1 by a third client, state equal to the player's; following
  restarts at a `PAY`; a missed `SPIN` gives `lost` without an alert; a `SPIN` with a changed head
  gives `rewritten`; a `RES` with a wrong head gives `bad_res`; an omitted witness raises
  `omitted`; alerts reach the officer on `PAYREQ` and appear in the report; payout with nothing
  missing sends no `LOGREQ` and is green; payout with a partial log; fallback to the whole account;
  the follow record after `confirm`; an officer's `entries` cap.

## Known limits

- A witness that never logs in again never reveals its secret; its answers stay unchecked.
- After a crash the client's secret of that session is lost (SavedVariables are written at logout),
  so an honest witness can fail to reveal too. An unrevealed commit is therefore not a finding.
- A player with an accomplice among the witnesses gains one choice per spin: the accomplice answers
  or stays silent. The luck index is the counterweight.
- Alerts are unproven claims; a member can raise false ones against a player. They are yellow.
- An officer who never listened gets the whole account, which is slow for a long witnessed account.

## Clarifications (core)

Decisions made while building the pure core (sections 1 to 5); the tests pin them.

- **`LOGREQ` pairs.** `from = 0` goes with `head = -` and `from > 0` with a 32-hex head; any other pair does not encode or decode.
- **`ALERT` fields.** `n` and `g` are not checked against each other (`g` may be 1..5 with any `n`); the five codes are the only ones on the wire, `witness_cheat` is a notice, not an alert.
- **`HELLO.reveal`.** Any 32 lowercase hex or `-`; Proto does not check it against an earlier commit.
- **`from` marker.** `>` + canonical decimal 1..2^31; `>0`, a marker not on the first line, or an empty item after it is `bad_pack`. `Pack.encode(entries, 0, n)` writes no marker (from 0 is the whole account). With no entries the text is the marker line alone.
- **Start `n`.** Used only when the marker is present, on both sides; a whole account always numbers from 0, whatever `n` is passed. A start `n` that is not an integer 0..2^31 is `bad_pack`.
- **Snapshot form.** `{ head, count, anchors, balance, n, g, pending, purchase = B text or nil, buyIds = { id, … }, payIds = { id, … } }`, id lists sorted. A state before any purchase has no `purchase` and restores to a state without settings.
- **State carries its purchase.** `Ledger.apply` of a `B` entry stores its text as `state.purchase`, so `snapshot` needs nothing else.
- **`restore` codes.** A malformed field or id list, a purchase text that is not a `B`, or a purchase whose id is not among `buyIds` is `bad_entry`; then `bad_commit`, `bad_settings` as in `apply`.
- **`start` is not changed.** Verify replays on `Ledger.copy(start)`; `report.state` is that copy.
- **Anchor with `start`.** An anchor with `anchors` at or below `start.anchors` counts as covered (no finding), whatever its head: the start may lie after the anchor's entry, so its head cannot be compared there.
- **Luck with `start`.** The index runs over the given entries and still restarts at a payout among them; with `start` and no entries `report.luck` is nil (the look-ahead is still given).
- **Witness time with `start`.** The `isOfficer` time for level-2 witnesses is nil until the first purchase or payout among the given entries.
- **Alerts.** Rows that are not tables or whose `code` is not one of the five are dropped; one yellow check-7 finding `alert_<code>` (index nil) per distinct code in the order first seen; `report.alerts` is always a list (empty without the input) and is given even when the replay fails.
- **Session for now** (superseded for the secret and `reveal` by "Clarifications (session)"). The secret keeps its 14-day life and is created at session creation; `HELLO.reveal` is `-` until rotation is built; the officer sends `LOGREQ` with `from = 0`, `head = -`; anchors store the first 32 hex of `PAY.head`, and the player compares the full head.

## Clarifications (session)

Decisions made while building sections 2 to 6 in `Game/Guild.lua`; `tests/test_guild.lua` pins them.

- **Secret rotation.** Only at session creation; a session that runs longer than 24 hours keeps its secret. `prev` is dropped 14 days after its own creation time.
- **Known commit.** Only a commit heard in this session counts: for `WIT`, `witnessesOnline`, the expected witnesses of settle-early, and for samples (a witness may have rotated while this client was away; a stale commit would raise a false `witness_cheat`). Commits stored by an earlier session do not count. Effect right after a reload or login: a member counts as a witness again from its next `HELLO` (every 120..140 s, and on its own first tick after a login). That is the same window in which `online()` (in memory, empty after a reload) refills anyway, so spins at level 1 show `few_players` for up to about 140 s after a reload either way; a member seen through other messages in that window simply waits for its `HELLO`.
- **Commit cleanup.** Stored commits older than 14 days are dropped at session creation.
- **Samples.** The own `WIT` values and a `WIT` from the player itself are not sampled; a request heard twice with the same number but other terms samples nothing for it (a late `WIT` could belong to either). A reservoir carries `time` (its creation); current and old reservoirs older than 14 days go at session creation.
- **`witness_cheat`.** One `notice` per reveal, `{ kind = "witness_cheat", name = <witness> }`; every differing row is a `bad_value` alert.
- **Settle early.** The expected names are fixed when the request is sent (level 2: online officers with a known commit); with none expected the request settles at 0.3 s. Settling happens in `tick()`.
- **Queue.** Every followed message (purchase, `SPIN`, `GAM`, `RES`, `PAY`, `HELLO`) waits in one queue in arrival order; only ledger applications count toward the 8 per tick; all of them count toward the 50 per player. `WIT` values are attached at once to the request they belong to.
- **Trust after a restart.** A record loaded from the store raises no `rewritten` until a message matched its head in this session (a payout or purchase may have happened while the client was away); such a mismatch is `lost` without an alert.
- **Purchase start.** The account start is a `BUY2` with `anchors` 0 and the empty account's head. The officer's `base` is then the empty account and `entries` holds the purchase text, so a check over them is a whole-account check.
- **Purchases this client cannot rebuild.** A purchase whose line does not hash like the own, a `BUY3` without a heard `BUY2`, and a watched purchase that expires after its `BUY2` make the stream `lost` without an alert. A purchase heard twice (the issuing officer) is applied once.
- **Level mismatch.** A `SPIN`/`GAM` whose `level` differs from the followed account's level (after the number and head checks passed) is `bad_entry`.
- **`HELLO`.** A lower or higher `n` is `lost` without an alert; while a level 1/2 request is open the `HELLO` is skipped (the `RES` decides).
- **PAY start.** `store.keys[guild][player]` also keeps `purchase` (the purchase entry text). The state built from a `PAY` holds only that purchase's id and the payout's id in `buyIds`/`payIds`, and `g = 0`.
- **Duplicate ids after a PAY start (accepted).** Because of the above, the ledger's `dup_buy`/`dup_pay` checks on a followed state started from a `PAY` (and on a payout check that starts there) only know those two ids. This stays as it is: a purchase is followed only from a complete `BUY1`/`BUY2`/`BUY3` with an officer's seed, a payout only from an officer's `PAY`, so a repeated id needs an officer to reuse it; and Verify's check 3 still turns an id this client saw at another position red (`replayed`, `store.seen` keeps the position). Merging `store.seen` into the id lists is not possible: `store.seen` does not say whether an id was a purchase or a payout.
- **Entries cap.** When an officer's list would pass 3000 entries, `entries` and `base` both become nil until the next starting point.
- **`omitted`.** Raised by the witness at the `RES` only when `who` has fewer than 8 tags (with 8 the limit may have left it out legitimately), its `WIT` went out at least 0.5 s earlier, and the `RES` is the first for that row.
- **Sending alerts.** The officer addressed by the `PAYREQ` sends none (it reads its own store). A batch that finds `budget() < 3` waits and is dropped 10 s after its due time.
- **Payout decision.** The officer decides only after the followed messages of that player that arrived before the `PAYREQ` are applied (they wait in the follow queue); the request stays `fetching` meanwhile. Nothing missing: the record's short head equals `PAYREQ.head` and its `count` equals `PAYREQ.count` or is unknown. Partial: `count` known, at least 1 and below `PAYREQ.count`. Everything else: whole account. A `lost` record is used like any other: its snapshot is a true state of the past.
- **Partial log on the officer.** `Pack.decode` gets `limit = PAYREQ.count` and the record's `n`. A log with a marker other than the asked `from` is `bad_log`; the entry count must be `PAYREQ.count - from` (whole account: `PAYREQ.count`), else `mismatch`. With the officer's `entries` the check runs from `base` over the stored entries plus the received ones, so the luck index covers everything since `base`.
- **Partial log on the player.** `from` above the own entry count, an own entry that does not replay, or another short head after entry `from`: the whole account. While replaying, the request is `sending` with `total = 0`. `from`, `head`, the decision (`part`) and the spin number after entry `from` are kept in `store.payout`, so a reload restarts the replay or rebuilds the same chunks.
- **Report time.** Verify starts at the first `tick()` at least 4 s after the `PAYREQ` arrived, also when nothing is missing; `ALERT` messages arriving later are not in that report. The officer's own stored alerts about the player are added with `by` = the officer's name. `audit` is an empty list, so the audit codes `witness_mismatch`, `omitted` and `void_with_answers` no longer arise (their UI texts are gone).
- **Follow record after a check.** Starting point 3 when the report has a replayed state and no red finding of checks 1 to 6: `count = PAYREQ.count`, `base` = the state the check started from (the empty account for a whole account), `entries` = every entry the check replayed (dropped above 3000). A self payout is never followed.
- **Follow record after `confirm`.** Always moved to the state after the payout, `count = PAYREQ.count + 1`, `base` there, `entries` empty, also after a red report the officer paid anyway: every other client restarts from the same `PAY`.
- **Request records.** The officer's records carry `followed = true` (nothing transferred) or `partial = true`, and `life` (seconds, `300 + 1.2 * total`, 300 while `total` is unknown); the player's record carries `life` too. `confirm` is refused with `expired` from `life - 30` s on.
- **Incoming alerts.** `ALERT` messages are kept in memory per `reqId` only for a heard `PAYREQ` of the same player, at most 50 per `reqId`, once per `(by, code, n, g)`; the own echo is not kept. They go with the `PAYREQ` record 15 minutes after it.
