"""Self-check of the Python reference: python3 tools/ref/test_ref.py"""
import os
import sys
import unittest
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_vectors as G  # noqa: E402
import gsref as R  # noqa: E402
import t2_stats as TS  # noqa: E402


class RefTests(unittest.TestCase):
    def test_table_stats(self):
        st = R.Tables.stats(R.Tables.get("T1"), 10, 0)
        self.assertEqual(st["rtp"], Fraction(4594, 4913))
        self.assertAlmostEqual(float(st["hit"]), 0.198962, places=6)
        self.assertAlmostEqual(float(st["variance"]), 22.057864, places=6)
        self.assertEqual(st["combos"], 39304)

    def test_cap_lowers_rtp(self):
        t = R.Tables.get("T1")
        self.assertLess(R.Tables.stats(t, 100, 300)["rtp"], R.Tables.stats(t, 100, 0)["rtp"])

    def test_vectors_replay(self):
        data = G.build_all()  # runs replay, head and invalid-case self-checks
        self.assertGreaterEqual(len(data["ledger"]["accounts"]), 4)


# ---------------------------------------------------------------- table T2

T2 = R.Tables.get("T2")


def cols_table(cols, free=False):
    """T2 table whose strips are the three-character columns: at stop 1 the window is the column itself."""
    t = dict(T2)
    if free:
        t["freeReels"] = list(cols)
    else:
        t["reels"] = list(cols)
    return t


def ev(cols, stake=100, X=None):
    return R.t2_evaluate(cols_table(cols, X is not None), [1] * 5, stake, X)


def line_win(res, line):
    return sum(x["win"] for x in res["lines"] if x["line"] == line)


FILL = ["KKK", "TTT", "GGG", "SSS", "KKK"]  # no line wins, no books


def mid_row(syms):
    """Columns whose middle row is `syms` (line 1); top and bottom rows are neutral filler."""
    return ["%s%s%s" % ("T" if x != "T" else "G", x, "T" if x != "T" else "G") for x in syms]


class T2Tests(unittest.TestCase):
    def test_strips_match_spec(self):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "..", "docs", "table-t2-spec.md")) as f:
            txt = f.read()
        blocks = [b for b in txt.split("```") if b.strip()[:2] == "1:"]
        self.assertEqual(len(blocks), 3)  # lines, base strips, free strips
        base = [ln.split(": ")[1] for ln in blocks[1].strip().split("\n")]
        free = [ln.split(": ")[1] for ln in blocks[2].strip().split("\n")]
        self.assertEqual(T2["reels"], base)
        self.assertEqual(T2["freeReels"], free)

    def test_window_wraps(self):
        w = R.t2_window(["ABC", "ABC", "ABC", "ABC", "ABC"], [0, 1, 2, 0, 1])
        self.assertEqual(w[0], ["C", "A", "B"])
        self.assertEqual(w[1], ["A", "B", "C"])
        self.assertEqual(w[2], ["B", "C", "A"])

    def test_every_pay_rule(self):
        # stake 100, line bet 10; only line 1 (middle row) is checked
        for sym, pays in R.T2_PAYS.items():
            other = "S" if sym == "K" else "K"
            for count in range(1, 6):
                res = ev(mid_row([sym] * count + [other] * (5 - count)))
                want = pays.get(count, 0) * 10 if count >= 2 else 0
                self.assertEqual(line_win(res, 1), want, (sym, count))

    def test_wild_cases(self):
        cases = [("KBKTT", 50), ("BBMTT", 300), ("BKKKB", 1000), ("CBBBC", 20000), ("BBBBB", 0),
                 ("BBBBK", 1000), ("MBTSK", 50), ("KKTBB", 0), ("KTBKK", 0), ("BLTSK", 100),
                 ("LBBKK", 1000), ("TBBBS", 400)]
        for text, want in cases:
            self.assertEqual(line_win(ev(mid_row(list(text))), 1), want, text)

    def test_leading_wild_detail(self):
        res = ev(mid_row(list("BBMTT")))
        e = [x for x in res["lines"] if x["line"] == 1][0]
        self.assertEqual((e["symbol"], e["count"], e["win"]), ("M", 3, 300))

    def test_full_window_exact(self):
        # top row K K K S K -> line 2 (count 3); line 7 reads mid K, top K, top K, top S -> count 3
        res = ev(["KKK", "KTT", "KGG", "SSS", "KKK"], stake=100)
        got = [(x["line"], x["symbol"], x["count"], x["win"]) for x in res["lines"]]
        self.assertEqual(got, [(2, "K", 3, 50), (7, "K", 3, 50)])
        self.assertEqual(res["win"], 100)
        self.assertEqual(res["scatter"], {"count": 0, "win": 0})
        self.assertNotIn("expand", res)

    def test_no_win_filler(self):
        res = ev(FILL)
        self.assertEqual((res["lines"], res["win"]), ([], 0))

    def test_five_books_on_a_line(self):
        res = ev(["KBS", "TBG", "GBK", "SBT", "KBG"], stake=10)
        self.assertEqual(line_win(res, 1), 0)
        self.assertFalse([x for x in res["lines"] if x["line"] == 1])
        self.assertEqual(res["scatter"], {"count": 5, "win": 2000})
        self.assertTrue(res["retrigger"])

    def test_scatter_counts(self):
        for books, mult, trig in ((0, 0, False), (1, 0, False), (2, 0, False), (3, 2, True), (4, 20, True),
                                  (5, 200, True), (6, 200, True), (15, 200, True)):
            cols = ["".join("B" if i * 3 + j < books else f for j in range(3)) for i, f in enumerate("KTGSK")]
            res = ev(cols, stake=50)
            self.assertEqual(res["scatter"], {"count": books, "win": mult * 50}, books)
            self.assertEqual(res["retrigger"], trig)

    def test_expansion_non_adjacent(self):
        cols = ["KTG", "TGS", "KTG", "TGS", "KTG"]  # K on reels 1, 3, 5 only
        res = ev(cols, stake=100, X="K")
        self.assertEqual(res["expand"], {"reels": [1, 3, 5], "count": 3, "win": 500})
        self.assertEqual(res["win"], sum(x["win"] for x in res["lines"]) + res["scatter"]["win"] + 500)

    def test_expansion_counts(self):
        res = ev(["KTG", "KTG", "TGS", "TGS", "TGS"], X="K")
        self.assertNotIn("expand", res)  # K pays from 3 reels
        res = ev(["MTG", "TGS", "TGS", "TGS", "MTG"], stake=100, X="M")
        self.assertEqual(res["expand"], {"reels": [1, 5], "count": 2, "win": 500})  # M pays 5 for two
        res = ev(["LTG", "TLS", "TGL", "LGS", "TGS"], stake=10, X="L")
        self.assertEqual(res["expand"]["reels"], [1, 2, 3, 4])
        self.assertEqual(res["expand"]["win"], 1000 * 10)

    def test_expansion_ignores_books(self):
        res = ev(["KTG", "KTG", "BTG", "TGS", "TGS"], X="K")
        self.assertNotIn("expand", res)  # K on 2 reels; the book on reel 3 does not count as K
        self.assertEqual(res["scatter"]["count"], 1)

    def test_expansion_once_per_reel(self):
        res = ev(["KKG", "TGS", "TGS", "TGS", "TGS"], X="K")  # two K on one reel count that reel once
        self.assertNotIn("expand", res)
        res = ev(["KKK", "KTS", "KGS", "TGS", "TGS"], stake=100, X="K")
        self.assertEqual(res["expand"], {"reels": [1, 2, 3], "count": 3, "win": 500})

    def test_bad_stake(self):
        with self.assertRaises(R.Err):
            R.t2_evaluate(T2, [0] * 5, 15)

    def test_round_deterministic_and_consistent(self):
        K = R.sha_hex("k")
        seen_free = 0
        for n in range(1, 3000):
            a = R.t2_round(K, n, "", T2, 100, 0)
            b = R.t2_round(lambda m, raw=False: R.hmac_raw(K, m) if raw else R.hmac_hex(K, m), n, "", T2, 100, 0)
            self.assertEqual(a, b)
            self.assertEqual(a["base"], sum(x["win"] for x in a["lines"]) + a["scatter"]["win"])
            self.assertEqual(a["lineBet"], 10)
            if "free" in a:
                seen_free += 1
                f = a["free"]
                self.assertEqual(f["awarded"], len(f["games"]))
                self.assertEqual(f["win"], sum(g["win"] for g in f["games"]))
                self.assertEqual(a["win"], a["base"] + f["win"])
                self.assertIn(f["symbol"], "KSGTWMDCL")
                self.assertEqual(f["awarded"], min(10 + 10 * sum(g["retrigger"] for g in f["games"]), 50))
                self.assertGreaterEqual(a["scatter"]["count"], 3)
            else:
                self.assertEqual(a["win"], a["base"])
                self.assertLess(a["scatter"]["count"], 3)
        self.assertGreater(seen_free, 5)

    def test_round_stops_and_expanding_symbol(self):
        K = R.sha_hex("k2")
        c = "x:0123456789abcdef"
        for n in range(1, 5000):
            rd = R.t2_round(K, n, c, T2, 10, 0)
            raw = R.hmac_raw(K, "spin|%d|%s" % (n, c))
            self.assertEqual(rd["stops"], [int.from_bytes(raw[4 * i:4 * i + 4], "big") % len(T2["reels"][i])
                                           for i in range(5)])
            if "free" in rd:
                self.assertEqual(rd["free"]["symbol"], "KSGTWMDCL"[int.from_bytes(raw[20:24], "big") % 9])
                f1 = R.hmac_raw(K, "free|%d|1|%s" % (n, c))
                self.assertEqual(rd["free"]["games"][0]["stops"],
                                 [int.from_bytes(f1[4 * i:4 * i + 4], "big") % len(T2["freeReels"][i])
                                  for i in range(5)])
                return
        self.fail("no free round")

    def test_cap(self):
        K = R.sha_hex("k")
        for n in range(1, 3000):
            full = R.t2_round(K, n, "", T2, 100, 0)
            if full["win"] > 10:
                capped = R.t2_round(K, n, "", T2, 100, 10)
                self.assertEqual(capped["win"], 10)
                self.assertEqual(capped["base"], full["base"])
                self.assertEqual(R.t2_round(K, n, "", T2, 100, full["win"])["win"], full["win"])
                return
        self.fail("no win")

    def test_fifty_game_limit(self):
        # every window is all books: every game retriggers, the series stops at 50 games
        t = dict(T2)
        t["reels"] = ["BBB"] * 5
        t["freeReels"] = ["BBB"] * 5
        rd = R.t2_round("k", 1, "", t, 10, 0)
        self.assertEqual(rd["free"]["awarded"], 50)
        self.assertEqual(len(rd["free"]["games"]), 50)
        self.assertTrue(all(g["retrigger"] for g in rd["free"]["games"]))
        self.assertEqual(rd["win"], 51 * 200 * 10)
        self.assertEqual(R.t2_round("k", 1, "", t, 10, 777)["win"], 777)

    def test_settings_rule(self):
        self.assertEqual(R.settings_parse("GSLOTS1;E=10,20;T=T2")["E"], [10, 20])
        for line in ("GSLOTS1;E=10,15;T=T2", "GSLOTS1;T=T2;E=5", "GSLOTS1;T=T2;E=10,20,35"):
            with self.assertRaises(R.Err) as cm:
                R.settings_parse(line)
            self.assertEqual(cm.exception.code, "bad_settings")
        self.assertEqual(R.settings_parse("GSLOTS1;E=15,25;T=T1")["E"], [15, 25])
        self.assertEqual(R.settings_parse("GSLOTS1;E=15")["T"], "T1")

    def test_ledger_t2(self):
        ac, r = G.fresh(G.T2_LINE, tokens=1000, seed_label="t2test")
        st = R.start(ac.guild, ac.player)
        for t in ac.texts:
            R.apply(st, R.decode(t))
        with self.assertRaises(R.Err) as cm:
            R.apply(st, G.S_(1, 20))
        self.assertEqual(cm.exception.code, "bad_stake")
        info = R.apply(st, G.S_(1, 10))
        self.assertIn("round", info)
        self.assertNotIn("stops", info)
        self.assertEqual(info["multiplier"], R.Fraction(info["win"], 10))
        self.assertEqual(info["balance"], 1000 - 10 + info["win"])
        self.assertEqual(info["round"], R.t2_round(st.K, 1, "", st.tbl, 10, 0))

    def test_t1_kind(self):
        self.assertEqual(R.Tables.get("T1")["kind"], "classic")
        self.assertIsNone(R.Tables.get("T3"))


class T2StatsTests(unittest.TestCase):
    def test_exact_and_small_simulation(self):
        ex = TS.exact()
        self.assertAlmostEqual(float(ex["rtp"]), 0.9499910643, places=9)
        self.assertEqual(ex["freeRate"], R.Fraction(747441, 130790000))
        sim = TS.simulate(4_000_000, seed=5, mu0=float(ex["rtp"]), progress=False)
        self.assertLess(abs(sim["rtp"] - float(ex["rtp"])), 4 * sim["rtpSE"])
        self.assertLess(abs(sim["freeRate"] - float(ex["freeRate"])), 4 * sim["freeRateSE"])

    def test_numpy_tables_match_reference(self):
        import numpy as np
        T = TS._tables()
        rng = np.random.default_rng(3)
        for _ in range(300):
            stops = [int(rng.integers(0, n)) for n in T["nb"]]
            ref = R.t2_evaluate(T2, stops, 10)  # stake 10: line bet 1, scatter pays 10 * multiple
            arr = [np.array([s], dtype=np.int32) for s in stops]
            got = int(TS._lines10(T, T["base"], arr)[0]) + int(T["scat10"][sum(T["bbooks"][r][stops[r]]
                                                                                for r in range(5))])
            self.assertEqual(got, ref["win"])


if __name__ == "__main__":
    unittest.main()
