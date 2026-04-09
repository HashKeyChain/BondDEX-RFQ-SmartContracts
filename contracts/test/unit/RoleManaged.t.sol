// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RoleManaged} from "../../src/abstracts/RoleManaged.sol";
import {ZeroAddress} from "../../src/libraries/BondErrors.sol";

contract RoleManagedHarness is RoleManaged {
    constructor(address admin) {
        _ensureNonZero(admin);
    }

    function issuanceApproverRole() external pure returns (bytes32) {
        return ISSUANCE_APPROVER_ROLE;
    }

    function complianceAdminRole() external pure returns (bytes32) {
        return COMPLIANCE_ADMIN_ROLE;
    }

    function settlementAdminRole() external pure returns (bytes32) {
        return SETTLEMENT_ADMIN_ROLE;
    }

    function pauserRole() external pure returns (bytes32) {
        return PAUSER_ROLE;
    }

    function upgraderRole() external pure returns (bytes32) {
        return UPGRADER_ROLE;
    }
}

contract RoleManagedTest is Test {
    function test_revertWhenAdminIsZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new RoleManagedHarness(address(0));
    }

    function test_roleConstantsMatchExpectedHashes() public {
        RoleManagedHarness harness = new RoleManagedHarness(address(1));

        assertEq(
            harness.issuanceApproverRole(),
            keccak256("ISSUANCE_APPROVER_ROLE")
        );
        assertEq(
            harness.complianceAdminRole(),
            keccak256("COMPLIANCE_ADMIN_ROLE")
        );
        assertEq(
            harness.settlementAdminRole(),
            keccak256("SETTLEMENT_ADMIN_ROLE")
        );
        assertEq(harness.pauserRole(), keccak256("PAUSER_ROLE"));
        assertEq(harness.upgraderRole(), keccak256("UPGRADER_ROLE"));
    }
}
