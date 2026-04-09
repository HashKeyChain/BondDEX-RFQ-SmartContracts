// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Role} from "../../src/types/BondTypes.sol";

contract BondIssuanceRescueAndRedemptionIsolationTest is BondIssuanceRedemptionFixtures {
    event TokensRescued(address indexed token, address indexed to, uint256 amount, address indexed operator);

    function setUp() public {
        deployRedemptionFixtures();
    }

    // ─── rescueTokens ───────────────────────────────────────────

    function test_adminCanRescueTokensAndEmitsEvent() public {
        usdc.mint(address(issuance), 500e6);

        vm.expectEmit(true, true, true, true);
        emit TokensRescued(address(usdc), admin, 500e6, admin);

        vm.prank(admin);
        issuance.rescueTokens(address(usdc), admin, 500e6);

        assertEq(usdc.balanceOf(admin), 500e6);
    }

    function test_revertWhenNonAdminCallsRescueTokens() public {
        usdc.mint(address(issuance), 500e6);

        vm.prank(outsider);
        vm.expectRevert();
        issuance.rescueTokens(address(usdc), outsider, 500e6);
    }

    // ─── 多 bond 共享 settlement token 赎回隔离 ─────────────────

    function test_multiBondRedemptionIsolation() public {
        address issuerB = makeAddr("issuerB");
        address holderB = makeAddr("holderB");

        ComplianceModule complianceImplB = new ComplianceModule();
        ComplianceModule moduleB = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(complianceImplB),
                    abi.encodeCall(ComplianceModule.initialize, (admin, factory, keccak256("policyB"), 1))
                )
            )
        );

        BondToken bondTokenB = new BondToken(
            issuerB, "Bond B", "HKBB", 18, 500e6, 300,
            block.timestamp + 30 days, address(usdc), address(moduleB), address(issuance)
        );

        vm.prank(factory);
        moduleB.bindBondToken(address(bondTokenB));

        vm.startPrank(admin);
        moduleB.setWhitelist(issuerB, true);
        moduleB.setWhitelist(holderB, true);
        moduleB.setRole(issuerB, Role.ISSUER);
        moduleB.setRole(holderB, Role.INVESTOR);
        vm.stopPrank();

        vm.prank(address(issuance));
        bondTokenB.mint(holderB, 50e18);

        usdc.mint(issuerB, 1_000_000e6);
        vm.prank(issuerB);
        usdc.approve(address(issuance), type(uint256).max);

        // bond A: 100e18 份，faceValue=1000e6，coupon=500bps → payout = 100e18 * 1000e6 / 1e18 * 1.05 = 105_000e6
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);

        // bond B: 50e18 份，faceValue=500e6，coupon=300bps → payout = 50e18 * 500e6 / 1e18 * 1.03 = 25_750e6
        vm.prank(issuerB);
        issuance.depositRedemption(address(bondTokenB), 25_750e6);

        uint256 totalBalance = usdc.balanceOf(address(issuance));
        assertEq(totalBalance, 105_000e6 + 25_750e6);

        warpToMaturity();

        // holder A claim 全部
        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), 105_000e6);
        assertEq(bondToken.balanceOf(holder), 0);

        // bond B 的资金不受影响
        (uint256 fundedB, uint256 claimedB,) = issuance.getRedemptionState(address(bondTokenB));
        assertEq(fundedB, 25_750e6);
        assertEq(claimedB, 0);

        // holder B claim 全部
        vm.prank(holderB);
        issuance.claim(address(bondTokenB));
        assertEq(usdc.balanceOf(holderB), 25_750e6);
        assertEq(bondTokenB.balanceOf(holderB), 0);

        assertEq(usdc.balanceOf(address(issuance)), 0);
    }
}
