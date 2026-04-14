// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NotWhitelisted} from "../../src/libraries/BondErrors.sol";
import {PauseDomain} from "../../src/types/BondTypes.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract BondIssuanceClaimDirectTest is BondIssuanceRedemptionFixtures {
    event RedemptionClaimed(
        address indexed bondToken, address indexed holder, address indexed claimer, uint256 bondAmount, uint256 payout
    );

    function setUp() public {
        deployRedemptionFixtures();
    }

    function test_holderCanClaimAfterFundingAndMaturity() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.expectEmit(true, true, true, true);
        emit RedemptionClaimed(address(bondToken), holder, holder, 100e18, 100_301_369_800);

        vm.prank(holder);
        issuance.claim(address(bondToken));

        assertEq(bondToken.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(holder), 100_301_369_800);
        (uint256 fundedAmount, uint256 claimedAmount,) = issuance.getRedemptionState(address(bondToken));
        assertEq(fundedAmount, 100_301_369_800);
        assertEq(claimedAmount, 100_301_369_800);
    }

    function test_revertWhenInsufficientFunding() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 50_000e6);

        vm.prank(holder);
        vm.expectRevert();
        issuance.claim(address(bondToken));
    }

    function test_revertWhenHolderNotWhitelisted() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(admin);
        complianceModule.setWhitelist(holder, false);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, holder));
        issuance.claim(address(bondToken));
    }

    function test_getSettlementTokenPolicyReturnsCorrectFlags() public {
        (bool iss, bool stl, bool red) = issuance.getSettlementTokenPolicy(address(usdc));
        assertFalse(iss);
        assertFalse(stl);
        assertTrue(red);

        vm.prank(admin);
        issuance.setSettlementTokenPolicy(address(usdc), true, true, false);
        (iss, stl, red) = issuance.getSettlementTokenPolicy(address(usdc));
        assertTrue(iss);
        assertTrue(stl);
        assertFalse(red);

        address unknownToken = makeAddr("unknown");
        (iss, stl, red) = issuance.getSettlementTokenPolicy(unknownToken);
        assertFalse(iss);
        assertFalse(stl);
        assertFalse(red);
    }

    function test_holderCanClaimAfterReAddedToWhitelist() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(admin);
        complianceModule.setWhitelist(holder, false);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, holder));
        issuance.claim(address(bondToken));

        vm.prank(admin);
        complianceModule.setWhitelist(holder, true);

        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(bondToken.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(holder), 100_301_369_800);
    }

    function test_claimIgnoresNonClaimPauseDomainsButRespectsClaimsPause() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.SETTLEMENT, true);

        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), 100_301_369_800);

        vm.prank(address(issuance));
        bondToken.mint(holder, 100e18);
        usdc.mint(issuer, 100_301_369_800);
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.CLAIMS, true);

        vm.prank(holder);
        vm.expectRevert();
        issuance.claim(address(bondToken));
    }
}
