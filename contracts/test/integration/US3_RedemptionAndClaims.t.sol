// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BondIssuanceRedemptionFixtures } from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract US3RedemptionAndClaimsIntegrationTest is BondIssuanceRedemptionFixtures {
    function setUp() public {
        deployRedemptionFixtures();
    }

    function test_directAndDelegatedClaimLifecycle() public {
        warpToMaturity();

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 100_301_369_800);

        vm.prank(holder);
        issuance.setClaimDelegate(delegate);

        vm.prank(delegate);
        issuance.claimFor(address(bondToken), holder);

        assertEq(usdc.balanceOf(holder), 100_301_369_800);
        assertEq(usdc.balanceOf(delegate), 0);
        assertEq(bondToken.balanceOf(holder), 0);
    }
}
