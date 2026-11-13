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
