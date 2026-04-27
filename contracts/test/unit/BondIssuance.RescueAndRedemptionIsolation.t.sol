// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BondIssuanceRedemptionFixtures } from "../helpers/BondIssuanceRedemptionFixtures.sol";
import { BondToken } from "../../src/BondToken.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BondCategory, CouponFrequency, DayCount, Role } from "../../src/types/BondTypes.sol";

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
                settlementTokenDecimals: 6,
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

        // AUDIT-FIX(N7): payouts now use accruedInterestFor (deferred division).
        //   bond A: principal 100_000_000_000 + interest 301_369_863 = 100_301_369_863
        //   bond B: principal  25_000_000_000 + interest  61_643_835 =  25_061_643_835
        uint256 payoutA = 100_301_369_863;
        uint256 payoutB = 25_061_643_835;
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), payoutA);

        vm.prank(issuerB);
        issuance.depositRedemption(address(bondTokenB), payoutB);

        uint256 totalBalance = usdc.balanceOf(address(issuance));
        assertEq(totalBalance, payoutA + payoutB);

        warpToMaturity();

        // holder A claim 全部
        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), payoutA);
        assertEq(bondToken.balanceOf(holder), 0);

        // bond B 的资金不受影响
        (uint256 fundedB, uint256 claimedB,) = issuance.getRedemptionState(address(bondTokenB));
        assertEq(fundedB, payoutB);
        assertEq(claimedB, 0);

        // holder B claim 全部
        vm.prank(holderB);
        issuance.claim(address(bondTokenB));
        assertEq(usdc.balanceOf(holderB), payoutB);
        assertEq(bondTokenB.balanceOf(holderB), 0);

        assertEq(usdc.balanceOf(address(issuance)), 0);
    }

    // ─── 多存后自动释放超额负债（所有 bond 赎回后） ─────────────

    event ExcessRedemptionReleased(address indexed bondToken, address indexed settlementToken, uint256 excessAmount);
    event ExcessRedemptionRefunded(
        address indexed bondToken, address indexed settlementToken, address indexed issuer, uint256 excessAmount
    );

    function test_excessLiabilityAutoReleasedAfterAllClaims() public {
        // AUDIT-FIX(N7): payout uses high-precision accruedInterestFor (was 100_301_369_800).
        uint256 exactPayout = 100_301_369_863;
        uint256 excess = 50_000e6;
        uint256 deposit = exactPayout + excess;
        uint256 issuerBalanceBefore = usdc.balanceOf(issuer);

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), deposit);

        warpToMaturity();

        // AUDIT-FIX(N6): excess is auto-refunded to the issuer (was: parked as rescuable balance).
        vm.expectEmit(true, true, true, true);
        emit ExcessRedemptionRefunded(address(bondToken), address(usdc), issuer, excess);

        vm.prank(holder);
        issuance.claim(address(bondToken));

        assertEq(bondToken.totalSupply(), 0);
        // The contract no longer retains the excess; it returned to the issuer atomically.
        assertEq(usdc.balanceOf(address(issuance)), 0);
        assertEq(usdc.balanceOf(issuer), issuerBalanceBefore - deposit + excess);
        assertEq(usdc.balanceOf(holder), exactPayout);
    }

    // ─── 主动释放超额负债（部分赎回场景） ───────────────────────

    function test_adminCanReleaseExcessRedemptionBeforeAllClaims() public {
        uint256 exactPayout = 100_301_369_863;
        uint256 excess = 80_000e6;
        uint256 deposit = exactPayout + excess;
        uint256 issuerBalanceBefore = usdc.balanceOf(issuer);

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), deposit);

        warpToMaturity();

        // AUDIT-FIX(N6): the manual release path now atomically transfers excess to the issuer.
        vm.prank(admin);
        issuance.releaseExcessRedemption(address(bondToken));

        assertEq(usdc.balanceOf(issuer), issuerBalanceBefore - deposit + excess);

        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), exactPayout);
    }

    function test_revertReleaseExcessBeforeMaturity() public {
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_863);

        vm.prank(admin);
        vm.expectRevert();
        issuance.releaseExcessRedemption(address(bondToken));
    }

    function test_revertReleaseExcessByNonAdmin() public {
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_863);

        warpToMaturity();

        vm.prank(outsider);
        vm.expectRevert();
        issuance.releaseExcessRedemption(address(bondToken));
    }
}
