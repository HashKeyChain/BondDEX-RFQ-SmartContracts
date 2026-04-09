// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";
import {InvalidOrderNonce} from "../../src/libraries/BondErrors.sol";

contract RFQSettlementNonceAndCancelGuardsTest is RFQSettlementFixtures {
    event NonceIncremented(address indexed maker, uint256 newMinimumValidNonce);

    function setUp() public {
        deployRfqFixtures();
    }

    // ─── setMinimumNonce ────────────────────────────────────────

    function test_setMinimumNonceJumpsNonceFloor() public {
        vm.expectEmit(true, false, false, true);
        emit NonceIncremented(maker, 100);

        vm.prank(maker);
        settlement.setMinimumNonce(100);

        assertEq(settlement.currentNonce(maker), 100);
    }

    function test_setMinimumNonceInvalidatesOlderOrders() public {
        Order memory staleOrder = makeBuyOrder(10e18, 10_500e6, 50, 1);
        bytes memory staleSignature = signOrder(staleOrder, MAKER_PK);

        vm.prank(maker);
        settlement.setMinimumNonce(100);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(staleOrder, staleSignature);
    }

    function test_revertWhenSetMinimumNonceTooLow() public {
        vm.prank(maker);
        settlement.incrementNonce();

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidOrderNonce.selector, maker, 1, 2)
        );
        settlement.setMinimumNonce(1);
    }

    function test_revertWhenSetMinimumNonceEqualToCurrent() public {
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidOrderNonce.selector, maker, 0, 1)
        );
        settlement.setMinimumNonce(0);
    }

    // ─── isOrderCancelled ───────────────────────────────────────

    function test_isOrderCancelledReturnsTrueAfterCancel() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes32 orderHash = settlement.hashOrder(order);

        assertFalse(settlement.isOrderCancelled(orderHash));

        vm.prank(maker);
        settlement.cancelOrder(order);

        assertTrue(settlement.isOrderCancelled(orderHash));
    }

    function test_isOrderCancelledReturnsFalseForConsumedOrder() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes memory signature = signOrder(order, MAKER_PK);
        bytes32 orderHash = settlement.hashOrder(order);

        vm.prank(investor);
        settlement.fillOrder(order, signature);

        assertTrue(settlement.isOrderConsumed(orderHash));
        assertFalse(settlement.isOrderCancelled(orderHash));
    }

    function test_isOrderCancelledReturnsFalseForUnknownHash() public {
        assertFalse(settlement.isOrderCancelled(keccak256("random")));
    }
}
