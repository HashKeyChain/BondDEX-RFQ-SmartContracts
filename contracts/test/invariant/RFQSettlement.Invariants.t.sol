// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {Order} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementHandler is RFQSettlementFixtures {
    Order internal trackedOrder;
    bytes internal trackedSignature;
    bytes32 internal trackedHash;

    bool internal cancelled;
    uint256 internal fillAttempts;

    constructor() {
        deployRfqFixtures();
        trackedOrder = makeBuyOrder(10e18, 10_500e6, 0, 1);
        trackedSignature = signOrder(trackedOrder, MAKER_PK);
        trackedHash = settlement.hashOrder(trackedOrder);
    }

    function cancelTrackedOrder() external {
        if (cancelled || settlement.isOrderConsumed(trackedHash)) {
            return;
        }

        vm.prank(maker);
        settlement.cancelOrder(trackedOrder);
        cancelled = true;
    }

    function fillTrackedOrder() external {
        fillAttempts++;
        vm.prank(investor);
        try settlement.fillOrder(trackedOrder, trackedSignature) {} catch {}
    }

    function trackedOrderHash() external view returns (bytes32) {
        return trackedHash;
    }

    function trackedOrderCancelled() external view returns (bool) {
        return cancelled;
    }

    function trackedOrderConsumed() external view returns (bool) {
        return settlement.isOrderConsumed(trackedHash);
    }
}

contract RFQSettlementInvariantsTest is StdInvariant, Test {
    RFQSettlementHandler internal handler;

    function setUp() public {
        handler = new RFQSettlementHandler();
        targetContract(address(handler));
    }

    function invariant_consumedOrCancelledOrderCannotBeReopened() public view {
        if (handler.trackedOrderCancelled()) {
            assertFalse(handler.trackedOrderConsumed());
        }
    }
}
