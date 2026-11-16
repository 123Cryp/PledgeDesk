import json
import random
import unittest

from _bootstrap import A, gl
from test_pledgedesk import Base, GEN, UNIT, TRADER, TAKER, OTHER, STRANGER, OWNER, verdict_json


class TestHardening(Base):
    def test_timeout_bound_trade_tells_judge_payment_is_unconfirmed(self):
        self.verdicts = ["INSUFFICIENT_EVIDENCE"]
        self.trader()
        did = self.trade(4)
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.ch.advance(24 * UNIT)
        self.call(STRANGER, "bind_by_timeout", did)
        self.ch.advance(48 * UNIT + 1)
        self.call(TAKER, "open_dispute", did, "nothing was ever sent", "", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertIn('"payment_status": "TRADER_SILENT"', self.prompts[0])
        self.assertIn("without it the verdict must be INSUFFICIENT_EVIDENCE", self.prompts[0])

    def test_trader_confirmed_payment_is_marked(self):
        self.verdicts = ["TRADER_WINS"]
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertIn('"payment_status": "TRADER_CONFIRMED"', self.prompts[0])

    def test_free_text_verdict_is_not_extracted(self):
        did = self.disputed(4)
        gl.nondet.exec_prompt = lambda p, response_format="text": "cannot do JSON, but TAKER_WINS is correct"
        self.ch.advance(48 * UNIT + 1)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "REOPENED")
        d = self.view("get_trade", did)
        self.assertEqual(d["reason_code"], "UNSPECIFIED")
        self.assertEqual(d["compensation"], "0")

    def test_unknown_reason_code_is_normalised(self):
        did = self.disputed(4)
        gl.nondet.exec_prompt = lambda p, response_format="text": {"verdict": "SPLIT", "reason_code": "MADE_UP", "reason": "x"}
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_trade", did)["reason_code"], "UNSPECIFIED")

    def test_stalled_dispute_can_be_closed(self):
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        with self.assertRaises(Exception):
            self.call(STRANGER, "close_stalled_dispute", did)
        self.ch.advance(168 * UNIT + 1)
        self.call(STRANGER, "close_stalled_dispute", did)
        d = self.view("get_trade", did)
        self.assertEqual(d["outcome"], "STALLED")
        self.assertEqual(d["compensation"], "0")
        self.assertEqual(self.view("get_claimable", TAKER), str(2 * GEN))
        self.assertEqual(self.view("get_trader", TRADER)["locked"], "0")
        self.check_accounting()

    def test_reopen_round_allows_more_evidence(self):
        self.verdicts = ["INSUFFICIENT_EVIDENCE"]
        did = self.disputed(4)
        self.call(TAKER, "submit_evidence", did, "second piece of proof", "")
        self.call(TAKER, "submit_evidence", did, "third piece of proof", "")
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.call(TAKER, "submit_evidence", did, "fourth piece of proof", "")
        self.call(TAKER, "submit_evidence", did, "fifth piece of proof", "")
        with self.assertRaises(Exception):
            self.call(TAKER, "submit_evidence", did, "sixth piece of proof", "")

    def test_rejected_taker_cannot_reclaim_same_trade(self):
        self.trader()
        did = self.trade()
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(TRADER, "respond_payment", did, False, "no money received")
        r = self.call(TAKER, "claim_payment", did, "bank ref 654321", value=GEN)
        self.assertEqual(r, "REFUNDED:claim_was_rejected")
        self.assertEqual(self.call(OTHER, "claim_payment", did, "bank ref 777777", value=GEN), "OK")
        self.check_accounting()

    def test_rejections_do_not_lower_score(self):
        self.trader()
        before = self.view("get_trader", TRADER)["score"]
        did = self.trade()
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(TRADER, "respond_payment", did, False, "no money received")
        s = self.view("get_trader", TRADER)
        self.assertEqual(s["score"], before)
        self.assertEqual(s["rejected_claims"], 1)

    def test_trusted_needs_taker_confirmed_trades(self):
        self.trader(50)
        for i in range(5):
            b = A(200 + i)
            self.ch.fund(b, 10 * GEN)
            did = self.trade(2)
            self.call(b, "claim_payment", did, "bank ref 123456", value=GEN)
            self.call(TRADER, "respond_payment", did, True, "")
            self.call(TRADER, "submit_release", did, "released ok", "")
            self.ch.advance(72 * UNIT + 1)
            self.call(STRANGER, "finalize_trade", did)
        s = self.view("get_trader", TRADER)
        self.assertEqual(s["completed_auto"], 5)
        self.assertFalse(s["trusted"])

    def test_late_release_is_allowed_and_visible(self):
        did = self.bound()
        self.ch.advance(50 * UNIT)
        self.call(TRADER, "submit_release", did, "released late", "")
        d = self.view("get_trade", did)
        self.assertEqual(d["status"], "RELEASED")
        self.assertGreater(d["released_at"], d["release_deadline"])

    def test_random_operations_keep_accounting_balanced(self):
        rng = random.Random(11)
        users = [A(300 + i) for i in range(6)]
        for u in users:
            self.ch.fund(u, 500 * GEN)
        traders = users[:2]
        takers = users[2:]
        self.call(traders[0], "register_trader", "alpha_desk", value=30 * GEN)
        self.call(traders[1], "register_trader", "beta_desk", value=12 * GEN)
        verdicts = ["TAKER_WINS", "TRADER_WINS", "SPLIT", "INSUFFICIENT_EVIDENCE"]
        seen = set()
        pend = [0]

        def act(who, m, *a, value=0):
            try:
                self.call(who, m, *a, value=value)
                seen.add(m)
            except Exception:
                pass

        for step in range(1500):
            self.ch.advance(rng.choice([0, 0, 60, UNIT, 6 * UNIT, 30 * UNIT, 60 * UNIT]))
            trades = json.loads(self.ch.c.list_trades(0, 100))["trades"]
            if not trades or rng.random() < 0.12:
                act(rng.choice(traders), "create_trade", "Asset " + str(step), "10", "", rng.choice([1, 2, 4]) * GEN, rng.choice([1, 24, 48]))
            else:
                live = [x for x in trades if x["status"] not in ("COMPLETED", "RESOLVED", "CANCELLED", "EXPIRED")]
                d = rng.choice(live) if live and rng.random() < 0.9 else rng.choice(trades)
                did = d["trade_id"]
                st = d["status"]
                wrong = rng.random() < 0.15
                trader = d["trader"]
                taker = d["taker"] or rng.choice(takers)
                anyone = rng.choice(users)
                if wrong:
                    who = anyone
                else:
                    who = None
                if st == "OPEN":
                    c = rng.choice(["claim", "claim", "cancel", "expire"])
                    if c == "claim":
                        act(who or rng.choice(takers), "claim_payment", did, "bank ref " + str(step) + "xx", value=GEN)
                    elif c == "cancel":
                        act(who or trader, "cancel_trade", did)
                    else:
                        act(anyone, "expire_offer", did)
                elif st == "PAYMENT_CLAIMED":
                    c = rng.choice(["accept", "reject", "timeout"])
                    if c == "timeout":
                        act(anyone, "bind_by_timeout", did)
                    else:
                        act(who or trader, "respond_payment", did, c == "accept", "no payment seen")
                elif st == "ACTIVE":
                    c = rng.choice(["release", "dispute", "finalize"])
                    if c == "release":
                        act(who or trader, "submit_release", did, "released ok", "")
                    elif c == "dispute":
                        act(who or taker, "open_dispute", did, "never arrived at all", "", value=rng.choice([GEN, GEN, 2 * GEN]))
                    else:
                        act(anyone, "finalize_trade", did)
                elif st == "RELEASED":
                    c = rng.choice(["confirm", "dispute", "finalize"])
                    if c == "confirm":
                        act(who or taker, "confirm_release", did)
                    elif c == "dispute":
                        act(who or taker, "open_dispute", did, "asset is not as described", "", value=GEN)
                    else:
                        act(anyone, "finalize_trade", did)
                elif st == "PAYOUT_PENDING":
                    pend[0] += 1
                    c = "challenge" if pend[0] % 2 else "finalize"
                    if c == "finalize":
                        self.ch.advance(168 * UNIT)
                        act(anyone, "finalize_payout", did)
                    else:
                        act(who or trader, "challenge_payout", did, "my bank shows nothing", "")
                elif st in ("DISPUTED", "REOPENED", "CHALLENGED"):
                    c = rng.choice(["evidence", "resolve", "resolve", "stalled"])
                    if c == "evidence":
                        act(who or rng.choice([taker, trader]), "submit_evidence", did, "some evidence text", "")
                    elif c == "resolve":
                        v = rng.choice(verdicts)
                        gl.nondet.exec_prompt = lambda p, response_format="text", v=v, r=rng.random() < 0.7: verdict_json(v, reviewed=r)
                        act(anyone, "resolve_dispute", did)
                    else:
                        act(anyone, "close_stalled_dispute", did)
            if rng.random() < 0.1:
                act(rng.choice(traders), "withdraw_bond", rng.choice([1, 3, 5]) * GEN)
            if rng.random() < 0.15:
                act(rng.choice(users), "claim")
            if rng.random() < 0.05:
                act(rng.choice(traders), "add_bond", value=2 * GEN)
            self.check_accounting()
            for sk in json.loads(self.ch.c.list_traders()):
                self.assertGreaterEqual(int(sk["bond"]), int(sk["locked"]))
                self.assertEqual(int(sk["locked"]) == 0, int(sk["active_trades"]) == 0)
        act(OWNER, "collect_fees")
        self.check_accounting()
        for needed in ("confirm_release", "open_dispute", "resolve_dispute", "finalize_trade", "claim", "finalize_payout", "challenge_payout"):
            self.assertIn(needed, seen)


class TestTimeoutCap(Base):
    def silent_dispute(self, protect=4):
        self.trader()
        did = self.trade(protect)
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.ch.advance(24 * UNIT)
        self.call(STRANGER, "bind_by_timeout", did)
        self.ch.advance(48 * UNIT + 1)
        self.call(TAKER, "open_dispute", did, "nothing was ever sent", "", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        return did

    def set_answer(self, v, reviewed):
        gl.nondet.exec_prompt = lambda p, response_format="text": verdict_json(v, reviewed=reviewed)

    def test_taker_win_on_silent_trade_is_capped(self):
        did = self.silent_dispute(4)
        self.set_answer("TAKER_WINS", True)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.ch.advance(168 * UNIT)
        self.call(STRANGER, "finalize_payout", did)
        d = self.view("get_trade", did)
        self.assertEqual(d["compensation"], str(GEN))
        self.assertEqual(d["comp_cap_bps"], 2500)
        self.assertTrue(d["payment_reviewed"])
        self.assertEqual(d["fee"], str(GEN * 500 // 10000))
        self.assertEqual(self.view("get_claimable", TAKER), str(3 * GEN))
        self.check_accounting()

    def test_split_on_silent_trade_is_capped(self):
        did = self.silent_dispute(4)
        self.set_answer("SPLIT", True)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.ch.advance(168 * UNIT)
        self.call(STRANGER, "finalize_payout", did)
        self.assertEqual(self.view("get_trade", did)["compensation"], str(GEN))

    def test_unreviewed_taker_win_is_downgraded_not_paid(self):
        did = self.silent_dispute(4)
        self.set_answer("TAKER_WINS", False)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "REOPENED")
        d = self.view("get_trade", did)
        self.assertEqual(d["compensation"], "0")
        self.assertFalse(d["payment_reviewed"])

    def test_trader_wins_needs_no_flag_on_silent_trade(self):
        did = self.silent_dispute(4)
        self.set_answer("TRADER_WINS", False)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_trade", did)["outcome"], "TRADER_WINS")

    def test_settle_itself_refuses_unreviewed_payout_on_silent_trade(self):
        did = self.silent_dispute(4)
        c = self.ch.c
        d = c.trades[did]
        with self.assertRaises(Exception):
            c._settle(d, "TAKER_WINS", "X", "r", False)

    def test_trader_confirmed_trade_keeps_full_compensation(self):
        self.verdicts = ["TAKER_WINS"]
        did = self.disputed(4)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        d = self.view("get_trade", did)
        self.assertEqual(d["compensation"], str(4 * GEN))
        self.assertEqual(d["comp_cap_bps"], 10000)

    def test_validators_must_agree_on_review_flag_for_silent_trades(self):
        did = self.silent_dispute(4)
        answers = [verdict_json("TAKER_WINS", reviewed=True), verdict_json("TAKER_WINS", reviewed=False)]
        gl.nondet.exec_prompt = lambda p, response_format="text": answers.pop(0)
        with self.assertRaises(Exception):
            self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(self.view("get_trade", did)["status"], "DISPUTED")


class TestUrlVectors(unittest.TestCase):
    def test_shared_vectors(self):
        import pathlib

        root = pathlib.Path(__file__).resolve().parent
        vec = json.loads((root / "url_vectors.json").read_text())
        from _bootstrap import Chain

        mod = Chain().mod
        for u in vec["valid"]:
            self.assertTrue(mod._url_ok(u), repr(u))
        for u in vec["invalid"]:
            self.assertFalse(mod._url_ok(u), repr(u))

    def test_solidity_vector_file_is_current(self):
        import importlib.util
        import pathlib

        root = pathlib.Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location("gen", root / "scripts" / "gen_url_tests.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        self.assertEqual((root / "base" / "test" / "UrlVectors.t.sol").read_text(), gen.render())


if __name__ == "__main__":
    unittest.main()
