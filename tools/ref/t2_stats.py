"""Statistics of table T2 for the multiplier `round win / stake`, no cap (docs/table-t2-spec.md, section 7).

  python3 tools/ref/t2_stats.py [rounds] [seed]      default 1000000000 rounds, seed 20260101

Exact parts (Fractions, no simulation):
  - rtp: line wins (symbol distribution per line position), scatter and free-game award (per-reel book
    count distribution), free games (expected multiplier of one free game, averaged over the nine
    expanding symbols, times the expected number of free games with retriggers and the 50-game limit),
  - freeRate: probability of three or more books in the base window.
Simulated parts (numpy, plain random stops, chunked, fixed seed):
  - hit, variance (and rtp, freeRate as cross-checks), each with its standard error.
The result is written to tools/ref/t2_stats.json, which gen_vectors.py reads.
"""
import json
import math
import os
import sys
import time
from collections import Counter
from fractions import Fraction
from itertools import product

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsref as R  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_PATH = os.path.join(HERE, "t2_stats.json")
SYMS = "LCDMWTGSKB"  # numeric code = index; B = 9


# ---------------------------------------------------------------- exact

def _line_expect(strips, tbl):
    """E[line pay in line bets] for one line: the five cells are independent, each uniform over its strip."""
    cnts = [Counter(s) for s in strips]
    tot = Fraction(0)
    num = 0
    for combo in product(*[list(c.items()) for c in cnts]):
        syms = [x[0] for x in combo]
        w = 1
        for x in combo:
            w *= x[1]
        _, _, pay = R.t2_line(syms, tbl["pays"])
        num += pay * w
    den = 1
    for s in strips:
        den *= len(s)
    tot = Fraction(num, den)
    return tot


def _book_dist(strips):
    """P(b books in the window), b = 0..15, from the per-reel distribution of books in the 3 stops."""
    dist = {0: Fraction(1)}
    for st in strips:
        n = len(st)
        per = Counter(sum(1 for r in (-1, 0, 1) if st[(s + r) % n] == "B") for s in range(n))
        new = {}
        for b, p in dist.items():
            for k, c in per.items():
                new[b + k] = new.get(b + k, 0) + p * Fraction(c, n)
        dist = new
    return dist


def _scatter_expect(dist, tbl):
    return sum(p * tbl["scatter"].get(min(b, 5), 0) for b, p in dist.items())


def _expand_expect(strips, tbl, X):
    """E[expansion pay in multiples of the stake] for expanding symbol X."""
    dist = {0: Fraction(1)}
    for st in strips:
        n = len(st)
        q = Fraction(sum(1 for s in range(n) if X in (st[(s - 1) % n], st[s], st[(s + 1) % n])), n)
        new = {}
        for m, p in dist.items():
            new[m + 1] = new.get(m + 1, 0) + p * q
            new[m] = new.get(m, 0) + p * (1 - q)
        dist = new
    return sum(p * tbl["pays"][X].get(m, 0) for m, p in dist.items())


def _expected_games(pf):
    """Expected number of free games for one triggered series; pf = P(a free game awards 10 more)."""
    dist = {R.T2_AWARD: Fraction(1)}  # awarded count -> probability, before game 1
    total = Fraction(0)
    for i in range(1, R.T2_MAX_FREE + 1):
        played = sum(p for a, p in dist.items() if a >= i)
        total += played
        new = {}
        for a, p in dist.items():
            if a < i:
                new[a] = new.get(a, 0) + p
                continue
            up = min(a + R.T2_AWARD, R.T2_MAX_FREE)
            new[up] = new.get(up, 0) + p * pf
            new[a] = new.get(a, 0) + p * (1 - pf)
        dist = new
    return total


def exact():
    tbl = R.Tables.get("T2")
    base, free = tbl["reels"], tbl["freeReels"]
    bd, fd = _book_dist(base), _book_dist(free)
    p_free = sum(p for b, p in bd.items() if b >= 3)
    pf = sum(p for b, p in fd.items() if b >= 3)
    base_mult = _line_expect(base, tbl) + _scatter_expect(bd, tbl)
    game_nox = _line_expect(free, tbl) + _scatter_expect(fd, tbl)
    exp_x = [_expand_expect(free, tbl, X) for X in R.T2_EXPAND]
    game = game_nox + sum(exp_x) / 9
    n_games = _expected_games(pf)
    rtp = base_mult + p_free * n_games * game
    return {"rtp": rtp, "freeRate": p_free, "base": base_mult, "freeGame": game, "freeGameNoExpand": game_nox,
            "expandBySymbol": dict(zip(R.T2_EXPAND, exp_x)), "pFreeRetrigger": pf, "expectedGames": n_games,
            "rtpBase": base_mult, "rtpFree": p_free * n_games * game}


# ---------------------------------------------------------------- simulation

def _tables():
    import numpy as np
    tbl = R.Tables.get("T2")
    code = {c: i for i, c in enumerate(SYMS)}
    pay = np.zeros(10 ** 5, dtype=np.int32)
    for idx in range(10 ** 5):
        d = [(idx // 10 ** k) % 10 for k in (4, 3, 2, 1, 0)]
        pay[idx] = R.t2_line([SYMS[x] for x in d], tbl["pays"])[2]

    def cells(strips):
        out = []
        for st in strips:
            n = len(st)
            out.append(np.array([[code[st[(s + r) % n]] for r in (-1, 0, 1)] for s in range(n)], dtype=np.int32))
        return out

    def books(strips):
        return [(c == 9).sum(axis=1).astype(np.int32) for c in cells(strips)]

    bc, fc = cells(tbl["reels"]), cells(tbl["freeReels"])
    # in_x[reel][x, stop] = symbol x (0..8) in the window
    inx = []
    for c in fc:
        a = np.zeros((9, c.shape[0]), dtype=np.int32)
        for x in range(9):
            a[x] = (c == x).any(axis=1)
        inx.append(a)
    exp10 = np.zeros((9, 6), dtype=np.int64)  # expansion win in tenths of the stake
    for x, sym in enumerate(SYMS[:9]):
        for m, p in tbl["pays"][sym].items():
            exp10[x, m] = p * 10
    scat10 = np.zeros(16, dtype=np.int64)
    for b in range(16):
        scat10[b] = tbl["scatter"].get(min(b, 5), 0) * 10
    return {"pay": pay, "base": bc, "free": fc, "bbooks": books(tbl["reels"]), "fbooks": books(tbl["freeReels"]),
            "inx": inx, "exp10": exp10, "scat10": scat10, "lines": tbl["lines"],
            "nb": [len(s) for s in tbl["reels"]], "nf": [len(s) for s in tbl["freeReels"]]}


def _lines10(T, cellarr, stops):
    """Sum over the ten lines of the line pay (in line bets, i.e. tenths of the stake)."""
    cols = [[cellarr[r][stops[r], row] for row in range(3)] for r in range(5)]
    total = 0
    for rows in T["lines"]:
        idx = cols[0][rows[0]]
        for r in range(1, 5):
            idx = idx * 10 + cols[r][rows[r]]
        total = total + T["pay"][idx]
    return total.astype("int64")


def _chunk(T, rng, m):
    import numpy as np
    stops = [rng.integers(0, T["nb"][r], m, dtype=np.int32) for r in range(5)]
    w10 = _lines10(T, T["base"], stops)
    b = sum(T["bbooks"][r][stops[r]] for r in range(5))
    w10 += T["scat10"][b]
    trig = np.nonzero(b >= 3)[0]
    games = 0
    if len(trig):
        X = rng.integers(0, 9, len(trig), dtype=np.int32)
        awarded = np.full(len(trig), R.T2_AWARD, dtype=np.int32)
        acc = np.zeros(len(trig), dtype=np.int64)
        act = np.arange(len(trig))
        i = 0
        while len(act):
            i += 1
            k = len(act)
            fs = [rng.integers(0, T["nf"][r], k, dtype=np.int32) for r in range(5)]
            g = _lines10(T, T["free"], fs)
            fb = sum(T["fbooks"][r][fs[r]] for r in range(5))
            g += T["scat10"][fb]
            xs = X[act]
            mm = sum(T["inx"][r][xs, fs[r]] for r in range(5))
            g += T["exp10"][xs, mm]
            acc[act] += g
            games += k
            aw = awarded[act]
            aw = np.where(fb >= 3, np.minimum(aw + R.T2_AWARD, R.T2_MAX_FREE), aw)
            awarded[act] = aw
            act = act[aw > i]
        w10[trig] += acc
    return w10.astype("float64") / 10.0, int(len(trig)), games


def simulate(rounds=200_000_000, seed=20260101, chunk=2_000_000, mu0=None, progress=True):
    import numpy as np
    T = _tables()
    rng = np.random.default_rng(seed)
    if mu0 is None:
        mu0 = float(exact()["rtp"])
    s = [0.0] * 5  # sums of d^k, k = 1..4 (index 1..4)
    hits = trig = games = done = 0
    maxw = 0.0
    t0 = time.time()
    while done < rounds:
        m = min(chunk, rounds - done)
        w, t, gm = _chunk(T, rng, m)
        d = w - mu0
        d2 = d * d
        s[1] += float(d.sum())
        s[2] += float(d2.sum())
        s[3] += float((d2 * d).sum())
        s[4] += float((d2 * d2).sum())
        hits += int((w > 0).sum())
        trig += t
        games += gm
        maxw = max(maxw, float(w.max()))
        done += m
        if progress and (done // chunk) % 10 == 0:
            print("  %d rounds, %.0fs" % (done, time.time() - t0), file=sys.stderr, flush=True)
    N = float(done)
    md = s[1] / N
    mean = mu0 + md
    var = s[2] / N - md * md
    # central fourth moment about the mean
    m4 = s[4] / N - 4 * md * s[3] / N + 6 * md * md * s[2] / N - 3 * md ** 4
    p_hit = hits / N
    p_free = trig / N
    return {
        "rounds": done, "seed": seed, "seconds": time.time() - t0,
        "rtp": mean, "rtpSE": math.sqrt(var / N),
        "variance": var, "varianceSE": math.sqrt(max(m4 - var * var, 0.0) / N),
        "hit": p_hit, "hitSE": math.sqrt(p_hit * (1 - p_hit) / N),
        "freeRate": p_free, "freeRateSE": math.sqrt(p_free * (1 - p_free) / N),
        "freeGamesPerRound": games / N, "maxWin": maxw,
    }


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000_000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20260101
    ex = exact()
    print("exact rtp      = %.15f   (a fraction with a %d-digit denominator)" % (
        float(ex["rtp"]), len(str(ex["rtp"].denominator))))
    print("  base game    = %.9f   free part = %.9f" % (float(ex["rtpBase"]), float(ex["rtpFree"])))
    print("  freeRate     = %s = %.12f" % (ex["freeRate"], float(ex["freeRate"])))
    print("  E[games]     = %.9f   E[free game] = %.9f   P(retrigger) = %.9f" % (
        float(ex["expectedGames"]), float(ex["freeGame"]), float(ex["pFreeRetrigger"])))
    sim = simulate(rounds, seed, mu0=float(ex["rtp"]))
    for k, v in sim.items():
        print("sim %-18s %s" % (k, v))
    z = (sim["rtp"] - float(ex["rtp"])) / sim["rtpSE"]
    zf = (sim["freeRate"] - float(ex["freeRate"])) / sim["freeRateSE"]
    print("z(rtp) = %.2f   z(freeRate) = %.2f" % (z, zf))
    res = {"rtp": float(ex["rtp"]),
           "hit": sim["hit"], "variance": sim["variance"], "freeRate": float(ex["freeRate"]),
           "freeRateFraction": "%d/%d" % (ex["freeRate"].numerator, ex["freeRate"].denominator),
           "se": {"rtp": sim["rtpSE"], "hit": sim["hitSE"], "variance": sim["varianceSE"],
                  "freeRate": sim["freeRateSE"]},
           "sim": sim, "zRtp": z, "zFreeRate": zf}
    if rounds >= 200_000_000:
        with open(JSON_PATH, "w") as f:
            json.dump(res, f, indent=1, sort_keys=True)
            f.write("\n")
    return res


if __name__ == "__main__":
    main()
