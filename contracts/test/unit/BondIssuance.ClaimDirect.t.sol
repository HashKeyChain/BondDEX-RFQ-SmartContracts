// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PauseDomain} from "../../src/types/BondTypes.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract BondIssuanceClaimDirectTest is BondIssuanceRedemptionFixtures {
    event RedemptionClaimed(
        address indexed bondToken,
        address indexed holder,
        address indexed claimer,
        uint256 bondAmount,
        uint256 payout
    );

    function setUp() public {
        deployRedemptionFixtures();
    }

    function test_holderCanClaimAfterFundingAndMaturity() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);

        vm.expectEmit(true, true, true, true);
        emit RedemptionClaimed(address(bondToken), holder, holder, 100e18, 105_000e6);

        vm.prank(holder);
        issuance.claim(address(bondToken));

        assertEq(bondToken.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(holder), 105_000e6);
        (uint256 fundedAmount, uint256 claimedAmount,) = issuance.getRedemptionState(address(bondToken));
        assertEq(fundedAmount, 105_000e6);
        assertEq(claimedAmount, 105_000e6);
    }

    function test_revertWhenInsufficientFunding() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 50_000e6);

        vm.prank(holder);
        vm.expectRevert();
        issuance.claim(address(bondToken));
    }

    function test_claimIgnoresNonClaimPauseDomainsButRespectsClaimsPause() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.SETTLEMENT, true);

        vm.prank(holder);
        issuance.claim(address(bondToken));
        assertEq(usdc.balanceOf(holder), 105_000e6);

        vm.prank(address(issuance));
        bondToken.mint(holder, 100e18);
        usdc.mint(issuer, 105_000e6);
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.CLAIMS, true);

        vm.prank(holder);
        vm.expectRevert();
        issuance.claim(address(bondToken));
    }
}
