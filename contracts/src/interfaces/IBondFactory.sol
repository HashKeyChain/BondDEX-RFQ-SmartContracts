// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ApprovalStatus, BondConfig, PauseDomain} from "../types/BondTypes.sol";

/// @title IBondFactory
/// @notice Interface for the factory that approves issuances and deploys new bond series.
interface IBondFactory {
    /// @dev Approves one issuer launch window and binds it to an allowed compliance implementation.
    /// @param approvalId Unique approval identifier.
    /// @param issuer Approved issuer address.
    /// @param complianceImplementation Approved compliance implementation template.
    /// @param expiresAt Expiry timestamp for the approval.
    /// @param metadataHash Offchain issuance packet reference.
    function approveIssuance(
        bytes32 approvalId,
        address issuer,
        address complianceImplementation,
        uint256 expiresAt,
        bytes32 metadataHash
    ) external;

    /// @dev Revokes a previously approved issuance record.
    /// @param approvalId Unique approval identifier.
    function revokeIssuance(bytes32 approvalId) external;

    /// @dev Registers one compliance implementation that future bonds may instantiate.
    /// @param implementation Compliance implementation address.
    /// @param interfaceId ERC165 interface identifier expected from the implementation.
    function registerComplianceImplementation(
        address implementation,
        bytes4 interfaceId
    ) external;

    /// @dev Disables one previously approved compliance implementation.
    /// @param implementation Compliance implementation address.
    function disableComplianceImplementation(address implementation) external;

    /// @dev Creates one bond token and one isolated compliance module from an active approval.
    /// @param config Immutable bond configuration payload.
    /// @param approvalId Active issuance approval identifier.
    /// @return bondToken Deployed bond token address.
    /// @return complianceModule Deployed per-bond compliance module address.
    function createBond(
        BondConfig calldata config,
        bytes32 approvalId
    ) external returns (address bondToken, address complianceModule);

    /// @dev Sets the paused state for one factory-controlled domain.
    /// @param domain Domain to update.
    /// @param paused Whether the domain should be paused.
    function pauseDomain(PauseDomain domain, bool paused) external;

    /// @dev Updates the platform administrator and grants it DEFAULT_ADMIN_ROLE.
    /// New ComplianceModules will be initialized with the updated admin.
    /// @param newAdmin New platform administrator address.
    function setPlatformAdmin(address newAdmin) external;

    /// @dev Returns one issuance approval record.
    /// @param approvalId Unique approval identifier.
    /// @return issuer Approved issuer address.
    /// @return complianceImplementation Bound compliance implementation.
    /// @return status Current approval status.
    /// @return expiresAt Expiry timestamp.
    /// @return metadataHash Offchain issuance packet reference.
    function getIssuanceApproval(
        bytes32 approvalId
    )
        external
        view
        returns (
            address issuer,
            address complianceImplementation,
            ApprovalStatus status,
            uint256 expiresAt,
            bytes32 metadataHash
        );

    /// @dev Returns whether one compliance implementation is approved for bond creation.
    /// @param implementation Compliance implementation address.
    /// @return approved True when the implementation is approved.
    function isComplianceImplementationApproved(
        address implementation
    ) external view returns (bool);

    /// @dev Returns the created bond token and compliance module addresses for one approval.
    /// @param approvalId Unique approval identifier.
    /// @return bondToken Deployed bond token address.
    /// @return complianceModule Deployed compliance module address.
    function getBondAddresses(
        bytes32 approvalId
    ) external view returns (address bondToken, address complianceModule);
}
