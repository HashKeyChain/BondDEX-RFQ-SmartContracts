// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeConfig, Order} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";

contract US2RfqSettlementIntegrationTest is RFQSettlementFixtures {
    function setUp() public {
        deployRfqFixtures();
    }

    function test_multiMakerBatchSettlementAndFeeFlow() public {
        vm.prank(admin);
        settlement.setFeeConfig(FeeConfig({feeRecipient: feeRecipient, currentFeeBps: 50, maxFeeBps: 1_000}));

        Order[] memory orders = new Order[](2);
        bytes[] memory signatures = new bytes[](2);

        orders[0] = makeBuyOrder(10e18, 10_500e6, 0, 1);
        orders[1] = makeBuyOrderForMaker(otherMaker, 15e18, 15_750e6, 0, 2);

        signatures[0] = signOrder(orders[0], MAKER_PK);
        signatures[1] = signOrder(orders[1], OTHER_MAKER_PK);

        vm.prank(investor);
        settlement.batchFillOrders(orders, signatures);

        assertEq(bondToken.balanceOf(investor), 25e18);
        assertEq(usdc.balanceOf(feeRecipient), 131250000);
        assertTrue(settlement.isOrderConsumed(settlement.hashOrder(orders[0])));
        assertTrue(settlement.isOrderConsumed(settlement.hashOrder(orders[1])));
    }

    function test_cancelledOrderCannotBeFilledViaBatch() public {
        Order[] memory orders = new Order[](2);
        bytes[] memory signatures = new bytes[](2);

        orders[0] = makeBuyOrder(10e18, 10_500e6, 0, 1);
        orders[1] = makeBuyOrderForMaker(otherMaker, 15e18, 15_750e6, 0, 2);

        signatures[0] = signOrder(orders[0], MAKER_PK);
        signatures[1] = signOrder(orders[1], OTHER_MAKER_PK);

        vm.prank(maker);
        settlement.cancelOrder(orders[0]);

        vm.prank(investor);
        vm.expectRevert();
        settlement.batchFillOrders(orders, signatures);

        assertEq(bondToken.balanceOf(investor), 0);
    }
}
