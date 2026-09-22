"""Test suite for hypeback. Uses stdlib unittest (no pytest dep).

Run:  python -m unittest discover -s tests -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hypeback import engine  # noqa: E402


class TestSanityInvariants(unittest.TestCase):
    def test_sanity_check_passes(self):
        self.assertTrue(engine.sanity_check(verbose=False))

    def test_hr_1_0_equity_invariant_to_price_move(self):
        s = engine.init_state(100_000.0, 1.0, 3.0)
        eq_before = engine.compute_equity(s)
        s["spot_value"] *= 1.05
        s["perp_notional"] *= 1.05
        eq_after = engine.compute_equity(s)
        self.assertAlmostEqual(eq_before, eq_after, places=6)

    def test_hr_1_5_short_delta_is_33_3pct_of_capital(self):
        s = engine.init_state(100_000.0, 1.5, 3.0)
        spot_init = s["spot_value"]
        eq_before = engine.compute_equity(s)
        s["spot_value"] *= 1.01
        s["perp_notional"] *= 1.01
        eq_after = engine.compute_equity(s)
        expected = -(0.5) * spot_init * 0.01
        self.assertAlmostEqual(eq_after - eq_before, expected, places=4)

    def test_initial_equity_equals_capital(self):
        for hr, lev in [(0.5, 3.0), (1.0, 3.0), (1.5, 3.0), (2.0, 5.0)]:
            s = engine.init_state(100_000.0, hr, lev)
            self.assertAlmostEqual(engine.compute_equity(s), 100_000.0, places=4)


class TestEngineSmoke(unittest.TestCase):
    def test_run_backtest_returns_required_keys(self):
        r = engine.run_backtest(overrides={"hr_target": 1.0, "lev": 3.0, "seed": 42},
                                return_curve=True)
        for key in ("final_equity", "net_apy", "max_drawdown", "sharpe",
                    "years", "funding_pnl", "staking_pnl", "fees_paid",
                    "trades", "liquidated"):
            self.assertIn(key, r)
        self.assertIn("equity_curve", r)
        self.assertGreater(len(r["equity_curve"]), 10_000)

    def test_window_hours_restricts_history(self):
        r_all = engine.run_backtest(overrides={"hr_target": 1.0, "seed": 1},
                                    return_curve=True)
        r_recent = engine.run_backtest(overrides={"hr_target": 1.0, "seed": 1},
                                       window_hours=2000, return_curve=True)
        self.assertGreater(len(r_all["equity_curve"]), len(r_recent["equity_curve"]))

    def test_different_seeds_give_different_paths(self):
        r1 = engine.run_backtest(overrides={"hr_target": 1.0, "seed": 1})
        r2 = engine.run_backtest(overrides={"hr_target": 1.0, "seed": 2})
        self.assertNotEqual(r1["net_apy"], r2["net_apy"])

    def test_monte_carlo_shape(self):
        mc = engine.monte_carlo(num_paths=20, seed=42,
                                overrides={"hr_target": 1.0, "lev": 3.0})
        self.assertEqual(mc["n_paths"], 20)
        self.assertEqual(len(mc["apy_samples"]), 20)
        self.assertEqual(len(mc["dd_samples"]), 20)
        self.assertLessEqual(mc["liquidations"], 20)


class TestKillGate(unittest.TestCase):
    def test_passes_for_delta_neutral(self):
        r = engine.run_backtest(overrides={"hr_target": 1.0, "lev": 3.0, "seed": 42})
        self.assertTrue(engine.kill_gate(r)["passed"])

    def test_fails_for_overleveraged_hr(self):
        r = engine.run_backtest(overrides={"hr_target": 2.0, "lev": 3.0, "seed": 42})
        # HR=2.0 has -50% net short delta; expect to fail the 15% DD gate
        self.assertFalse(engine.kill_gate(r)["passed"])


class TestData(unittest.TestCase):
    def test_data_file_loads(self):
        recs = engine.load_funding()
        self.assertGreater(len(recs), 15_000)
        # sorted by time
        times = [r["time"] for r in recs]
        self.assertEqual(times, sorted(times))
        # contains expected keys
        for k in ("coin", "fundingRate", "premium", "time"):
            self.assertIn(k, recs[0])


if __name__ == "__main__":
    unittest.main()
