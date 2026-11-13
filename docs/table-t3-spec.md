# Table T3 spec (T2 with a 92 % return)

`T3` is the default table for new purchases (settings line `T=T3`) and for the solo game. It has
**every rule of `T2`** (`docs/table-t2-spec.md`): the layout, the 10 lines, the pays, the tome as
wild and scatter, the free games with the expanding symbol, the round derivation from the
purchase key, the 50-game limit, the cap and the bought free games (solo, price 64 times the
stake). Only the reel strips differ, so the return to the player is about 92 % instead of 95 %.

`T2` stays unchanged: an account bought under `T=T2` keeps replaying exactly, and
`tests/vectors_t2.lua` still pins it.

## Strips

One character per stop, stop 0 first.

Base game:

```
1: KTMKDSGTCDTGWTGWSKMSKDGSWKDWLMSCTKDGSTWCB
2: KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCKWG
3: WGDSMTWDSMWSKTSDTGKWCSTGMWSGTKGCDKMDLGWCSWMLKTGKWTLSBDM
4: TGSWMGTMWTKWSGWKTGSTKSMWKGSMKGWKGWSMKTWGTWGBMLSTCD
5: WKSBKGSWTGMWKTMGWTGKDSBLTCGKM
```

Free games:

```
1: SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWKTKBTWLSGKC
2: SWKSDKSTWGTKGMKTCSKWSMWCTKGWTDMGSTWGLSDMGSKWLTGKMLKSCWTB
3: GTDGSKWTSWKSGTKSGTLWSGWKTWDGTMKDTKSDGLSGKTDCTWKGWMBTDKBMWSC
4: SDGSKMWGTKGSWDKTGDCMSWTGWKTWKCGSTDWMGWCKSBGDMSLDWCTKL
5: WGSTWSTGKSTGWTGKWGSKTSKGTBKWSMTGSTWDKTSKWGCMDSCKBDWLGST
```

Two stops differ from T2 (0-based stops):

| Strip | Stop | T2 | T3 |
|---|---|---|---|
| base reel 2 | 37 | D | K |
| free reel 1 | 30 | D | K |

Changed stops per strip: base 0, 1, 0, 0, 0; free 1, 0, 0, 0, 0.

## How the strips were found

`python3 tools/ref/t3_tune.py` (deterministic, seed 20261112) starts from the T2 strips and
replaces one stop per step, taking the change that lowers the exact return the most without
going below 0.918, until the return lies in 0.920 ± 0.002. Allowed changes: a mid/high symbol
(M, D, C, L, the symbols that pay from two of a kind) becomes a low one (K, S, G, T, W). Kept:
every strip length, the tome positions (so the free-game rate stays 1 in 175 and no reel shows
two tomes in one window), at least one of every symbol on every reel, no two equal symbols next
to each other, a free-game share of the return between 30 % and 40 %. The hit rate is checked
afterwards to stay within 0.02 of T2's.

A single D on base reel 2 carries a lot of return in T2: M and D pay from two of a kind, so a D
on reel 2 next to one of the five Ds on reel 1 pays on every line through both. Two changes
were enough.

## Statistics

From `python3 tools/ref/t2_stats.py 1000000000 20260101 T3` (stored in `tools/ref/t3_stats.json`),
for the multiplier `round win / stake` without a cap. T2 for comparison.

| | T3 | T2 |
|---|---|---|
| rtp (exact) | 0.919956 | 0.949991 |
| base game / free games | 0.5799 / 0.3401 (37.0 % from free games) | 0.6063 / 0.3437 (36.2 %) |
| free games (exact) | 1 in 175 (747441/130790000) | same |
| hit (10^9 simulated rounds) | 0.31291 (SE 0.000015) | 0.32410 |
| variance (simulated) | 61.38 (SE 0.22) | 62.91 (SE 0.22) |
| largest simulated round win | 5517 x stake | 5517 x stake |
| bought series (exact) | 59.51 x stake | 60.14 x stake |
| bonus buy at 64 x stake | returns 93.0 % | returns 94.0 % |

The bonus-buy return lies inside 90 .. 95 %, so `T3.buyPrice` stays 64. The bought-series value
is exact: by Wald's identity a series is worth the expected number of games times the expected
free game (the expanding symbol does not change the number of games). The largest simulated win
is the same round in both runs (same seed); it does not touch a changed stop.

## Vectors

`tests/vectors_t3.lua` has the format of `tests/vectors_t2.lua` (rounds with free games,
retriggers, expansions, capped wins, wild five of a kind; two accounts bought under a `T=T3` line
with spins, gamble steps and a payout; invalid cases). `tests/test_vectors_t2.lua` checks both
files.
