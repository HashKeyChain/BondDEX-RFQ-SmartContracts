// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NotWhitelisted} from "../../src/libraries/BondErrors.sol";
import {PauseDomain} from "../../src/types/BondTypes.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract BondIssuanceClaimDelegateTest is BondIssuanceRedemptionFixtures {
    event ClaimDelegateSet(address indexed holder, address indexed delegate, address operator);
    event RedemptionClaimed(
        address indexed bondToken, address indexed holder, address indexed claimer, uint256 bondAmount, uint256 payout
    );

    function setUp() public {
        deployRedemptionFixtures();
    }

    function test_holderCanSetDelegateAndDelegateClaimsForHolder() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.expectEmit(true, true, false, true);
        emit ClaimDelegateSet(holder, delegate, holder);
        vm.prank(holder);
        issuance.setClaimDelegate(delegate);

        vm.expectEmit(true, true, true, true);
        emit RedemptionClaimed(address(bondToken), holder, delegate, 100e18, 100_301_369_800);
        vm.prank(delegate);
        issuance.claimFor(address(bondToken), holder);

        assertEq(usdc.balanceOf(holder), 100_301_369_800);
        assertEq(usdc.balanceOf(delegate), 0);
        assertEq(bondToken.balanceOf(holder), 0);
    }

    function test_revertWhenDelegateRevokedOrUnauthorized() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(holder);
        issuance.setClaimDelegate(delegate);
        vm.prank(holder);
        issuance.setClaimDelegate(address(0));

        vm.prank(delegate);
        vm.expectRevert();
        issuance.claimFor(address(bondToken), holder);
    }

    function test_revertWhenDelegateClaimsForNonWhitelistedHolder() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(holder);
        issuance.setClaimDelegate(delegate);

        vm.prank(admin);
        complianceModule.setWhitelist(holder, false);

        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, holder));
        issuance.claimFor(address(bondToken), holder);
    }

    function test_delegateClaimRespectsClaimsPause() public {
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(holder);
        issuance.setClaimDelegate(delegate);

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.CLAIMS, true);

        vm.prank(delegate);
        vm.expectRevert();
        issuance.claimFor(address(bondToken), holder);
    }
}
