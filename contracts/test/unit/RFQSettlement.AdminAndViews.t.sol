// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order, FeeConfig, PauseDomain} from "../../src/types/BondTypes.sol";
import {RFQSettlementFixtures} from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementAdminAndViewsTest is RFQSettlementFixtures {
    event OrderCancelled(
        bytes32 indexed orderHash,
        address indexed maker,
        address canceller
    );
    event AiToleranceUpdated(uint256 newToleranceSeconds, address operator);
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount,
        address indexed operator
    );

    function setUp() public {
        deployRfqFixtures();
    }

    // ── batchCancelOrders ──────────────────────────────────────────

    function test_batchCancelOrdersBlocksFutureFills() public {
        Order[] memory orders = new Order[](2);
        orders[0] = makeBuyOrder(5e18, 5_000e6, 0, 100);
        orders[1] = makeBuyOrder(3e18, 3_000e6, 0, 101);

        bytes32 hash0 = settlement.hashOrder(orders[0]);
        bytes32 hash1 = settlement.hashOrder(orders[1]);

        vm.prank(maker);
        settlement.batchCancelOrders(orders);

        assertTrue(settlement.isOrderCancelled(hash0));
        assertTrue(settlement.isOrderCancelled(hash1));

        bytes memory sig0 = signOrder(orders[0], MAKER_PK);
        vm.prank(investor);
        vm.expectRevert();
        settlement.fillOrder(orders[0], sig0);
    }

    function test_revertWhenBatchCancelOrdersExceedsCap() public {
        Order[] memory orders = new Order[](25);
        for (uint256 i = 0; i < 25; i++) {
            orders[i] = makeBuyOrder(1e18, 1_000e6, 0, i + 200);
        }
        vm.prank(maker);
        vm.expectRevert();
        settlement.batchCancelOrders(orders);
    }

    function test_revertWhenBatchCancelOrdersEmpty() public {
        Order[] memory orders = new Order[](0);
        vm.prank(maker);
        vm.expectRevert();
        settlement.batchCancelOrders(orders);
    }

    // ── setAiToleranceSeconds ──────────────────────────────────────

    function test_setAiToleranceSecondsUpdatesTolerance() public {
        vm.prank(admin);
        settlement.setAiToleranceSeconds(600);
        assertEq(settlement.aiToleranceSeconds(), 600);
    }

    function test_revertWhenAiToleranceBelowMinimum() public {
        vm.prank(admin);
        vm.expectRevert();
        settlement.setAiToleranceSeconds(5);
    }

    function test_revertWhenAiToleranceAboveMaximum() public {
        vm.prank(admin);
        vm.expectRevert();
        settlement.setAiToleranceSeconds(31 days);
    }

    function test_revertWhenNonAdminSetsAiTolerance() public {
        vm.prank(maker);
        vm.expectRevert();
        settlement.setAiToleranceSeconds(600);
    }

    // ── eip712Domain ───────────────────────────────────────────────

    function test_eip712DomainReturnsExpectedFields() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,

        ) = settlement.eip712Domain();

        assertEq(fields, hex"0f");
        assertEq(keccak256(bytes(name)), keccak256("BondDEX RFQSettlement"));
        assertEq(keccak256(bytes(version)), keccak256("1"));
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(settlement));
    }

    // ── rescueTokens ──────────────────────────────────────────────

    function test_adminCanRescueTokensFromSettlement() public {
        usdc.mint(address(settlement), 1_000e6);

        vm.prank(admin);
        settlement.rescueTokens(address(usdc), admin, 1_000e6);
        assertEq(usdc.balanceOf(admin), 1_000e6);
    }

    function test_revertWhenNonAdminRescuesTokens() public {
        usdc.mint(address(settlement), 1_000e6);

        vm.prank(maker);
        vm.expectRevert();
        settlement.rescueTokens(address(usdc), maker, 1_000e6);
    }

    function test_revertWhenRescueZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert();
        settlement.rescueTokens(address(usdc), admin, 0);
    }

    // ── maxBatchSize ──────────────────────────────────────────────

    function test_maxBatchSizeReturns24() public view {
        assertEq(settlement.maxBatchSize(), 24);
    }
}
