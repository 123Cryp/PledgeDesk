// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PledgeDeskBase.sol";

abstract contract ParityBase is Test {
    struct Obs {
        bool reverted;
        uint8 status;
        uint8 verdict;
        uint256 compensation;
        uint256 fee;
        uint256 takerClaimable;
        uint256 traderClaimable;
        uint256 treasury;
        uint256 traderBond;
        uint256 traderLocked;
        uint256 lost;
        uint256 split;
        uint256 won;
        uint256 inconclusive;
    }

    uint256 internal constant U = 0.001 ether;
    uint256 internal constant H = 3600;

    function _run(uint256 protectUnits, bool silent, uint8[] memory kinds, uint8[] memory verdicts, bool[] memory reviewed) internal returns (Obs memory o) {
        address arbiter = makeAddr("arbiter");
        address trader = makeAddr("trader");
        address taker = makeAddr("taker");
        PledgeDeskBase pd = new PledgeDeskBase(arbiter, H);
        vm.deal(trader, 100 ether);
        vm.deal(taker, 100 ether);

        vm.prank(trader);
        pd.registerTrader{value: 50 * U}("parity_desk");
        vm.prank(trader);
        uint256 id = pd.createTrade("Parity asset", "1 USD", "", protectUnits * U, 48);
        vm.prank(taker);
        pd.claimPayment{value: U}(id, "bank ref 123456");
        if (silent) {
            vm.warp(block.timestamp + 24 * H);
            pd.bindByTimeout(id);
        } else {
            vm.prank(trader);
            pd.respondPayment(id, true, "");
        }
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(taker);
        pd.openDispute{value: U}(id, "nothing was ever sent", "");
        vm.warp(block.timestamp + 48 * H + 1);

        for (uint256 i = 0; i < kinds.length; i++) {
            if (kinds[i] == 1) {
                vm.prank(trader);
                pd.challengePayout(id, "I never saw this payment", "");
            } else if (kinds[i] == 2) {
                vm.warp(block.timestamp + 168 * H);
                pd.finalizePayout(id);
            } else {
                if (i > 0) vm.warp(block.timestamp + 24 * H + 1);
                vm.prank(arbiter);
                try pd.resolveDispute(id, PledgeDeskBase.Verdict(verdicts[i]), bytes32("PARITY"), "parity", reviewed[i]) {} catch {
                    o.reverted = true;
                    break;
                }
            }
        }

        PledgeDeskBase.Trade memory d = pd.getTrade(id);
        PledgeDeskBase.TraderInfo memory s = pd.traderInfo(trader);
        o.status = uint8(d.status);
        o.verdict = uint8(d.verdict);
        o.compensation = d.compensation;
        o.fee = d.fee;
        o.takerClaimable = pd.claimable(taker);
        o.traderClaimable = pd.claimable(trader);
        o.treasury = pd.treasury();
        o.traderBond = s.bond;
        o.traderLocked = s.locked;
        o.lost = s.disputesLost;
        o.split = s.disputesSplit;
        o.won = s.disputesWon;
        o.inconclusive = s.inconclusive;
    }
}
