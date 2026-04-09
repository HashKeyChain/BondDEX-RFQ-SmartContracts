// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeConfig, Order, OrderSide, Role} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";

/// @dev 覆盖三种手续费场景：做市商卖/投资者买、投资者卖/做市商买、做市商间免费。
contract RFQSettlementFeeModelTest is RFQSettlementFixtures {
    uint16 constant FEE_BPS = 30; // 0.30%

    function setUp() public {
        deployRfqFixtures();

        vm.prank(admin);
        settlement.setFeeConfig(
            FeeConfig({
                feeRecipient: feeRecipient,
                currentFeeBps: FEE_BPS,
                maxFeeBps: 1_000
            })
        );

        vm.prank(issuanceController);
        bondToken.mint(investor, 500e18);

        usdc.mint(otherMaker, 10_000_000e6);
    }

    // ──────────────────────── 场景一：做市商卖出债券，投资者买入 ────────────────────────

    function test_mmSellInvestorBuy_feeDeductedFromMmIncome() public {
        uint256 quoteAmount = 10_000e6;
        uint256 expectedFee = (quoteAmount * FEE_BPS) / 10_000; // 30e6
        uint256 expectedMmIncome = quoteAmount - expectedFee; // 9_970e6

        Order memory order = Order({
            maker: maker,
            taker: investor,
            bondToken: address(bondToken),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: quoteAmount,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 100
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 investorUsdcBefore = usdc.balanceOf(investor);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(investor);
        settlement.fillOrder(order, sig);

        assertEq(
            usdc.balanceOf(investor),
            investorUsdcBefore - quoteAmount,
            "investor pays quoteAmount"
        );
        assertEq(
            usdc.balanceOf(maker),
            makerUsdcBefore + expectedMmIncome,
            "mm receives quoteAmount - fee"
        );
        assertEq(
            usdc.balanceOf(feeRecipient),
            feeBefore + expectedFee,
            "platform receives fee"
        );
        assertEq(
            bondToken.balanceOf(investor),
            500e18 + 10e18,
            "investor receives bonds"
        );
    }

    // ──────────────────────── 场景二：投资者卖出债券，做市商买入 ────────────────────────

    function test_investorSellMmBuy_feeChargedToMm() public {
        uint256 quoteAmount = 10_000e6;
        uint256 expectedFee = (quoteAmount * FEE_BPS) / 10_000; // 30e6

        Order memory order = Order({
            maker: maker,
            taker: investor,
            bondToken: address(bondToken),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: quoteAmount,
            side: OrderSide.SELL,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 200
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 investorUsdcBefore = usdc.balanceOf(investor);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(investor);
        settlement.fillOrder(order, sig);

        assertEq(
            usdc.balanceOf(maker),
            makerUsdcBefore - quoteAmount - expectedFee,
            "mm pays quoteAmount + fee"
        );
        assertEq(
            usdc.balanceOf(investor),
            investorUsdcBefore + quoteAmount,
            "investor receives full quoteAmount"
        );
        assertEq(
            usdc.balanceOf(feeRecipient),
            feeBefore + expectedFee,
            "platform receives fee"
        );
    }

    // ──────────────────────── 场景三：做市商之间交易免手续费 ────────────────────────

    function test_mmToMm_noFeeCharged() public {
        uint256 quoteAmount = 10_000e6;

        Order memory order = Order({
            maker: maker,
            taker: otherMaker,
            bondToken: address(bondToken),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: quoteAmount,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 300
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        uint256 otherMakerUsdcBefore = usdc.balanceOf(otherMaker);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(otherMaker);
        settlement.fillOrder(order, sig);

        assertEq(
            usdc.balanceOf(otherMaker),
            otherMakerUsdcBefore - quoteAmount,
            "otherMaker pays full quoteAmount"
        );
        assertEq(
            usdc.balanceOf(maker),
            makerUsdcBefore + quoteAmount,
            "maker receives full quoteAmount (no fee)"
        );
        assertEq(
            usdc.balanceOf(feeRecipient),
            feeBefore,
            "platform receives zero fee"
        );
    }

    function test_mmToMm_sellSide_noFeeCharged() public {
        uint256 quoteAmount = 10_000e6;

        Order memory order = Order({
            maker: maker,
            taker: otherMaker,
            bondToken: address(bondToken),
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: quoteAmount,
            side: OrderSide.SELL,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 301
        });
        bytes memory sig = signOrder(order, MAKER_PK);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(otherMaker);
        settlement.fillOrder(order, sig);

        assertEq(
            usdc.balanceOf(feeRecipient),
            feeBefore,
            "platform receives zero fee for MM-MM"
        );
    }

    // ──────────────────────── quoteFee view 函数 ────────────────────────

    function test_quoteFee_returnsCorrectFeeForMmInvestor() public view {
        uint256 fee = settlement.quoteFee(
            address(bondToken),
            maker,
            investor,
            10_000e6
        );
        uint256 expected = (10_000e6 * FEE_BPS) / 10_000;
        assertEq(fee, expected, "quoteFee should return fee for MM-investor");
    }

    function test_quoteFee_returnsZeroForMmToMm() public view {
        uint256 fee = settlement.quoteFee(
            address(bondToken),
            maker,
            otherMaker,
            10_000e6
        );
        assertEq(fee, 0, "quoteFee should return 0 for MM-MM");
    }

    function test_quoteFee_returnsCorrectFeeForInvestorMm() public view {
        uint256 fee = settlement.quoteFee(
            address(bondToken),
            investor,
            maker,
            10_000e6
        );
        uint256 expected = (10_000e6 * FEE_BPS) / 10_000;
        assertEq(fee, expected, "quoteFee should return fee for investor-MM");
    }
}
