// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ZeroAddress} from "../libraries/BondErrors.sol";

/// @title RoleManaged
/// @notice Shared role identifiers and address validation helpers for BondDEX control-plane contracts.
abstract contract RoleManaged {
    /// @notice Role allowed to approve or revoke new bond issuance packets.
    bytes32 internal constant ISSUANCE_APPROVER_ROLE =
        keccak256("ISSUANCE_APPROVER_ROLE");

    /// @notice Role allowed to manage compliance implementations and bond-level policy admins.
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE =
        keccak256("COMPLIANCE_ADMIN_ROLE");

    /// @notice Role allowed to manage settlement-token policy and fee configuration.
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE =
        keccak256("SETTLEMENT_ADMIN_ROLE");

    /// @notice Emergency role allowed to pause lifecycle domains.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Governance role allowed to authorize UUPS upgrades.
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev Reverts when a required address is zero.
    /// @param account Address to validate.
    function _ensureNonZero(address account) internal pure {
        if (account == address(0)) {
            revert ZeroAddress();
        }
    }
}
