"""Search the reel strips of table T3 (docs/table-t3-spec.md): T2 with a return of about 92 %.

  python3 tools/ref/t3_tune.py          prints the strips, the changed stops and the exact statistics

Deterministic: a greedy search from the T2 strips with ties broken by a fixed seed. Each step
replaces one stop. Rules:
  - every strip keeps its length, the tome (B) stays on exactly the T2 positions (free-game rate and
    retrigger rate stay exact as in T2, no reel shows two tomes in one window);
  - only a mid/high symbol (M, D, C, L: they pay from two of a kind) becomes a low one (K, S, G, T, W);
  - every reel keeps at least one of every symbol;
  - no two equal symbols next to each other (T2 has none; this also rules out three in a row);
  - each step takes the change that lowers the exact return the most without going below the band,
    and the search stops as soon as the return is in TARGET +- BAND;
  - the free-game share of the return must stay within 30 .. 40 %.
The search scores candidates with floats (numpy); the result is then checked with the exact
Fraction calculation of t2_stats.py. Hit rate is checked separately by t2_stats.py (simulation).
"""
import os
import random
import sys
from collections import Counter

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsref as R  # noqa: E402
import t2_stats as TS  # noqa: E402

TARGET = 0.920
BAND = 0.002
SEED = 20261112
SYMS = TS.SYMS  # "LCDMWTGSKB"
HIGH = "MDCL"
LOW = "KSGTW"
FREE_SHARE = (0.30, 0.40)


def _pay5():
    """pay[a, b, c, d, e] = line pay in line bets for the symbol codes a..e (reels 1..5)."""
    pays = R.T2_PAYS
    out = np.zeros(10 ** 5)
    for idx in range(10 ** 5):
        d = [(idx // 10 ** k) % 10 for k in (4, 3, 2, 1, 0)]
        out[idx] = R.t2_line([SYMS[x] for x in d], pays)[2]
    return out.reshape((10,) * 5)


PAY5 = _pay5()


def _probs(strip):
    c = Counter(strip)
    return np.array([c[s] / len(strip) for s in SYMS])


def _grads(strips):
    """Per reel: E[line pay | that reel's line cell shows symbol x], x = 0..9 (other reels random)."""
    ps = [_probs(s) for s in strips]
    letters = "abcde"
    out = []
    for r in range(5):
        ops = [PAY5] + [ps[k] for k in range(5) if k != r]
        spec = "abcde," + ",".join(letters[k] for k in range(5) if k != r) + "->" + letters[r]
        out.append(np.einsum(spec, *ops))
    return out


def _line(strips):
    return float(_grads(strips)[0] @ _probs(strips[0]))


def _q(strip, X):
    n = len(strip)
    return sum(1 for s in range(n) if X in (strip[(s - 1) % n], strip[s], strip[(s + 1) % n])) / n


def _expand(qs, X):
    dist = [1.0]
    for q in qs:
        new = [0.0] * (len(dist) + 1)
        for m, p in enumerate(dist):
            new[m + 1] += p * q
            new[m] += p * (1 - q)
        dist = new
    return sum(p * R.T2_PAYS[X].get(m, 0) for m, p in enumerate(dist))


class Model:
    """Float model of the exact return: only line wins and expansion depend on the non-tome stops."""

    def __init__(self, base, free):
        ex = TS.exact(dict(R.Tables.get("T2"), reels=base, freeReels=free))
        self.k = float(ex["freeRate"] * ex["expectedGames"])  # free games per round
        bd, fd = TS._book_dist(base), TS._book_dist(free)
        self.sb = float(TS._scatter_expect(bd, R.Tables.get("T2")))
        self.sf = float(TS._scatter_expect(fd, R.Tables.get("T2")))
        self.base, self.free = list(base), list(free)
        self.refresh()

    def refresh(self):
        self.gb, self.gf = _grads(self.base), _grads(self.free)
        self.lb = float(self.gb[0] @ _probs(self.base[0]))
        self.lf = float(self.gf[0] @ _probs(self.free[0]))
        self.q = {X: [_q(s, X) for s in self.free] for X in R.T2_EXPAND}
        self.ex = {X: _expand(self.q[X], X) for X in R.T2_EXPAND}

    def parts(self, lb=None, lf=None, ex=None):
        lb = self.lb if lb is None else lb
        lf = self.lf if lf is None else lf
        ex = self.ex if ex is None else ex
        base = lb + self.sb
        free = self.k * (lf + self.sf + sum(ex.values()) / 9)
        return base, free

    def rtp(self, **kw):
        b, f = self.parts(**kw)
        return b + f

    def try_change(self, which, r, i, new):
        """Return of the table with stop i of reel r (0-based) set to `new`."""
        strips = self.base if which == "base" else self.free
        st = strips[r]
        old = st[i]
        n = len(st)
        ci, co = SYMS.index(new), SYMS.index(old)
        if which == "base":
            g = self.gb[r]
            return self.parts(lb=self.lb + (g[ci] - g[co]) / n)
        g = self.gf[r]
        lf = self.lf + (g[ci] - g[co]) / n
        ns = st[:i] + new + st[i + 1:]
        ex = dict(self.ex)
        for X in (old, new):
            qs = list(self.q[X])
            qs[r] = _q(ns, X)
            ex[X] = _expand(qs, X)
        return self.parts(lf=lf, ex=ex)

    def apply(self, which, r, i, new):
        strips = self.base if which == "base" else self.free
        strips[r] = strips[r][:i] + new + strips[r][i + 1:]
        self.refresh()


def allowed(strip, i, new):
    n = len(strip)
    if strip[i] not in HIGH or new not in LOW:
        return False
    if strip.count(strip[i]) <= 1:
        return False  # keep at least one of every symbol
    return strip[(i - 1) % n] != new and strip[(i + 1) % n] != new


def tune(verbose=False):
    rng = random.Random(SEED)
    m = Model(R.T2_BASE, R.T2_FREE)
    steps = []
    while m.rtp() > TARGET + BAND:
        cands = []
        for which in ("base", "free"):
            strips = m.base if which == "base" else m.free
            for r, st in enumerate(strips):
                for i in range(len(st)):
                    for new in LOW:
                        if allowed(st, i, new):
                            cands.append((which, r, i, new))
        rng.shuffle(cands)  # ties: the seeded order decides
        best = None
        for c in cands:
            b, f = m.try_change(*c)
            v = b + f
            if v < TARGET - BAND or not FREE_SHARE[0] <= f / v <= FREE_SHARE[1]:
                continue
            # in the band: closest to TARGET wins; otherwise the largest step down
            key = (0, abs(v - TARGET)) if v <= TARGET + BAND else (1, v)
            if best is None or key < best[0]:
                best = (key, c, v)
        if best is None:
            raise RuntimeError("no admissible change left at rtp %.6f" % m.rtp())
        which, r, i, new = best[1]
        old = (m.base if which == "base" else m.free)[r][i]
        m.apply(which, r, i, new)
        steps.append((which, r + 1, i, old, new, m.rtp()))
        if verbose:
            print("  %s reel %d stop %2d: %s -> %s   rtp %.6f" % steps[-1], file=sys.stderr)
    return m.base, m.free, steps


def diff(a, b):
    """Changed stops between two strip lists: [(reel, stop, old, new)], reel 1-based, stop 0-based."""
    return [(r + 1, i, x, y) for r in range(5) for i, (x, y) in enumerate(zip(a[r], b[r])) if x != y]


def main():
    base, free, steps = tune(verbose=True)
    tbl = dict(R.Tables.get("T2"), id="T3", reels=base, freeReels=free)
    ex = TS.exact(tbl)
    print("base strips:")
    for r, s in enumerate(base, 1):
        print("%d: %s" % (r, s))
    print("free strips:")
    for r, s in enumerate(free, 1):
        print("%d: %s" % (r, s))
    for name, a, b in (("base", R.T2_BASE, base), ("free", R.T2_FREE, free)):
        d = diff(a, b)
        per = Counter(x[0] for x in d)
        print("%s: %d stops changed (%s)" % (name, len(d), ", ".join("reel %d: %d" % (r, per[r]) for r in range(1, 6))))
        for r, i, x, y in d:
            print("  reel %d stop %2d: %s -> %s" % (r, i, x, y))
    rtp = float(ex["rtp"])
    print("exact rtp %.9f  base %.9f  free %.9f (share %.4f)  freeRate %s" % (
        rtp, float(ex["rtpBase"]), float(ex["rtpFree"]), float(ex["rtpFree"]) / rtp, ex["freeRate"]))
    print("bought series %.6f x stake" % float(ex["boughtEV"]))
    assert abs(rtp - TARGET) <= BAND
    assert FREE_SHARE[0] <= float(ex["rtpFree"]) / rtp <= FREE_SHARE[1]
    # hit rate within 0.02 of T2's (short simulation, same seed for both tables)
    h2 = TS.simulate(4_000_000, seed=SEED, tbl="T2", progress=False)["hit"]
    h3 = TS.simulate(4_000_000, seed=SEED, tbl=tbl, progress=False)["hit"]
    print("hit (4e6 simulated rounds): T2 %.4f, T3 %.4f" % (h2, h3))
    assert abs(h3 - h2) <= 0.02
    return base, free


if __name__ == "__main__":
    main()
