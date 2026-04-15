// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { BondIssuance } from "../../src/BondIssuance.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";
import { BondCategory, CouponFrequency, DayCount, Role, SubscriptionTerms } from "../../src/types/BondTypes.sol";

contract US1SubscriptionHandler is Test {
    BondIssuance internal immutable issuance;
    BondToken internal immutable bondToken;
    MockERC20Decimals internal immutable usdc;
    bytes32 internal immutable offerId;
    address internal immutable maker;

    constructor(
        BondIssuance issuance_,
        BondToken bondToken_,
        MockERC20Decimals usdc_,
        bytes32 offerId_,
        address maker_
    ) {
        issuance = issuance_;
        bondToken = bondToken_;
        usdc = usdc_;
        offerId = offerId_;
        maker = maker_;
    }

    function subscribe(uint256 units) external {
        units = bound(units, 1, 50e18);

        usdc.mint(maker, 1_000_000e6);
        vm.startPrank(maker);
        usdc.approve(address(issuance), type(uint256).max);
        try issuance.subscribe(offerId, units) { } catch { }
        vm.stopPrank();
    }
}

contract US1PrimaryMarketAccountingInvariantTest is StdInvariant, Test {
    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal maker = makeAddr("maker");

    MockERC20Decimals internal usdc;
    BondIssuance internal issuance;
    ComplianceModule internal module;
    BondToken internal bondToken;
    bytes32 internal offerId;
    US1SubscriptionHandler internal handler;

    function setUp() public {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance issuanceImplementation = new BondIssuance();
        issuance = BondIssuance(
            address(new ERC1967Proxy(address(issuanceImplementation), abi.encodeCall(BondIssuance.initialize, (admin))))
        );

        ComplianceModule complianceImplementation = new ComplianceModule();
        module = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(complianceImplementation),
                    abi.encodeCall(ComplianceModule.initialize, (admin, factory, keccak256("policy"), 1))
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
        issuance.setSettlementTokenPolicy(address(usdc), true, false, false);
        vm.stopPrank();

        bytes32 subApprovalId = keccak256("inv-sub-approval");
        vm.prank(admin);
        issuance.approveSubscription(subApprovalId, issuer, address(bondToken), 500e18, 0);

        vm.prank(issuer);
        offerId = issuance.createSubscription(
            SubscriptionTerms({
                bondToken: address(bondToken),
                settlementToken: address(usdc),
                unitPrice: 1_000e6,
                maxUnits: 500e18,
                opensAt: block.timestamp,
                closesAt: block.timestamp + 1 days
            }),
            subApprovalId
        );

        handler = new US1SubscriptionHandler(issuance, bondToken, usdc, offerId, maker);
        targetContract(address(handler));
    }

    function invariant_totalSupplyMatchesSoldUnits() public view {
        (,,,, uint256 soldUnits,,,) = issuance.getSubscription(offerId);
        assertEq(bondToken.totalSupply(), soldUnits);
    }
}
