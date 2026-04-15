// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PauseDomain, Role } from "../types/BondTypes.sol";

/// @title IComplianceModule
/// @notice Interface for per-bond whitelist, role, and transfer-restriction policy modules.
interface IComplianceModule {
    /// @dev Updates whitelist status for one account within the bound bond policy.
    /// @param account Account to update.
    /// @param allowed Whether the account is allowed.
    function setWhitelist(address account, bool allowed) external;

    /// @dev Batch-updates whitelist status for multiple accounts.
    /// @param accounts Accounts to update.
    /// @param allowed Whitelist flags aligned by index.
    function batchSetWhitelist(address[] calldata accounts, bool[] calldata allowed) external;

    /// @dev Sets the role for one account within the bound bond policy.
    /// @param account Account to update.
    /// @param role Role to assign.
    function setRole(address account, Role role) external;

    /// @dev Batch-updates roles for multiple accounts.
    /// @param accounts Accounts to update.
    /// @param roles Roles aligned by index.
    function batchSetRole(address[] calldata accounts, Role[] calldata roles) external;

    /// @dev Updates provider-facing policy metadata for the compliance module.
    /// @param policyId Policy identifier.
    /// @param policyVersion Policy version number.
    function setPolicyMetadata(bytes32 policyId, uint256 policyVersion) external;

    /// @dev Sets the paused state for one compliance-controlled domain.
    /// @param domain Domain to update.
    /// @param paused Whether the domain should be paused.
    function pauseDomain(PauseDomain domain, bool paused) external;

    /// @dev Returns whitelist status for one account.
    /// @param account Account to inspect.
    /// @return allowed True when the account is whitelisted.
    function isWhitelisted(address account) external view returns (bool);

    /// @dev Returns the registered role for one account.
    /// @param account Account to inspect.
    /// @return role Current role.
    function roleOf(address account) external view returns (Role);

    /// @dev Returns whether one domain is paused.
    /// @param domain Domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(PauseDomain domain) external view returns (bool);

    /// @dev Evaluates whether one transfer satisfies the per-bond compliance policy.
    /// @param from Sender address.
    /// @param to Receiver address.
    /// @param amount Transfer amount in smallest bond units.
    /// @param operator Address initiating the transfer (msg.sender on the bond token).
    /// @return restrictionCode Numeric restriction code where zero means success.
    function checkTransfer(address from, address to, uint256 amount, address operator) external view returns (uint8);

    /// @dev Registers or removes an authorized transfer operator (e.g. RFQSettlement).
    /// Only authorized operators may trigger user-to-user bond transfers.
    /// @param operator Operator address.
    /// @param authorized Whether the operator is authorized.
    function setTransferOperator(address operator, bool authorized) external;

    /// @dev Returns whether the given address is an authorized transfer operator.
    /// @param operator Address to inspect.
    /// @return authorized True when the operator is authorized.
    function isTransferOperator(address operator) external view returns (bool);

    /// @dev Returns the current provider-facing policy identifier.
    /// @return id Policy identifier.
    function policyId() external view returns (bytes32);

    /// @dev Returns the current provider-facing policy version.
    /// @return version Policy version number.
    function policyVersion() external view returns (uint256);
}
