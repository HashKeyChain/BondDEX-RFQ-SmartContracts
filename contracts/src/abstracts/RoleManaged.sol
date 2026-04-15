// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ZeroAddress } from "../libraries/BondErrors.sol";

abstract contract RoleManaged {
    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE = keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function _ensureNonZero(address account) internal pure {
        if (account == address(0)) revert ZeroAddress();
    }
}
