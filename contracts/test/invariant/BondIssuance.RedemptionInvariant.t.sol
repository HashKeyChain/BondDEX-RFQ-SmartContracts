// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {BondIssuanceRedemptionFixtures} from "../helpers/BondIssuanceRedemptionFixtures.sol";

contract BondIssuanceRedemptionHandler is BondIssuanceRedemptionFixtures {
    constructor() {
        deployRedemptionFixtures();
        warpToMaturity();
        vm.prank(issuer);
        issuance.depositRedemption(address(bondToken), 105_000e6);
        vm.prank(holder);
        issuance.setClaimDelegate(delegate);
    }

    function delegateClaim() external {
        vm.prank(delegate);
        try issuance.claimFor(address(bondToken), holder) {} catch {}
    }

    function usdcToken() external view returns (address) {
        return address(usdc);
    }

    function delegateAccount() external view returns (address) {
        return delegate;
    }
}

contract BondIssuanceRedemptionInvariantTest is StdInvariant, Test {
    BondIssuanceRedemptionHandler internal handler;

    function setUp() public {
        handler = new BondIssuanceRedemptionHandler();
        targetContract(address(handler));
    }

    function invariant_delegateNeverReceivesPayout() public view {
        assertEq(IERC20Like(handler.usdcToken()).balanceOf(handler.delegateAccount()), 0);
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
