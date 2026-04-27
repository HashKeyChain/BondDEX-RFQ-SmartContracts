// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ApprovalStatus, BondConfig, PauseDomain } from "../types/BondTypes.sol";

interface IBondFactory {
    function approveIssuance(
        bytes32 approvalId,
        address issuer,
        address complianceImplementation,
        uint256 expiresAt,
        bytes32 metadataHash
    ) external;
    function revokeIssuance(bytes32 approvalId) external;
    function markIssuanceExpired(bytes32 approvalId) external;
    function registerComplianceImplementation(address implementation, bytes4 interfaceId) external;
    function disableComplianceImplementation(address implementation) external;
    function createBond(BondConfig calldata config, bytes32 approvalId)
        external
        returns (address bondToken, address complianceModule);
    function pauseDomain(PauseDomain domain, bool paused) external;
    function setPlatformAdmin(address newAdmin) external;
    function getIssuanceApproval(bytes32 approvalId)
        external
        view
        returns (
            address issuer,
            address complianceImplementation,
            ApprovalStatus status,
            uint256 expiresAt,
            bytes32 metadataHash
        );
    function isComplianceImplementationApproved(address implementation) external view returns (bool);
    function getBondAddresses(bytes32 approvalId) external view returns (address bondToken, address complianceModule);
    /// @dev AUDIT-FIX(N3): canonical hashing function shared between approver and issuer to bind
    ///      the BondConfig integrity to the approval record's metadataHash.
    function hashBondConfig(BondConfig calldata config) external pure returns (bytes32);
}
