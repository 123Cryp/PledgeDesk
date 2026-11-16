// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PledgeDeskBase.sol";

contract PledgeDeskBaseTest is Test {
    PledgeDeskBase pd;
    address owner = makeAddr("owner");
    address arbiter = makeAddr("arbiter");
    address trader = makeAddr("trader");
    address taker = makeAddr("taker");
    address stranger = makeAddr("stranger");
    uint256 constant U = 0.001 ether;
    uint256 constant H = 3600;

    function setUp() public {
        vm.prank(owner);
        pd = new PledgeDeskBase(arbiter, H);
        vm.trade(trader, 10 ether);
        vm.trade(taker, 10 ether);
        vm.trade(stranger, 10 ether);
    }

    function _register(uint256 bond) internal {
        vm.prank(trader);
        pd.registerTrader{value: bond}("desk_one");
    }

    function _trade(uint256 protect) internal returns (uint256 id) {
        vm.prank(trader);
        id = pd.createTrade("Red handbag", "40 USD", "https://example.com/p/1", protect, 48);
    }

    function _bound(uint256 protect) internal returns (uint256 id) {
        _register(20 * U);
        id = _trade(protect);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(trader);
        pd.respondPayment(id, true, "");
    }

    function _released(uint256 protect) internal returns (uint256 id) {
        id = _bound(protect);
        vm.prank(trader);
        pd.submitRelease(id, "released with tx hash", "https://example.com/t/1");
    }

    function _disputed(uint256 protect) internal returns (uint256 id) {
        id = _released(protect);
        vm.prank(taker);
        pd.openDispute{value: U}(id, "crypto never arrived at all", "");
    }

    function _accounting() internal view {
        uint256 total = pd.totalBonds() + pd.totalClaimable() + pd.treasury() + pd.burned() + pd.depositsHeld();
        assertEq(address(pd).balance, total);
    }

    function test_register_and_level() public {
        _register(20 * U);
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.level), 1);
        assertEq(i.nick, "desk_one");
        assertEq(pd.traderByAlias("desk_one"), trader);
        _accounting();
    }

    function test_register_rejects_bad_input() public {
        vm.prank(trader);
        vm.expectRevert("bond below minimum");
        pd.registerTrader{value: U}("desk_one");
        vm.prank(trader);
        vm.expectRevert("invalid alias");
        pd.registerTrader{value: 6 * U}("Bad Alias");
        _register(6 * U);
        vm.prank(stranger);
        vm.expectRevert("alias taken");
        pd.registerTrader{value: 6 * U}("desk_one");
    }

    function test_create_locks_bond_and_caps() public {
        _register(20 * U);
        _trade(4 * U);
        assertEq(pd.traderInfo(trader).locked, 6 * U);
        vm.prank(trader);
        vm.expectRevert("protect above level cap");
        pd.createTrade("Another asset", "1", "", 11 * U, 5);
        vm.prank(trader);
        vm.expectRevert("bad url");
        pd.createTrade("Another asset", "1", "http://x.com", 2 * U, 5);
        vm.prank(trader);
        vm.expectRevert("bad url");
        pd.createTrade("Another asset", "1", "https://user:pw@x.com/a", 2 * U, 5);
    }

    function test_happy_path() public {
        uint256 id = _released(4 * U);
        vm.prank(taker);
        pd.confirmRelease(id);
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.completedVerified), 1);
        assertEq(i.locked, 0);
        assertGt(i.score, 500);
        _accounting();
    }

    function test_reject_reopens_offer() public {
        _register(20 * U);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(trader);
        pd.respondPayment(id, false, "no money received");
        PledgeDeskBase.Trade memory d = pd.getTrade(id);
        assertEq(uint256(d.status), uint256(PledgeDeskBase.Status.OPEN));
        assertEq(d.taker, address(0));
        assertEq(uint256(pd.traderInfo(trader).rejectedClaims), 1);
    }

    function test_timeout_binding() public {
        _register(20 * U);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(stranger);
        vm.expectRevert("trader still has time");
        pd.bindByTimeout(id);
        vm.warp(block.timestamp + 24 * H);
        vm.prank(stranger);
        pd.bindByTimeout(id);
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.ACTIVE));
    }

    function test_auto_finalize_and_lapse() public {
        uint256 id = _released(4 * U);
        vm.expectRevert("review window open");
        pd.finalizeTrade(id);
        vm.warp(block.timestamp + 72 * H + 1);
        pd.finalizeTrade(id);
        assertEq(uint256(pd.traderInfo(trader).completedAuto), 1);
    }

    function test_lapsed_when_nobody_acts() public {
        uint256 id = _bound(4 * U);
        vm.warp(block.timestamp + 48 * H + 72 * H + 1);
        pd.finalizeTrade(id);
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.lapsed), 1);
        assertEq(i.locked, 0);
    }

    function test_taker_wins_pays_from_bond() public {
        uint256 id = _disputed(4 * U);
        vm.prank(trader);
        pd.submitEvidence(id, "I posted it yesterday", "https://example.com/t/1");
        vm.prank(arbiter);
        vm.expectRevert("evidence window open");
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "none", true);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(stranger);
        vm.expectRevert("only arbiter");
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("X"), "x", true);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "none", true);
        uint256 fee = (4 * U * 500) / 10000;
        assertEq(pd.claimable(taker), 4 * U + U + U);
        assertEq(pd.treasury(), fee);
        assertEq(pd.traderInfo(trader).bond, 20 * U - 4 * U - fee);
        assertEq(pd.traderInfo(trader).locked, 0);
        _accounting();
        uint256 before = taker.balance;
        vm.prank(taker);
        pd.claim();
        assertEq(taker.balance, before + 6 * U);
        vm.prank(owner);
        pd.collectFees();
        vm.prank(owner);
        pd.claim();
        _accounting();
    }

    function test_trader_wins_gets_deposit() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TRADER_WINS, bytes32("RELEASE_PROOF_CREDIBLE"), "ok", true);
        assertEq(pd.claimable(trader), 2 * U);
        assertEq(pd.claimable(taker), 0);
        assertEq(uint256(pd.traderInfo(trader).disputesWon), 1);
        _accounting();
    }

    function test_split() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.SPLIT, bytes32("PARTIAL_OR_MISMATCH"), "half", true);
        assertEq(pd.getTrade(id).compensation, 2 * U);
        assertEq(pd.claimable(taker), 4 * U);
        _accounting();
    }

    function test_insufficient_reopens_then_inconclusive() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.REOPENED));
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        assertEq(pd.getTrade(id).compensation, 0);
        assertEq(pd.claimable(taker), 2 * U);
        assertEq(pd.traderInfo(trader).locked, 0);
        _accounting();
    }

    function test_arbiter_timeout_is_inconclusive() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.expectRevert("arbiter still has time");
        pd.resolveTimeout(id);
        vm.warp(block.timestamp + 168 * H + 1);
        pd.resolveTimeout(id);
        assertEq(pd.getTrade(id).compensation, 0);
        assertEq(pd.claimable(taker), 2 * U);
        _accounting();
    }

    function test_dispute_guards() public {
        uint256 id = _bound(4 * U);
        vm.prank(taker);
        vm.expectRevert("not disputable now");
        pd.openDispute{value: U}(id, "too early to complain", "");
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(stranger);
        vm.expectRevert("only taker");
        pd.openDispute{value: U}(id, "not my trade at all", "");
        vm.prank(taker);
        vm.expectRevert("wrong deposit");
        pd.openDispute{value: U / 2}(id, "claim text long enough", "");
        vm.prank(taker);
        vm.expectRevert("wrong deposit");
        pd.openDispute{value: 2 * U}(id, "claim text long enough", "");
        vm.prank(taker);
        pd.openDispute{value: U}(id, "claim text long enough", "");
        _accounting();
    }

    function test_evidence_limit() public {
        uint256 id = _disputed(4 * U);
        vm.startPrank(taker);
        pd.submitEvidence(id, "second piece of proof", "");
        pd.submitEvidence(id, "third piece of proof", "");
        vm.expectRevert("evidence limit");
        pd.submitEvidence(id, "fourth piece of proof", "");
        vm.stopPrank();
        assertEq(pd.getEvidence(id).length, 3);
        vm.prank(stranger);
        vm.expectRevert("only parties");
        pd.submitEvidence(id, "outsider text here", "");
    }

    function test_pair_credit_limit() public {
        _register(50 * U);
        for (uint256 k = 0; k < 5; k++) {
            vm.prank(trader);
            uint256 id = pd.createTrade("Red handbag", "40 USD", "", 2 * U, 5);
            vm.prank(taker);
            pd.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(trader);
            pd.respondPayment(id, true, "");
            vm.prank(trader);
            pd.submitRelease(id, "released ok", "");
            vm.prank(taker);
            pd.confirmRelease(id);
        }
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.completedVerified), 3);
        assertFalse(i.trusted);
    }

    function test_withdraw_limited_by_lock() public {
        _register(20 * U);
        _trade(4 * U);
        vm.prank(trader);
        vm.expectRevert("exceeds free bond");
        pd.withdrawBond(15 * U);
        vm.prank(trader);
        pd.withdrawBond(14 * U);
        vm.prank(trader);
        pd.claim();
        _accounting();
    }

    function test_only_owner_can_propose_arbiter() public {
        vm.prank(stranger);
        vm.expectRevert("only owner");
        pd.proposeArbiter(stranger);
        vm.prank(owner);
        pd.proposeArbiter(stranger);
        assertEq(pd.arbiter(), arbiter);
        assertEq(pd.pendingArbiter(), stranger);
    }

    function test_arbiter_change_is_timelocked() public {
        address other = makeAddr("other_arbiter");
        vm.prank(owner);
        pd.proposeArbiter(other);
        vm.expectRevert("change is still locked");
        pd.applyArbiterChange();
        vm.warp(block.timestamp + 168 * H);
        pd.applyArbiterChange();
        assertEq(pd.arbiter(), other);
        assertEq(pd.pendingArbiter(), address(0));
    }

    function test_arbiter_proposal_can_be_cancelled() public {
        vm.prank(owner);
        pd.proposeArbiter(stranger);
        vm.prank(owner);
        pd.cancelArbiterChange();
        vm.warp(block.timestamp + 168 * H);
        vm.expectRevert("nothing proposed");
        pd.applyArbiterChange();
    }

    function test_arbiter_change_does_not_affect_open_dispute() public {
        uint256 id = _disputed(4 * U);
        address other = makeAddr("other_arbiter");
        vm.prank(owner);
        pd.proposeArbiter(other);
        vm.warp(block.timestamp + 168 * H);
        pd.applyArbiterChange();
        assertEq(pd.arbiter(), other);
        vm.prank(other);
        vm.expectRevert("only arbiter");
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("X"), "x", true);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TRADER_WINS, bytes32("RELEASE_PROOF_CREDIBLE"), "ok", true);
        _accounting();
    }

    function test_rejected_taker_cannot_reclaim() public {
        _register(20 * U);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(trader);
        pd.respondPayment(id, false, "no money received");
        vm.prank(taker);
        vm.expectRevert("claim was rejected");
        pd.claimPayment{value: U}(id, "bank ref 654321");
        vm.prank(stranger);
        pd.claimPayment{value: U}(id, "bank ref 777777");
    }

    function test_reopen_allows_more_evidence() public {
        uint256 id = _disputed(4 * U);
        vm.startPrank(taker);
        pd.submitEvidence(id, "second piece of proof", "");
        pd.submitEvidence(id, "third piece of proof", "");
        vm.stopPrank();
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        vm.startPrank(taker);
        pd.submitEvidence(id, "fourth piece of proof", "");
        pd.submitEvidence(id, "fifth piece of proof", "");
        vm.expectRevert("evidence limit");
        pd.submitEvidence(id, "sixth piece of proof", "");
        vm.stopPrank();
    }

    function test_trusted_needs_taker_confirmed_trades() public {
        _register(50 * U);
        for (uint256 k = 0; k < 5; k++) {
            address b = makeAddr(string(abi.encodePacked("taker", vm.toString(k))));
            vm.trade(b, 10 ether);
            vm.prank(trader);
            uint256 id = pd.createTrade("Red handbag", "40 USD", "", 2 * U, 5);
            vm.prank(b);
            pd.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(trader);
            pd.respondPayment(id, true, "");
            vm.prank(trader);
            pd.submitRelease(id, "released ok", "");
            vm.warp(block.timestamp + 72 * H + 1);
            pd.finalizeTrade(id);
        }
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.completedAuto), 5);
        assertFalse(i.trusted);
    }

    function test_rejection_does_not_lower_score() public {
        _register(20 * U);
        uint256 before = pd.traderScore(trader);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(trader);
        pd.respondPayment(id, false, "no money received");
        assertEq(pd.traderScore(trader), before);
    }

    function test_bad_unit_rejected() public {
        vm.expectRevert("bad unit");
        new PledgeDeskBase(arbiter, 86401);
    }

    function _timeoutDisputed(uint256 protect) internal returns (uint256 id) {
        _register(20 * U);
        id = _trade(protect);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.warp(block.timestamp + 24 * H);
        pd.bindByTimeout(id);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(taker);
        pd.openDispute{value: U}(id, "nothing was ever sent", "");
        vm.warp(block.timestamp + 48 * H + 1);
    }

    function test_timeout_trade_taker_win_is_capped_at_25_percent() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.PAYOUT_PENDING));
        vm.expectRevert("payout is still locked");
        pd.finalizePayout(id);
        vm.warp(block.timestamp + 168 * H);
        pd.finalizePayout(id);
        PledgeDeskBase.Trade memory d = pd.getTrade(id);
        assertEq(d.compensation, U);
        assertTrue(d.paymentEvidenceReviewed);
        assertEq(pd.claimable(taker), 3 * U);
        _accounting();
    }

    function test_timeout_trade_split_is_capped_at_25_percent() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.SPLIT, bytes32("PARTIAL_OR_MISMATCH"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        pd.finalizePayout(id);
        assertEq(pd.getTrade(id).compensation, U);
        _accounting();
    }

    function test_timeout_trade_needs_review_flag_for_compensation() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        vm.expectRevert("payment evidence not reviewed");
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", false);
        vm.prank(arbiter);
        vm.expectRevert("payment evidence not reviewed");
        pd.resolveDispute(id, PledgeDeskBase.Verdict.SPLIT, bytes32("PARTIAL_OR_MISMATCH"), "x", false);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TRADER_WINS, bytes32("TAKER_CLAIM_UNSUPPORTED"), "x", false);
        assertEq(pd.getTrade(id).compensation, 0);
        _accounting();
    }

    function test_timeout_trade_arbiter_cannot_exceed_cap_even_if_flagged() public {
        uint256 id = _timeoutDisputed(10 * U);
        uint256 bondBefore = pd.traderInfo(trader).bond;
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        pd.finalizePayout(id);
        uint256 comp = (10 * U * 2500) / 10000;
        uint256 fee = (comp * 500) / 10000;
        assertEq(bondBefore - pd.traderInfo(trader).bond, comp + fee);
    }

    function test_timeout_trade_inconclusive_needs_no_flag() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "x", false);
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.REOPENED));
    }

    function test_claim_deposit_must_be_exact() public {
        _register(20 * U);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        vm.expectRevert("wrong deposit");
        pd.claimPayment{value: U / 2}(id, "bank ref 123456");
        vm.prank(taker);
        vm.expectRevert("wrong deposit");
        pd.claimPayment{value: 2 * U}(id, "bank ref 123456");
    }

    function test_rejected_claim_deposit_is_burned() public {
        _register(20 * U);
        uint256 id = _trade(4 * U);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(trader);
        pd.respondPayment(id, false, "no money received");
        assertEq(pd.burned(), U);
        assertEq(pd.treasury(), 0);
        assertEq(pd.claimable(trader), 0);
        assertEq(pd.getTrade(id).claimDeposit, 0);
        _accounting();
    }

    function test_claim_deposit_returned_on_completion() public {
        uint256 id = _released(4 * U);
        vm.prank(taker);
        pd.confirmRelease(id);
        assertEq(pd.claimable(taker), U);
        _accounting();
    }

    function test_trader_can_challenge_pending_payout() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        vm.prank(stranger);
        vm.expectRevert("only trader");
        pd.challengePayout(id, "I never saw this payment", "");
        vm.prank(trader);
        pd.challengePayout(id, "My bank shows no incoming transfer", "https://example.com/stmt");
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.CHALLENGED));
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TRADER_WINS, bytes32("TAKER_CLAIM_UNSUPPORTED"), "x", false);
        assertEq(pd.getTrade(id).compensation, 0);
        assertEq(pd.claimable(trader), 2 * U);
        assertEq(pd.claimable(taker), 0);
        _accounting();
    }

    function test_challenge_window_closes() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        vm.prank(trader);
        vm.expectRevert("challenge window closed");
        pd.challengePayout(id, "too late to object", "");
    }

    function test_challenged_ruling_pays_immediately_and_stays_capped() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        vm.prank(trader);
        pd.challengePayout(id, "My bank shows no incoming transfer", "");
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.RESOLVED));
        assertEq(pd.getTrade(id).compensation, U);
        _accounting();
    }

    function test_trusted_needs_age_and_unique_takers() public {
        _register(50 * U);
        for (uint256 k = 0; k < 6; k++) {
            address b = makeAddr(string(abi.encodePacked("rep", vm.toString(k % 2))));
            vm.trade(b, 100 ether);
            vm.prank(trader);
            uint256 id = pd.createTrade("Red handbag", "40 USD", "", 2 * U, 5);
            vm.prank(b);
            pd.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(trader);
            pd.respondPayment(id, true, "");
            vm.prank(trader);
            pd.submitRelease(id, "released ok", "");
            vm.prank(b);
            pd.confirmRelease(id);
        }
        vm.warp(block.timestamp + 340 * H);
        PledgeDeskBase.TraderInfo memory i = pd.traderInfo(trader);
        assertEq(uint256(i.completedVerified), 6);
        assertEq(uint256(i.uniqueTakers), 2);
        assertFalse(i.trusted);
    }

    function test_trader_can_challenge_after_using_all_evidence_slots() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "x", false);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(trader);
            pd.submitEvidence(id, "trader evidence text", "");
        }
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        pd.resolveDispute(id, PledgeDeskBase.Verdict.TAKER_WINS, bytes32("NO_RELEASE_PROOF"), "x", true);
        vm.prank(trader);
        pd.challengePayout(id, "My bank shows no incoming transfer", "");
        assertEq(uint256(pd.getTrade(id).status), uint256(PledgeDeskBase.Status.CHALLENGED));
        vm.prank(taker);
        pd.submitEvidence(id, "taker reply to the challenge", "");
        vm.prank(trader);
        pd.submitEvidence(id, "trader follow-up after challenge", "");
        _accounting();
    }
}
