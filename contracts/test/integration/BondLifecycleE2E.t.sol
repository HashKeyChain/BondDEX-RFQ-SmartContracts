// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondFactory} from "../../src/BondFactory.sol";
import {BondIssuance} from "../../src/BondIssuance.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";
import {RFQSettlement} from "../../src/RFQSettlement.sol";
import {
    BondConfig,
    Role,
    SubscriptionTerms,
    Order,
    OrderSide,
    FeeConfig
} from "../../src/types/BondTypes.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";

contract BondLifecycleE2ETest is Test {
    uint256 internal constant MAKER_PK = 0xA11CE;

    address internal admin = makeAddr("admin");
    address internal factoryRole = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal maker = vm.addr(MAKER_PK);
    address internal investor = makeAddr("investor");
    address internal feeRecipient = makeAddr("feeRecipient");

    MockERC20Decimals internal usdc;
    BondFactory internal factory;
    BondIssuance internal issuance;
    RFQSettlement internal settlement;
    ComplianceModule internal complianceImplementation;

    function test_fullLifecycleFromIssuanceToRedemptionClaim() public {
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

        RFQSettlement settlementImplementation = new RFQSettlement();
        settlement = RFQSettlement(
            address(
                new ERC1967Proxy(
                    address(settlementImplementation),
                    abi.encodeCall(RFQSettlement.initialize, (admin))
                )
            )
        );

        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));

        bytes32 approvalId = keccak256("approval");
        vm.startPrank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            keccak256("metadata")
        );
        issuance.setSettlementTokenPolicy(address(usdc), true, false, true);
        settlement.setSettlementTokenPolicy(address(usdc), true);
        settlement.setFeeConfig(
            FeeConfig({
                feeRecipient: feeRecipient,
                currentFeeBps: 50,
                maxFeeBps: 1_000
            })
        );
        vm.stopPrank();

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
            policyVersion: 1
        });

        vm.prank(issuer);
        (address bondTokenAddress, address complianceModuleAddress) = factory
            .createBond(config, approvalId);
        BondToken bondToken = BondToken(bondTokenAddress);
        ComplianceModule complianceModule = ComplianceModule(
            complianceModuleAddress
        );

        vm.startPrank(admin);
        complianceModule.setWhitelist(issuer, true);
        complianceModule.setWhitelist(maker, true);
        complianceModule.setWhitelist(investor, true);
        complianceModule.setRole(issuer, Role.ISSUER);
        complianceModule.setRole(maker, Role.MARKET_MAKER);
        complianceModule.setRole(investor, Role.INVESTOR);
        settlement.setBondTokenRegistration(bondTokenAddress, true);
        vm.stopPrank();

        bytes32 subApprovalId = keccak256("e2e-sub-approval");
        vm.prank(admin);
        issuance.approveSubscription(
            subApprovalId,
            issuer,
            bondTokenAddress,
            100e18,
            0
        );

        vm.prank(issuer);
        bytes32 offerId = issuance.createSubscription(
            SubscriptionTerms({
                bondToken: bondTokenAddress,
                settlementToken: address(usdc),
                unitPrice: 1_000e6,
                maxUnits: 100e18,
                opensAt: block.timestamp,
                closesAt: block.timestamp + 1 days
            }),
            subApprovalId
        );

        usdc.mint(maker, 500_000e6);
        usdc.mint(investor, 500_000e6);
        vm.prank(maker);
        usdc.approve(address(issuance), type(uint256).max);
        vm.prank(investor);
        usdc.approve(address(settlement), type(uint256).max);
        vm.prank(maker);
        bondToken.approve(address(settlement), type(uint256).max);

        vm.prank(maker);
        issuance.subscribe(offerId, 100e18);

        Order memory order = Order({
            maker: maker,
            taker: investor,
            bondToken: bondTokenAddress,
            quoteToken: address(usdc),
            bondAmount: 10e18,
            quoteAmount: 10_500e6,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 1,
            maxFeeBps: 10_000
        });
        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, digest);

        vm.prank(investor);
        settlement.fillOrder(order, abi.encodePacked(r, s, v));

        vm.warp(block.timestamp + 31 days);

        usdc.mint(issuer, 10_500e6);
        vm.prank(issuer);
        usdc.approve(address(issuance), type(uint256).max);
        vm.prank(issuer);
        issuance.depositRedemption(bondTokenAddress, 10_500e6);

        vm.prank(investor);
        issuance.claim(bondTokenAddress);

        assertEq(usdc.balanceOf(investor), 500_000e6 - 10_500e6 + 10_500e6);
        assertEq(bondToken.balanceOf(investor), 0);
        assertEq(usdc.balanceOf(feeRecipient), 52_500_000);
    }
}
