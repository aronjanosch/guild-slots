# Table T2 spec (five reels, lines, free games)

Adds a second table next to `T1`. `docs/core-spec.md` stays valid for everything else; this file
defines what a spin means when the settings line says `T=T2`. `T1` keeps working unchanged
(its vectors and tests stay).

## 1. Layout

- 5 reels, 3 visible rows. For reel `r` at stop `s` (0-based) the window is
  top = strip[s-1], middle = strip[s], bottom = strip[s+1], wrapping around the strip. Rows are
  numbered 0 (top), 1 (middle), 2 (bottom).
- 10 fixed lines. The stake is the total bet; `lineBet = stake / 10`. A stake that is not a
  multiple of 10 is invalid for T2: `Settings.parse` rejects such an `E` list when `T=T2`, and the
  ledger answers `bad_stake`.
- Lines, as the row on reels 1..5:

```
 1: 1 1 1 1 1      6: 1 2 2 2 1
 2: 0 0 0 0 0      7: 1 0 0 0 1
 3: 2 2 2 2 2      8: 2 2 1 0 0
 4: 0 1 2 1 0      9: 0 0 1 2 2
 5: 2 1 0 1 2     10: 0 1 1 1 0
```

## 2. Symbols and pays

Pays are multiples of the line bet for 2, 3, 4, 5 of a kind.

| Symbol | 2 | 3 | 4 | 5 |
|---|---|---|---|---|
| K, S, G | - | 5 | 25 | 100 |
| T, W | - | 5 | 40 | 150 |
| M, D | 5 | 30 | 100 | 750 |
| C | 5 | 40 | 400 | 2000 |
| L | 10 | 100 | 1000 | 5000 |
| B (book) | wild and scatter, no line pay of its own |

Scatter pay for B anywhere in the window, as multiples of the **stake**: 3 → 2, 4 → 20,
5 or more → 200. Three or more B award free games.

Symbol order for display, best first: `L C D M W T G S K`, then `B`.

## 3. Strips

One character per stop, stop 0 first.

Base game:

```
1: KTMKDSGTCDTGWTGWSKMSKDGSWKDWLMSCTKDGSTWCB
2: KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCDWG
3: WGDSMTWDSMWSKTSDTGKWCSTGMWSGTKGCDKMDLGWCSWMLKTGKWTLSBDM
4: TGSWMGTMWTKWSGWKTGSTKSMWKGSMKGWKGWSMKTWGTWGBMLSTCD
5: WKSBKGSWTGMWKTMGWTGKDSBLTCGKM
```

Free games:

```
1: SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWDTKBTWLSGKC
2: SWKSDKSTWGTKGMKTCSKWSMWCTKGWTDMGSTWGLSDMGSKWLTGKMLKSCWTB
3: GTDGSKWTSWKSGTKSGTLWSGWKTWDGTMKDTKSDGLSGKTDCTWKGWMBTDKBMWSC
4: SDGSKMWGTKGSWDKTGDCMSWTGWKTWKCGSTDWMGWCKSBGDMSLDWCTKL
5: WGSTWSTGKSTGWTGKWGSKTSKGTBKWSMTGSTWDKTSKWGCMDSCKBDWLGST
```

## 4. Evaluating one window

Used for the base game and for each free game.

**Lines.** For each line take the five symbols left to right. `target` is the first symbol that is
not B; a line of five B pays nothing. `count` is the length of the prefix in which every symbol is
`target` or B. The line wins `pays[target][count] * lineBet` (nothing when that pay is `-` or
`count < 2`).

**Scatter.** `b` = number of B among the 15 visible cells. Scatter win = scatter pay for
`min(b, 5)` times the stake. `b >= 3` awards 10 free games.

**Expanding symbol (free games only).** Each free-game series has one expanding symbol `X`
(never B). After lines and scatter: `m` = number of reels whose window shows `X` at least once
(B does not count as `X` here). If `pays[X][m]` is a pay, the symbol expands over those reels and
wins `pays[X][m] * lineBet * 10` on top of the line wins. The reels need not be adjacent.

Window win = line wins + scatter win + expansion win.

## 5. A round

A round is one spin entry in the account: the base game plus every free game it awards. The
ledger entry, the SPIN message and the witness contributions are those of a T1 spin; nothing on
the wire changes.

```
R        = Sha256.hmacRaw(K, "spin" | n | contribs)
stop r   = uint32be(R[4r-3 .. 4r]) mod #baseStrip[r]          r = 1..5
X        = "KSGTWMDCL"[ uint32be(R[21..24]) mod 9 ]            (index 0 = K); used only when free games are awarded
F(i)     = Sha256.hmacRaw(K, "free" | n | i | contribs)       i = 1, 2, … the i-th free game of this round
stop r   = uint32be(F(i)[4r-3 .. 4r]) mod #freeStrip[r]
```

- The base game awards 10 free games when `b >= 3`. A free game with `b >= 3` awards 10 more.
- At most 50 free games are played per round; awards beyond that are dropped.
- Round win = base window win + all free-game window wins. With a cap `C > 0` the round win is
  `min(win, C)`.
- The balance changes by `-stake + round win`. The gamble offer after a round risks the round win,
  with the rules of core-spec (pending, `G`, cap).

## 6. Lua interface

`Tables.get("T2")` returns `{ id = "T2", kind = "lines", reels = base strips, freeReels, rows = 3,
lines, pays, scatter, lineCount = 10 }`; `T1` gets `kind = "classic"`. Existing `Tables.*`
functions keep their T1 behaviour. New:

```
Engine.round(K, n, contribs, tbl, stake, cap) -> round      for T2; K as text or keyed function
Tables.evaluate(tbl, stops, stake, X)         -> window result (X nil in the base game; `tbl.freeReels` when X is given)
Tables.stats(tbl, stake, cap)                 -> { rtp, hit, variance } for T2 from constants (section 7)
```

```
round = {
  kind = "lines", n = n, stake = stake, lineBet = stake / 10,
  stops = { s1..s5 }, window = { {top, mid, bottom} x 5 },
  lines = { { line = 4, symbol = "M", count = 3, win = 30 }, … },   winning lines only, ascending line number
  scatter = { count = b, win = w },
  base = base window win,
  free = nil, or { symbol = X, awarded = games played, win = sum of the free-game wins, games = { game, … } },
  win = round win after the cap,
}
game = { stops, window, lines, scatter, expand = nil or { reels = {1,3,4}, count = 3, win = w }, win, retrigger = boolean }
```

`Ledger.apply` uses `Engine.round` for a T2 account; its `info` then carries `round = round`,
`win`, `multiplier = win / stake` (may be fractional), `balance`, `pending`, `head`, and no `stops`.
`Verify` works for T2 accounts through the same path.

## 7. Statistics

The 130 million base combinations are too many to enumerate in the game. `Tables.stats` for T2
returns constants computed by the Python reference (`tools/ref`), for the multiplier
`round win / stake` without a cap: `rtp`, `hit` (share of rounds with a win), `variance`,
`freeRate` (share of rounds that award free games). With a cap `C > 0` the same constants are
used; they then overstate mean and variance, which only makes the luck index more lenient.

The reference computes `rtp` exactly where it can (line wins and scatter by enumeration per line;
free games by enumeration per expanding symbol and the expected number of games) and gives
`variance` from a simulation of at least 2·10^8 rounds with the standard error stated.

## 8. Vectors

`tests/vectors_t2.lua`, written by `tools/ref/gen_vectors.py`, returns

```
{ stats = { rtp =, hit =, variance =, freeRate = },
  rounds = { { K =, n =, contribs =, stake =, cap =, round = <round table as in section 6> }, … },
  accounts = { { guild =, player =, entries = { text, … }, balance =, head = <64 hex> }, … } }
```

with at least 200 rounds, among them rounds with free games, a retrigger, an expansion win, a
capped win, five-of-a-kind through wilds and a scatter win without free games (searched for by
trying spin numbers), and at least two T2 accounts with purchases, spins and gamble steps.
`tests/test_vectors_t2.lua` compares `Engine.round` field by field and replays the accounts.

## Clarifications

Readings fixed after the Lua implementation and the Python reference were compared; the vectors
pin them.

- `retrigger` is true whenever a free game shows three or more B, also when the 50-game limit
  drops the award. `free.awarded` is the number of free games played.
- The free-game index `i` counts every game of the round across retriggers. `X` is drawn once per
  round and stays through retriggers.
- `scatter.count` is the real number of B (not limited to 5); `scatter` and `lines` are always
  present, `free` and `expand` only when they apply.
- A line pays only for its full prefix count: `K K` (count 2, no pay) wins nothing. Leading B count
  toward the prefix. The expansion win is added on top of line wins, including those of `X`.
- The cap applies to `round.win` only; `base`, `free.win` and the game wins stay uncapped.
- Measured statistics (no cap): rtp 0.949991 (exact; 0.6063 base game, 0.3437 free games),
  free games in 1 of 175 rounds (exact), hit 0.3241, variance 62.91 (10^9 simulated rounds,
  standard error 0.22). Largest simulated round win: 5517 times the stake.
