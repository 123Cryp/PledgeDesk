import json
import unittest

from _bootstrap import gl
from test_pledgedesk import Base, GEN, UNIT, OWNER, TAKER, TRADER, STRANGER, OTHER, verdict_json


class TestDefenses(Base):
    def silent_disputed(self, protect=4):
        self.trader()
        did = self.trade(protect)
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.ch.advance(24 * UNIT)
        self.call(STRANGER, "bind_by_timeout", did)
        self.ch.advance(48 * UNIT + 1)
        self.call(TAKER, "open_dispute", did, "nothing was ever sent", "", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        return did

    def rule(self, v, reviewed=True):
        gl.nondet.exec_prompt = lambda p, response_format="text": verdict_json(v, reviewed=reviewed)

    def status(self, did):
        return json.loads(self.ch.c.get_trade(did))["status"]

    def test_claim_deposit_must_be_exact(self):
        self.trader()
        did = self.trade()
        for amt in (GEN // 2, 2 * GEN, 0):
            r = self.call(TAKER, "claim_payment", did, "bank ref 123456", value=amt)
            self.assertEqual(r, "REFUNDED:wrong_deposit")
        self.assertEqual(self.status(did), "OPEN")
        self.call(TAKER, "claim")
        self.check_accounting()

    def test_rejected_claim_deposit_is_burned_not_paid_to_anyone(self):
        self.trader()
        did = self.trade()
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(TRADER, "respond_payment", did, False, "no money received")
        acc = json.loads(self.ch.c.get_accounting())
        self.assertEqual(int(acc["burned"]), GEN)
        self.assertEqual(int(acc["treasury"]), 0)
        self.assertEqual(self.view("get_claimable", TRADER), "0")
        with self.assertRaises(Exception):
            self.call(OWNER, "collect_fees")
        self.assertEqual(json.loads(self.ch.c.get_trade(did))["claim_deposit"], "0")
        r = self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.assertTrue(r.startswith("REFUNDED"))
        self.check_accounting()

    def test_claim_deposit_returned_on_completion(self):
        did = self.released()
        self.call(TAKER, "confirm_release", did)
        self.assertEqual(self.view("get_claimable", TAKER), str(GEN))
        self.check_accounting()

    def test_claim_deposit_returned_on_lapse(self):
        did = self.bound()
        self.ch.advance(48 * UNIT + 168 * UNIT + 1)
        self.call(STRANGER, "finalize_trade", did)
        self.assertEqual(self.view("get_claimable", TAKER), str(GEN))
        self.check_accounting()

    def test_silent_taker_win_is_delayed_not_paid(self):
        did = self.silent_disputed()
        self.rule("TAKER_WINS")
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.assertEqual(self.view("get_claimable", TAKER), "0")
        with self.assertRaises(Exception):
            self.call(STRANGER, "finalize_payout", did)
        self.check_accounting()
        self.ch.advance(168 * UNIT)
        self.call(STRANGER, "finalize_payout", did)
        d = json.loads(self.ch.c.get_trade(did))
        self.assertEqual(d["status"], "RESOLVED")
        self.assertEqual(int(d["compensation"]), GEN)
        self.assertEqual(self.view("get_claimable", TAKER), str(GEN + GEN + GEN))
        self.check_accounting()

    def test_only_trader_can_challenge(self):
        did = self.silent_disputed()
        self.rule("TAKER_WINS")
        self.call(STRANGER, "resolve_dispute", did)
        with self.assertRaises(Exception):
            self.call(STRANGER, "challenge_payout", did, "I never saw this payment", "")
        with self.assertRaises(Exception):
            self.call(TAKER, "challenge_payout", did, "I never saw this payment", "")

    def test_challenge_window_closes(self):
        did = self.silent_disputed()
        self.rule("TAKER_WINS")
        self.call(STRANGER, "resolve_dispute", did)
        self.ch.advance(168 * UNIT)
        with self.assertRaises(Exception):
            self.call(TRADER, "challenge_payout", did, "too late to object", "")

    def test_challenge_then_trader_wins(self):
        did = self.silent_disputed()
        self.rule("TAKER_WINS")
        self.call(STRANGER, "resolve_dispute", did)
        self.call(TRADER, "challenge_payout", did, "My bank shows no incoming transfer", "https://example.com/stmt")
        self.assertEqual(self.status(did), "CHALLENGED")
        self.ch.advance(24 * UNIT + 1)
        self.rule("TRADER_WINS", reviewed=False)
        self.call(STRANGER, "resolve_dispute", did)
        d = json.loads(self.ch.c.get_trade(did))
        self.assertEqual(d["compensation"], "0")
        self.assertEqual(self.view("get_claimable", TRADER), str(2 * GEN))
        self.assertEqual(self.view("get_claimable", TAKER), "0")
        self.check_accounting()

    def test_challenged_ruling_pays_immediately_and_stays_capped(self):
        did = self.silent_disputed()
        self.rule("TAKER_WINS")
        self.call(STRANGER, "resolve_dispute", did)
        self.call(TRADER, "challenge_payout", did, "My bank shows no incoming transfer", "")
        self.ch.advance(24 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        d = json.loads(self.ch.c.get_trade(did))
        self.assertEqual(d["status"], "RESOLVED")
        self.assertEqual(int(d["compensation"]), GEN)
        self.check_accounting()

    def test_confirmed_trade_pays_without_delay(self):
        did = self.disputed()
        self.ch.advance(48 * UNIT + 1)
        self.rule("TAKER_WINS")
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "TAKER_WINS")
        self.assertEqual(int(json.loads(self.ch.c.get_trade(did))["compensation"]), 4 * GEN)
        self.check_accounting()

    def test_trusted_needs_unique_takers_and_age(self):
        self.trader(50)
        for k in range(6):
            b = TAKER if k % 2 == 0 else OTHER
            did = self.call(TRADER, "create_trade", "Red handbag", "40 USD", "", 2 * GEN, 48)
            self.call(b, "claim_payment", did, "bank ref 123456", value=GEN)
            self.call(TRADER, "respond_payment", did, True, "")
            self.call(TRADER, "submit_release", did, "released ok", "")
            self.call(b, "confirm_release", did)
        self.ch.advance(340 * UNIT)
        s = self.view("get_trader", TRADER)
        self.assertEqual(int(s["unique_takers"]), 2)
        self.assertFalse(s["trusted"])

    def test_links_are_never_opened(self):
        fetched = []
        gl.nondet.web.render = lambda url, mode="text": fetched.append(url) or "page"
        seen = []

        def fake(prompt, response_format="text"):
            seen.append(prompt)
            return verdict_json("TRADER_WINS", reviewed=False)

        gl.nondet.exec_prompt = fake
        self.trader()
        did = self.trade()
        self.call(TAKER, "claim_payment", did, "bank ref 123456", value=GEN)
        self.call(TRADER, "respond_payment", did, True, "")
        self.call(TRADER, "submit_release", did, "released with tx hash", "https://i.imgur.com/t.png")
        self.call(TAKER, "open_dispute", did, "crypto never arrived at all", "https://i.imgur.com/a.png", value=GEN)
        self.ch.advance(48 * UNIT + 1)
        self.call(STRANGER, "resolve_dispute", did)
        self.assertEqual(fetched, [])
        self.assertIn("reference link, not opened", seen[0])

    def test_trader_can_challenge_after_using_all_evidence_slots(self):
        did = self.silent_disputed()
        self.rule("INSUFFICIENT_EVIDENCE", reviewed=False)
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "REOPENED")
        for i in range(5):
            self.call(TRADER, "submit_evidence", did, "trader evidence number %d" % i, "")
        self.ch.advance(24 * UNIT + 1)
        self.rule("TAKER_WINS")
        self.assertEqual(self.call(STRANGER, "resolve_dispute", did), "PAYOUT_PENDING")
        self.assertEqual(self.call(TRADER, "challenge_payout", did, "My bank shows no incoming transfer", ""), "CHALLENGED")
        self.call(TAKER, "submit_evidence", did, "taker reply to the challenge", "")
        self.call(TRADER, "submit_evidence", did, "trader follow-up after challenge", "")
        self.check_accounting()

if __name__ == "__main__":
    unittest.main()
