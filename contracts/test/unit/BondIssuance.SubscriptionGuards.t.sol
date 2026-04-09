// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondIssuance} from "../../src/BondIssuance.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";
import {Role, SubscriptionTerms, SubscriptionStatus} from "../../src/types/BondTypes.sol";
import {
    MaxUnitsBelowSoldUnits,
    SubscriptionNotActive,
    UnsupportedSettlementToken,
    ZeroAmount
} from "../../src/libraries/BondErrors.sol";

contract BondIssuanceSubscriptionGuardsTest is Test {
    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal maker = makeAddr("maker");

    MockERC20Decimals internal usdc;
    BondIssuance internal issuance;
    ComplianceModule internal module;
    BondToken internal bondToken;

    function setUp() public {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance impl = new BondIssuance();
        issuance = BondIssuance(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(BondIssuance.initialize, (admin))))
        );

        ComplianceModule complianceImpl = new ComplianceModule();
        module = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(complianceImpl),
                    abi.encodeCall(ComplianceModule.initialize, (admin, factory, keccak256("p"), 1))
                )
            )
        );

        bondToken = new BondToken(
            issuer, "HKB", "HKB", 18, 1_000e6, 500,
            block.timestamp + 30 days, address(usdc), address(module), address(issuance)
        );

        vm.prank(factory);
        module.bindBondToken(address(bondToken));

        vm.startPrank(admin);
        module.setWhitelist(issuer, true);
        module.setWhitelist(maker, true);
        module.setRole(issuer, Role.ISSUER);
        module.setRole(maker, Role.MARKET_MAKER);
        issuance.setSettlementTokenPolicy(address(usdc), true, false, true);
        vm.stopPrank();

        usdc.mint(maker, 10_000_000e6);
        vm.prank(maker);
        usdc.approve(address(issuance), type(uint256).max);
    }

    // ─── subscribe 零值 ─────────────────────────────────────────

    function test_revertWhenSubscribeWithZeroUnits() public {
        bytes32 offerId = _createOffer(100e18);
        vm.prank(maker);
        vm.expectRevert(ZeroAmount.selector);
        issuance.subscribe(offerId, 0);
    }

    // ─── depositRedemption 零值 ─────────────────────────────────

    function test_revertWhenDepositRedemptionWithZeroAmount() public {
        usdc.mint(issuer, 100e6);
        vm.prank(issuer);
        usdc.approve(address(issuance), type(uint256).max);

        vm.prank(issuer);
        vm.expectRevert(ZeroAmount.selector);
        issuance.depositRedemption(address(bondToken), 0);
    }

    // ─── closeSubscription ACTIVE 校验 ──────────────────────────

    function test_revertWhenCloseAlreadyClosedSubscription() public {
        bytes32 offerId = _createOffer(100e18);

        vm.prank(issuer);
        issuance.closeSubscription(offerId);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionNotActive.selector, offerId));
        issuance.closeSubscription(offerId);
    }

    function test_revertWhenCloseAutoClosedSubscription() public {
        bytes32 offerId = _createOffer(10e18);

        vm.prank(maker);
        issuance.subscribe(offerId, 10e18);

        (, , , , uint256 soldUnits, , , uint8 status) = issuance.getSubscription(offerId);
        assertEq(soldUnits, 10e18);
        assertEq(status, uint8(SubscriptionStatus.CLOSED));

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionNotActive.selector, offerId));
        issuance.closeSubscription(offerId);
    }

    // ─── updateSubscription 全覆盖 ──────────────────────────────

    function test_updateSubscriptionSucceeds() public {
        bytes32 offerId = _createOffer(100e18);

        SubscriptionTerms memory newTerms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_100e6,
            maxUnits: 200e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 2 days
        });

        vm.prank(issuer);
        issuance.updateSubscription(offerId, newTerms);

        (, , uint256 unitPrice, uint256 maxUnits, , , uint256 closesAt,) = issuance.getSubscription(offerId);
        assertEq(unitPrice, 1_100e6);
        assertEq(maxUnits, 200e18);
        assertEq(closesAt, block.timestamp + 2 days);
    }

    function test_revertWhenUpdateWithMismatchedSettlementToken() public {
        bytes32 offerId = _createOffer(100e18);
        MockERC20Decimals otherToken = new MockERC20Decimals("Other", "OTH", 6);

        SubscriptionTerms memory newTerms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(otherToken),
            unitPrice: 1_000e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(UnsupportedSettlementToken.selector, address(otherToken)));
        issuance.updateSubscription(offerId, newTerms);
    }

    function test_revertWhenUpdateMaxUnitsBelowSoldUnits() public {
        bytes32 offerId = _createOffer(100e18);

        vm.prank(maker);
        issuance.subscribe(offerId, 50e18);

        SubscriptionTerms memory newTerms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 30e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(MaxUnitsBelowSoldUnits.selector, offerId, 30e18, 50e18));
        issuance.updateSubscription(offerId, newTerms);
    }

    function test_revertWhenUpdateClosedSubscription() public {
        bytes32 offerId = _createOffer(100e18);
        vm.prank(issuer);
        issuance.closeSubscription(offerId);

        SubscriptionTerms memory newTerms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_000e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionNotActive.selector, offerId));
        issuance.updateSubscription(offerId, newTerms);
    }

    // ─── helpers ─────────────────────────────────────────────────

    function _createOffer(uint256 maxUnits) internal returns (bytes32) {
        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: maxUnits,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });
        vm.prank(issuer);
        return issuance.createSubscription(terms);
    }
}
