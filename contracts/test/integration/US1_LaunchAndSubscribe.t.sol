// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { BondFactory } from "../../src/BondFactory.sol";
import { BondIssuance } from "../../src/BondIssuance.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";
import {
    BondCategory,
    BondConfig,
    CouponFrequency,
    DayCount,
    SubscriptionTerms,
    Role
} from "../../src/types/BondTypes.sol";
import { IComplianceModule } from "../../src/interfaces/IComplianceModule.sol";

contract US1LaunchAndSubscribeIntegrationTest is Test {
    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal maker = makeAddr("maker");
    bytes32 internal approvalId = keccak256("approval");

    MockERC20Decimals internal usdc;
    BondFactory internal factory;
    BondIssuance internal issuance;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance issuanceImplementation = new BondIssuance();
        issuance = BondIssuance(
            address(new ERC1967Proxy(address(issuanceImplementation), abi.encodeCall(BondIssuance.initialize, (admin))))
        );

        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));

        // AUDIT-FIX(N11) revisited: self-grant secondary roles this integration test exercises.
        vm.startPrank(admin);
        factory.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        factory.grantRole(keccak256("ISSUANCE_APPROVER_ROLE"), admin);
        issuance.grantRole(keccak256("SETTLEMENT_ADMIN_ROLE"), admin);
        issuance.grantRole(keccak256("ISSUANCE_APPROVER_ROLE"), admin);
        vm.stopPrank();
    }

    function test_launchAndSubscribeEndToEnd() public {
        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Bond",
            symbol: "HKB",
            decimals: 18,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: block.timestamp + 30 days,
            settlementToken: address(usdc),
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1,
            issueDate: block.timestamp + 8 days,
            dayCountConvention: DayCount.ACT_365,
            couponFrequency: CouponFrequency.BULLET,
            bondCategory: BondCategory.CORPORATE,
            isin: bytes12(0)
        });

        vm.startPrank(admin);
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);
        // AUDIT-FIX(N3): bind metadataHash to canonical config hash.
        factory.approveIssuance(
            approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, factory.hashBondConfig(config)
        );
        issuance.setSettlementTokenPolicy(address(usdc), true, false);
        vm.stopPrank();

        vm.prank(issuer);
        (address bondTokenAddress, address complianceModuleAddress) = factory.createBond(config, approvalId);

        BondToken bondToken = BondToken(bondTokenAddress);
        ComplianceModule complianceModule = ComplianceModule(complianceModuleAddress);

        // AUDIT-FIX(N11) revisited: ComplianceModule.initialize now grants only DEFAULT_ADMIN_ROLE
        // to admin. Self-grant COMPLIANCE_ADMIN_ROLE before exercising whitelist/role setters.
        vm.startPrank(admin);
        complianceModule.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        complianceModule.setWhitelist(issuer, true);
        complianceModule.setWhitelist(maker, true);
        complianceModule.setRole(issuer, Role.ISSUER);
        complianceModule.setRole(maker, Role.MARKET_MAKER);
        vm.stopPrank();

        bytes32 subApprovalId = keccak256("us1-sub-approval");
        vm.prank(admin);
        issuance.approveSubscription(subApprovalId, issuer, bondTokenAddress, 500e18, 0);

        vm.prank(issuer);
        bytes32 offerId = issuance.createSubscription(
            SubscriptionTerms({
                bondToken: bondTokenAddress,
                settlementToken: address(usdc),
                unitPrice: 1_050e6,
                maxUnits: 500e18,
                opensAt: block.timestamp,
                closesAt: block.timestamp + 1 days
            }),
            subApprovalId
        );

        usdc.mint(maker, 500_000e6);
        vm.prank(maker);
        usdc.approve(address(issuance), type(uint256).max);

        vm.prank(maker);
        issuance.subscribe(offerId, 100e18);

        assertEq(bondToken.balanceOf(maker), 100e18);
        assertEq(usdc.balanceOf(issuer), 105_000e6);
        assertEq(bondToken.complianceModule(), complianceModuleAddress);
    }

    function test_revertWhenSubscriptionUsesUnsupportedSettlementToken() public {
        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Bond",
            symbol: "HKB",
            decimals: 18,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: block.timestamp + 30 days,
            settlementToken: address(usdc),
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1,
            issueDate: block.timestamp + 8 days,
            dayCountConvention: DayCount.ACT_365,
            couponFrequency: CouponFrequency.BULLET,
            bondCategory: BondCategory.CORPORATE,
            isin: bytes12(0)
        });

        vm.startPrank(admin);
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);
        factory.approveIssuance(
            approvalId, issuer, address(complianceImplementation), block.timestamp + 1 days, factory.hashBondConfig(config)
        );
        vm.stopPrank();

        vm.prank(issuer);
        (address bondTokenAddress, address complianceModuleAddress) = factory.createBond(config, approvalId);

        ComplianceModule complianceModule = ComplianceModule(complianceModuleAddress);
        // AUDIT-FIX(N11) revisited: self-grant COMPLIANCE_ADMIN_ROLE under the new minimal init.
        vm.startPrank(admin);
        complianceModule.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        complianceModule.setWhitelist(issuer, true);
        complianceModule.setRole(issuer, Role.ISSUER);
        vm.stopPrank();

        MockERC20Decimals other = new MockERC20Decimals("Other USD", "oUSD", 6);

        bytes32 subApprovalId2 = keccak256("us1-sub-approval-2");
        vm.prank(admin);
        issuance.approveSubscription(subApprovalId2, issuer, bondTokenAddress, 500e18, 0);

        vm.prank(issuer);
        vm.expectRevert();
        issuance.createSubscription(
            SubscriptionTerms({
                bondToken: bondTokenAddress,
                settlementToken: address(other),
                unitPrice: 1_000e6,
                maxUnits: 500e18,
                opensAt: block.timestamp,
                closesAt: block.timestamp + 1 days
            }),
            subApprovalId2
        );
    }
}
