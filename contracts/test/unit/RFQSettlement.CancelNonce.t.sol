// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Order } from "../../src/types/BondTypes.sol";
import { RFQSettlementFixtures } from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementCancelNonceTest is RFQSettlementFixtures {
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker, address canceller);
    event NonceIncremented(address indexed maker, uint256 newMinimumValidNonce);

    function setUp() public {
        deployRfqFixtures();
    }

    function test_cancelOrderBlocksFutureFill() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes32 digest = settlement.hashOrder(order);
        bytes memory signature = signOrder(order, MAKER_PK);

        vm.expectEmit(true, true, false, true);
        emit OrderCancelled(digest, maker, maker);
        vm.prank(maker);
        settlement.cancelOrder(order);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(order, signature);
    }

    function test_incrementNonceInvalidatesOlderOrders() public {
        Order memory staleOrder = makeBuyOrder(10e18, 10_500e6, 0, 1);
        Order memory freshOrder = makeBuyOrder(10e18, 10_500e6, 1, 2);
        bytes memory staleSignature = signOrder(staleOrder, MAKER_PK);
        bytes memory freshSignature = signOrder(freshOrder, MAKER_PK);

        vm.expectEmit(true, false, false, true);
        emit NonceIncremented(maker, 1);
        vm.prank(maker);
        settlement.incrementNonce();

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(staleOrder, staleSignature);

        vm.prank(investor);
        settlement.fillOrder(freshOrder, freshSignature);
        assertTrue(settlement.isOrderConsumed(settlement.hashOrder(freshOrder)));
    }
}
