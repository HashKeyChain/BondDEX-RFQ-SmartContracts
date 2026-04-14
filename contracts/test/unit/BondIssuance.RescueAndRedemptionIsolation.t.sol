// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondCategory, CouponFrequency, DayCount, Role} from "../../src/types/BondTypes.sol";

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
            BondToken.ConstructorParams({
                issuer: issuerB,
                name: "Bond B",
                symbol: "HKBB",
                decimals: 18,
                faceValue: 500e6,
                couponRateBps: 300,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: address(usdc),
                complianceModule: address(moduleB),
                issuanceController: address(issuance),
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
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

        // bond A: ACT/365 accrual from issueDate+8d to maturity (22d), 100e18 * (1000e6 + aiPerUnit) = 100_301_369_800
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        // bond B: ACT/365 accrual over 30d, 50e18 * (500e6 + aiPerUnit) = 25_061_643_800
        vm.prank(issuerB);
        issuance.depositRedemption(address(bondTokenB), 25_061_643_800);

        uint256 totalBalance = usdc.balanceOf(address(issuance));
        assertEq(totalBalance, 100_301_369_800 + 25_061_643_800);

        warpToMaturity();

        // holder A claim 全部
        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), 100_301_369_800);
        assertEq(bondToken.balanceOf(holder), 0);

        // bond B 的资金不受影响
        (uint256 fundedB, uint256 claimedB,) = issuance.getRedemptionState(address(bondTokenB));
        assertEq(fundedB, 25_061_643_800);
        assertEq(claimedB, 0);

        // holder B claim 全部
        vm.prank(holderB);
        issuance.claim(address(bondTokenB));
        assertEq(usdc.balanceOf(holderB), 25_061_643_800);
        assertEq(bondTokenB.balanceOf(holderB), 0);

        assertEq(usdc.balanceOf(address(issuance)), 0);
    }

    // ─── 多存后自动释放超额负债（所有 bond 赎回后） ─────────────

    event ExcessRedemptionReleased(address indexed bondToken, address indexed settlementToken, uint256 excessAmount);

    function test_excessLiabilityAutoReleasedAfterAllClaims() public {
        uint256 exactPayout = 100_301_369_800;
        uint256 excess = 50_000e6;
        uint256 deposit = exactPayout + excess;

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), deposit);

        warpToMaturity();

        vm.expectEmit(true, true, false, true);
        emit ExcessRedemptionReleased(address(bondToken), address(usdc), excess);

        vm.prank(holder);
        issuance.claim(address(bondToken));

        assertEq(bondToken.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(issuance)), excess);

        vm.prank(admin);
        issuance.rescueTokens(address(usdc), admin, excess);
        assertEq(usdc.balanceOf(admin), excess);
        assertEq(usdc.balanceOf(address(issuance)), 0);
    }

    // ─── 主动释放超额负债（部分赎回场景） ───────────────────────

    function test_adminCanReleaseExcessRedemptionBeforeAllClaims() public {
        uint256 exactPayout = 100_301_369_800;
        uint256 excess = 80_000e6;
        uint256 deposit = exactPayout + excess;

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), deposit);

        warpToMaturity();

        vm.prank(admin);
        issuance.releaseExcessRedemption(address(bondToken));

        vm.prank(admin);
        issuance.rescueTokens(address(usdc), admin, excess);
        assertEq(usdc.balanceOf(admin), excess);

        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), exactPayout);
    }

    function test_revertReleaseExcessBeforeMaturity() public {
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(admin);
        vm.expectRevert();
        issuance.releaseExcessRedemption(address(bondToken));
    }

    function test_revertReleaseExcessByNonAdmin() public {
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        warpToMaturity();

        vm.prank(outsider);
        vm.expectRevert();
        issuance.releaseExcessRedemption(address(bondToken));
    }
}
