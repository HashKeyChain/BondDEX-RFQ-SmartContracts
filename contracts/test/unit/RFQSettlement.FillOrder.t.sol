// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeConfig, Order, PauseDomain} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementFillOrderTest is RFQSettlementFixtures {
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        address bondToken,
        address quoteToken,
        uint8 side,
        uint256 bondAmount,
        uint256 quoteAmount,
        uint256 feeAmount,
        address feeRecipient
    );

    function setUp() public {
        deployRfqFixtures();
    }

    function test_fillOrderTransfersAssetsAndMarksOrderConsumed() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes32 digest = settlement.hashOrder(order);
        bytes memory signature = signOrder(order, MAKER_PK);

        vm.expectEmit(true, true, true, true);
        emit OrderFilled(
            digest, maker, investor, address(bondToken), address(usdc), 0, 10e18, 10_500e6, 0, feeRecipient
        );

        vm.prank(investor);
        settlement.fillOrder(order, signature);

        assertTrue(settlement.isOrderConsumed(digest));
        assertEq(bondToken.balanceOf(investor), 10e18);
        assertEq(usdc.balanceOf(maker), 10_010_500e6);
    }

    function test_revertWhenSignatureDoesNotMatchMaker() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes memory signature = signOrder(order, INVESTOR_PK);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(order, signature);
    }

    function test_revertWhenOrderExpired() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        order.expiry = block.timestamp - 1;
        bytes memory signature = signOrder(order, MAKER_PK);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(order, signature);
    }

    function test_revertWhenSettlementDomainPaused() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes memory signature = signOrder(order, MAKER_PK);
        vm.prank(admin);
        settlement.pauseDomain(PauseDomain.SETTLEMENT, true);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(order, signature);
    }

    function test_revertWhenSettlementTokenDisabled() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes memory signature = signOrder(order, MAKER_PK);
        vm.prank(admin);
        settlement.setSettlementTokenPolicy(address(usdc), false);

        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(order, signature);
    }

    function test_fillOrderRoutesFeeOnQuoteSide() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes memory signature = signOrder(order, MAKER_PK);
        vm.prank(admin);
        settlement.setFeeConfig(FeeConfig({feeRecipient: feeRecipient, currentFeeBps: 100, maxFeeBps: 1_000}));

        vm.prank(investor);
        settlement.fillOrder(order, signature);

        assertEq(usdc.balanceOf(feeRecipient), 105e6);
        assertEq(usdc.balanceOf(maker), 10_010_395e6);
    }
}
