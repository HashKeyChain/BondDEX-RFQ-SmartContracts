// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Order } from "../../src/types/BondTypes.sol";
import { RFQSettlementFixtures } from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementBatchTest is RFQSettlementFixtures {
    function setUp() public {
        deployRfqFixtures();
    }

    function test_batchFillOrdersExecutesAtomically() public {
        Order[] memory orders = new Order[](2);
        bytes[] memory signatures = new bytes[](2);

        orders[0] = makeBuyOrder(10e18, 10_500e6, 0, 1);
        orders[1] = makeBuyOrderForMaker(otherMaker, 15e18, 15_750e6, 0, 2);

        signatures[0] = signOrder(orders[0], MAKER_PK);
        signatures[1] = signOrder(orders[1], OTHER_MAKER_PK);

        vm.prank(investor);
        settlement.batchFillOrders(orders, signatures);

        assertEq(bondToken.balanceOf(investor), 25e18);
        assertTrue(settlement.isOrderConsumed(settlement.hashOrder(orders[0])));
        assertTrue(settlement.isOrderConsumed(settlement.hashOrder(orders[1])));
    }

    function test_batchRevertsFullyWhenOneOrderIsInvalid() public {
        Order[] memory orders = new Order[](2);
        bytes[] memory signatures = new bytes[](2);

        orders[0] = makeBuyOrder(10e18, 10_500e6, 0, 1);
        orders[1] = makeBuyOrderForMaker(otherMaker, 15e18, 15_750e6, 0, 2);
        orders[1].expiry = block.timestamp - 1;

        signatures[0] = signOrder(orders[0], MAKER_PK);
        signatures[1] = signOrder(orders[1], OTHER_MAKER_PK);

        vm.prank(investor);
        vm.expectRevert();
        settlement.batchFillOrders(orders, signatures);

        assertEq(bondToken.balanceOf(investor), 0);
        assertFalse(settlement.isOrderConsumed(settlement.hashOrder(orders[0])));
    }

    function test_revertWhenBatchSizeExceedsCap() public {
        Order[] memory orders = new Order[](25);
        bytes[] memory signatures = new bytes[](25);

        for (uint256 i = 0; i < orders.length; i++) {
            orders[i] = makeBuyOrder(1e18, 1_000e6, i, i + 1);
            signatures[i] = signOrder(orders[i], MAKER_PK);
        }

        vm.prank(investor);
        vm.expectRevert();
        settlement.batchFillOrders(orders, signatures);
    }
}
