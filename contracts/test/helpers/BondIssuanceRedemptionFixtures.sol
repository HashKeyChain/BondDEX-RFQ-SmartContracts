// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { BondIssuance } from "../../src/BondIssuance.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";
import { Role, BondCategory, CouponFrequency, DayCount } from "../../src/types/BondTypes.sol";

abstract contract BondIssuanceRedemptionFixtures is Test {
    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal holder = makeAddr("holder");
    address internal delegate = makeAddr("delegate");
    address internal outsider = makeAddr("outsider");

    MockERC20Decimals internal usdc;
    BondIssuance internal issuance;
    ComplianceModule internal complianceModule;
    BondToken internal bondToken;

    function deployRedemptionFixtures() internal {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        BondIssuance issuanceImplementation = new BondIssuance();
        issuance = BondIssuance(
            address(new ERC1967Proxy(address(issuanceImplementation), abi.encodeCall(BondIssuance.initialize, (admin))))
        );

        ComplianceModule complianceImplementation = new ComplianceModule();
        complianceModule = ComplianceModule(
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
                settlementTokenDecimals: 6,
                complianceModule: address(complianceModule),
                issuanceController: address(issuance),
                issueDate: block.timestamp + 8 days,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );

        vm.prank(factory);
        complianceModule.bindBondToken(address(bondToken));

        // AUDIT-FIX(N11) revisited: contracts now grant only DEFAULT_ADMIN_ROLE to admin at init
        // (BondIssuance + ComplianceModule). Self-grant the secondary roles this fixture exercises
        // so existing test bodies (which still vm.prank(admin) for setSettlementTokenPolicy /
        // approveSubscription / pauseDomain / setWhitelist / setRole / etc.) keep working.
        vm.startPrank(admin);
        issuance.grantRole(keccak256("SETTLEMENT_ADMIN_ROLE"), admin);
        issuance.grantRole(keccak256("ISSUANCE_APPROVER_ROLE"), admin);
        issuance.grantRole(keccak256("PAUSER_ROLE"), admin);
        complianceModule.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        complianceModule.grantRole(keccak256("PAUSER_ROLE"), admin);
        complianceModule.setWhitelist(issuer, true);
        complianceModule.setWhitelist(holder, true);
        complianceModule.setWhitelist(delegate, true);
        complianceModule.setRole(issuer, Role.ISSUER);
        complianceModule.setRole(holder, Role.INVESTOR);
        complianceModule.setRole(delegate, Role.INVESTOR);
        issuance.setSettlementTokenPolicy(address(usdc), false, true);
        vm.stopPrank();

        vm.prank(address(issuance));
        bondToken.mint(holder, 100e18);

        usdc.mint(issuer, 1_000_000e6);
        vm.prank(issuer);
        usdc.approve(address(issuance), type(uint256).max);
    }

    function warpToMaturity() internal {
        vm.warp(bondToken.maturityTimestamp() + 1);
    }
}
