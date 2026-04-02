// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PauseDomain} from "../../src/types/BondTypes.sol";
import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract BondIssuanceRedemptionFundingTest is BondIssuanceRedemptionFixtures {
    event RedemptionDeposited(
        address indexed bondToken,
        address indexed issuer,
        address indexed settlementToken,
        uint256 amount,
        uint256 cumulativeFundedAmount
    );

    function setUp() public {
        deployRedemptionFixtures();
    }

    function test_issuerCanDepositRedemptionFunds() public {
        warpToMaturity();

        vm.expectEmit(true, true, true, true);
        emit RedemptionDeposited(address(bondToken), issuer, address(usdc), 105_000e6, 105_000e6);

        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);

        (uint256 fundedAmount, uint256 claimedAmount,) = issuance.getRedemptionState(address(bondToken));
        assertEq(fundedAmount, 105_000e6);
        assertEq(claimedAmount, 0);
        assertEq(usdc.balanceOf(address(issuance)), 105_000e6);
    }

    function test_revertWhenRedemptionFundingDomainPaused() public {
        warpToMaturity();

        vm.prank(admin);
        issuance.pauseDomain(PauseDomain.REDEMPTION_FUNDING, true);

        vm.prank(issuer);
        vm.expectRevert();
        issuance.depositRedemption(address(bondToken), 105_000e6);
    }

    function test_revertWhenNonIssuerDepositsRedemption() public {
        warpToMaturity();
        usdc.mint(outsider, 200_000e6);
        vm.prank(outsider);
        usdc.approve(address(issuance), type(uint256).max);

        vm.prank(outsider);
        vm.expectRevert();
        issuance.depositRedemption(address(bondToken), 105_000e6);
    }
}
