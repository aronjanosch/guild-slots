"""Self-check of the Python reference: python3 tools/ref/test_ref.py"""
import os
import sys
import unittest
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_vectors as G  # noqa: E402
import gsref as R  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
