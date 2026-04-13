// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondIssuance} from "../../src/BondIssuance.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";
import {BondCategory, CouponFrequency, DayCount, Role, SubscriptionTerms} from "../../src/types/BondTypes.sol";

contract BondIssuanceSubscriptionTest is Test {
    event SettlementTokenPolicyUpdated(
        address indexed token,
        bool issuanceEnabled,
        bool settlementEnabled,
        bool redemptionEnabled,
        address operator
    );

    event Subscribed(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed subscriber,
        address settlementToken,
        uint256 units,
        uint256 cost
    );

    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal maker = makeAddr("maker");
    address internal outsider = makeAddr("outsider");

    MockERC20Decimals internal usdc;
    BondIssuance internal issuance;
    ComplianceModule internal module;
    BondToken internal bondToken;

    function setUp() public {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance issuanceImplementation = new BondIssuance();
        issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(issuanceImplementation),
                    abi.encodeCall(BondIssuance.initialize, (admin))
                )
            )
        );

        ComplianceModule complianceImplementation = new ComplianceModule();
        module = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(complianceImplementation),
                    abi.encodeCall(
                        ComplianceModule.initialize,
                        (admin, factory, keccak256("policy"), 1)
                    )
                )
            )
        );

        bondToken = new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HashKey Bond",
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
        vm.stopPrank();
    }

    function test_adminCanEnableSettlementTokenForIssuance() public {
        vm.expectEmit(true, false, false, true);
        emit SettlementTokenPolicyUpdated(
            address(usdc),
            true,
            false,
            false,
            admin
        );
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, false, false);

        assertTrue(issuance.isSettlementTokenEnabled(address(usdc)));
    }

    function test_issuerCanCreateSubscriptionAndMakerCanSubscribe() public {
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, false, false);

        bytes32 approvalId = keccak256("sub-approval-1");
        vm.prank(admin);
        issuance.approveSubscription(
            approvalId,
            issuer,
            address(bondToken),
            500e18,
            0
        );

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_050e6,
            maxUnits: 500e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        bytes32 offerId = issuance.createSubscription(terms, approvalId);

        usdc.mint(maker, 200_000e6);
        vm.prank(maker);
        usdc.approve(address(issuance), type(uint256).max);

        uint256 expectedCost = 105_000e6;
        vm.expectEmit(true, true, true, true);
        emit Subscribed(
            offerId,
            address(bondToken),
            maker,
            address(usdc),
            100e18,
            expectedCost
        );
        vm.prank(maker);
        issuance.subscribe(offerId, 100e18);

        assertEq(usdc.balanceOf(issuer), expectedCost);
        assertEq(bondToken.balanceOf(maker), 100e18);
    }

    function test_revertWhenOutsiderSubscribesWithoutMakerRole() public {
        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, false, false);

        bytes32 approvalId = keccak256("sub-approval-2");
        vm.prank(admin);
        issuance.approveSubscription(
            approvalId,
            issuer,
            address(bondToken),
            100e18,
            0
        );

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: address(bondToken),
            settlementToken: address(usdc),
            unitPrice: 1_000e6,
            maxUnits: 100e18,
            opensAt: block.timestamp,
            closesAt: block.timestamp + 1 days
        });

        vm.prank(issuer);
        bytes32 offerId = issuance.createSubscription(terms, approvalId);

        usdc.mint(outsider, 100_000e6);
        vm.prank(outsider);
        usdc.approve(address(issuance), type(uint256).max);

        vm.prank(outsider);
        vm.expectRevert();
        issuance.subscribe(offerId, 10e18);
    }
}
