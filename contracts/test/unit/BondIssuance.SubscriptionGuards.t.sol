// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { BondIssuance } from "../../src/BondIssuance.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";
import {
    BondCategory,
    CouponFrequency,
    DayCount,
    Role,
    SubscriptionTerms,
    SubscriptionStatus,
    ApprovalStatus
} from "../../src/types/BondTypes.sol";
import {
    MaxUnitsExceedsApproval,
    SubscriptionApprovalNotActive,
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

    uint256 internal _nextApprovalId = 1;

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
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HKB",
                symbol: "HKB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: address(usdc),
                complianceModule: address(module),
                issuanceController: address(issuance),
                issueDate: block.timestamp + 8 days,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
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

        (,,,, uint256 soldUnits,,, uint8 status) = issuance.getSubscription(offerId);
        assertEq(soldUnits, 10e18);
        assertEq(status, uint8(SubscriptionStatus.CLOSED));

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionNotActive.selector, offerId));
        issuance.closeSubscription(offerId);
    }

    // ─── approveSubscription 校验 ───────────────────────────────

    function test_approveSubscriptionSucceeds() public {
        bytes32 approvalId = keccak256("test-approval");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, block.timestamp + 1 days);

        (address approvedIssuer, address approvedBond, uint256 maxUnits, uint256 expiresAt, ApprovalStatus status) =
            issuance.getSubscriptionApproval(approvalId);

        assertEq(approvedIssuer, issuer);
        assertEq(approvedBond, address(bondToken));
        assertEq(maxUnits, 100e18);
        assertEq(expiresAt, block.timestamp + 1 days);
        assertEq(uint8(status), uint8(ApprovalStatus.ACTIVE));
    }

    function test_revertWhenNonApproverCallsApprove() public {
        bytes32 approvalId = keccak256("test-approval");
        vm.prank(issuer);
        vm.expectRevert();
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, 0);
    }

    function test_revokeSubscriptionApprovalSucceeds() public {
        bytes32 approvalId = keccak256("test-revoke");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, 0);

        vm.prank(admin);
        issuance.revokeSubscriptionApproval(approvalId);

        (,,,, ApprovalStatus status) = issuance.getSubscriptionApproval(approvalId);
        assertEq(uint8(status), uint8(ApprovalStatus.REVOKED));
    }

    // ─── createSubscription 需要审批 ────────────────────────────

    function test_revertWhenCreateWithoutApproval() public {
        bytes32 fakeApproval = keccak256("nonexistent");
        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert();
        issuance.createSubscription(terms, fakeApproval);
    }

    function test_revertWhenCreateExceedsApprovedMaxUnits() public {
        bytes32 approvalId = keccak256("small-approval");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 50e18, 0);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(MaxUnitsExceedsApproval.selector, approvalId, 100e18, 50e18));
        issuance.createSubscription(terms, approvalId);
    }

    function test_revertWhenCreateWithRevokedApproval() public {
        bytes32 approvalId = keccak256("revoked-approval");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, 0);
        vm.prank(admin);
        issuance.revokeSubscriptionApproval(approvalId);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionApprovalNotActive.selector, approvalId, ApprovalStatus.REVOKED)
        );
        issuance.createSubscription(terms, approvalId);
    }

    function test_revertWhenCreateWithExpiredApproval() public {
        bytes32 approvalId = keccak256("expired-approval");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        vm.expectRevert();
        issuance.createSubscription(terms, approvalId);
    }

    function test_revertWhenCreateWithConsumedApproval() public {
        bytes32 approvalId = keccak256("consumed-approval");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, 0);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        issuance.createSubscription(terms, approvalId);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(SubscriptionApprovalNotActive.selector, approvalId, ApprovalStatus.CONSUMED)
        );
        issuance.createSubscription(terms, approvalId);
    }

    // ─── markSubscriptionExpired ───────────────────────────────

    function test_markSubscriptionExpiredSucceeds() public {
        bytes32 approvalId = keccak256("expirable-sub");

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);

        issuance.markSubscriptionExpired(approvalId);

        (,,,, ApprovalStatus status) = issuance.getSubscriptionApproval(approvalId);
        assertEq(uint8(status), uint8(ApprovalStatus.EXPIRED));
    }

    function test_revertWhenMarkSubExpiredOnNonexistent() public {
        vm.expectRevert();
        issuance.markSubscriptionExpired(keccak256("nonexistent"));
    }

    function test_revertWhenMarkSubExpiredNotYetExpired() public {
        bytes32 approvalId = keccak256("not-yet-sub");
        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, block.timestamp + 1 days);

        vm.expectRevert();
        issuance.markSubscriptionExpired(approvalId);
    }

    function test_revertWhenMarkSubExpiredOnNoExpiry() public {
        bytes32 approvalId = keccak256("no-expiry-sub");
        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, 0);

        vm.expectRevert();
        issuance.markSubscriptionExpired(approvalId);
    }

    function test_revertWhenMarkSubExpiredOnRevoked() public {
        bytes32 approvalId = keccak256("revoked-sub-mark");
        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), 100e18, block.timestamp + 1 hours);
        vm.prank(admin);
        issuance.revokeSubscriptionApproval(approvalId);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert();
        issuance.markSubscriptionExpired(approvalId);
    }

    // ─── helpers ─────────────────────────────────────────────────

    function _createOffer(uint256 maxUnits) internal returns (bytes32) {
        bytes32 approvalId = bytes32(++_nextApprovalId);

        vm.prank(admin);
        issuance.approveSubscription(approvalId, issuer, address(bondToken), maxUnits, 0);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: maxUnits,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });
        vm.prank(issuer);
        return issuance.createSubscription(terms, approvalId);
    }
}
