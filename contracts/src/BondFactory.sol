// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BondToken} from "./BondToken.sol";
import {ComplianceModule} from "./compliance/ComplianceModule.sol";
import {DomainPausable} from "./abstracts/DomainPausable.sol";
import {RoleManaged} from "./abstracts/RoleManaged.sol";
import {
    ExpiredDeadline,
    InvalidApprovalState,
    UnsupportedInterface,
    UnsupportedSettlementToken,
    ZeroAddress
} from "./libraries/BondErrors.sol";
import {ApprovalStatus, BondConfig, PauseDomain} from "./types/BondTypes.sol";
import {IBondFactory} from "./interfaces/IBondFactory.sol";

/// @title BondFactory
/// @notice Control-plane contract that approves launches and deploys new bond instances.
/// @dev The factory binds platform approval, immutable bond metadata, and the selected
/// compliance implementation into one bond token plus one isolated compliance module.
contract BondFactory is
    AccessControl,
    DomainPausable,
    RoleManaged,
    IBondFactory
{
    /// @dev Stores the approval packet consumed by `createBond`.
    struct IssuanceApprovalRecord {
        /// @dev Issuer that is allowed to consume the approval.
        address issuer;
        /// @dev Compliance implementation template that must back the new bond.
        address complianceImplementation;
        /// @dev Current approval lifecycle status.
        ApprovalStatus status;
        /// @dev Optional deadline after which the approval can no longer be used.
        uint256 expiresAt;
        /// @dev Off-chain metadata reference for the issuance packet.
        bytes32 metadataHash;
    }

    /// @dev Stores the deployed addresses produced from one approval record.
    struct CreatedBondRecord {
        /// @dev Newly deployed bond token address.
        address bondToken;
        /// @dev Newly deployed per-bond compliance module address.
        address complianceModule;
    }

    /// @notice Emitted when governance approves one issuer launch window.
    event IssuanceApproved(
        bytes32 indexed approvalId,
        address indexed issuer,
        address approver,
        uint256 expiresAt,
        address complianceImplementation,
        bytes32 metadataHash
    );

    /// @notice Emitted when governance revokes one issuance approval.
    event IssuanceRevoked(
        bytes32 indexed approvalId,
        address indexed issuer,
        address revoker
    );

    /// @notice Emitted when a compliance implementation template is enabled or disabled.
    event ComplianceImplementationRegistered(
        address indexed implementation,
        address indexed registrar,
        bytes4 interfaceId,
        bool enabled
    );

    /// @notice Emitted when governance updates the platform administrator.
    event PlatformAdminUpdated(
        address indexed previousAdmin,
        address indexed newAdmin,
        address indexed operator
    );

    /// @notice Emitted when the factory successfully creates one bond series.
    event BondCreated(
        address indexed bondToken,
        address indexed issuer,
        address indexed complianceModule,
        string name,
        string symbol,
        uint8 decimals,
        uint256 faceValue,
        uint256 couponRateBps,
        uint256 maturityTimestamp,
        address settlementToken
    );

    /// @notice Issuance controller passed into every deployed bond token.
    address public immutable issuanceController;

    /// @notice Platform administrator injected into each deployed compliance module.
    address public platformAdmin;

    /// @dev Approval packets keyed by approval identifier.
    mapping(bytes32 approvalId => IssuanceApprovalRecord record)
        private _issuanceApprovals;

    /// @dev Compliance implementation allowlist keyed by template address.
    mapping(address implementation => bool approved)
        private _approvedComplianceImplementations;

    /// @dev Created bond addresses keyed by the approval that spawned them.
    mapping(bytes32 approvalId => CreatedBondRecord record)
        private _createdBonds;

    /// @param admin Default administrator for the factory control plane.
    /// @param issuanceController_ Issuance controller address shared by deployed bond tokens.
    constructor(address admin, address issuanceController_) {
        _ensureNonZero(admin);
        _ensureNonZero(issuanceController_);

        platformAdmin = admin;
        issuanceController = issuanceController_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUANCE_APPROVER_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @inheritdoc IBondFactory
    /// @dev Records one issuance approval that can later be consumed exactly once.
    function approveIssuance(
        bytes32 approvalId,
        address issuer,
        address complianceImplementation,
        uint256 expiresAt,
        bytes32 metadataHash
    ) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        if (issuer == address(0) || complianceImplementation == address(0)) {
            revert ZeroAddress();
        }

        _issuanceApprovals[approvalId] = IssuanceApprovalRecord({
            issuer: issuer,
            complianceImplementation: complianceImplementation,
            status: ApprovalStatus.ACTIVE,
            expiresAt: expiresAt,
            metadataHash: metadataHash
        });

        emit IssuanceApproved(
            approvalId,
            issuer,
            msg.sender,
            expiresAt,
            complianceImplementation,
            metadataHash
        );
    }

    /// @inheritdoc IBondFactory
    /// @dev Marks one approval as revoked so it cannot be consumed by the issuer.
    function revokeIssuance(
        bytes32 approvalId
    ) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        record.status = ApprovalStatus.REVOKED;
        emit IssuanceRevoked(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondFactory
    /// @dev Registers one compliance implementation after verifying the expected interface.
    function registerComplianceImplementation(
        address implementation,
        bytes4 interfaceId
    ) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (implementation == address(0)) {
            revert ZeroAddress();
        }

        if (!IERC165(implementation).supportsInterface(interfaceId)) {
            revert UnsupportedInterface(implementation, interfaceId);
        }

        _approvedComplianceImplementations[implementation] = true;
        emit ComplianceImplementationRegistered(
            implementation,
            msg.sender,
            interfaceId,
            true
        );
    }

    /// @inheritdoc IBondFactory
    /// @dev Disables one compliance implementation template without deleting its history.
    function disableComplianceImplementation(
        address implementation
    ) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _approvedComplianceImplementations[implementation] = false;
        emit ComplianceImplementationRegistered(
            implementation,
            msg.sender,
            bytes4(0),
            false
        );
    }

    /// @inheritdoc IBondFactory
    /// @dev Validates the approval packet, deploys the bond pair, and consumes the approval.
    function createBond(
        BondConfig calldata config,
        bytes32 approvalId
    )
        external
        returns (address bondTokenAddress, address complianceModuleAddress)
    {
        // The factory can be paused independently from the issuance and settlement flows.
        _requireDomainActive(PauseDomain.FACTORY);

        IssuanceApprovalRecord storage approval = _issuanceApprovals[
            approvalId
        ];
        if (approval.status != ApprovalStatus.ACTIVE) {
            revert InvalidApprovalState(approval.status);
        }

        if (approval.expiresAt != 0 && approval.expiresAt < block.timestamp) {
            revert ExpiredDeadline(approval.expiresAt, block.timestamp);
        }

        if (approval.issuer != msg.sender || config.issuer != msg.sender) {
            revert ZeroAddress();
        }

        if (
            approval.complianceImplementation !=
            config.complianceImplementation ||
            !_approvedComplianceImplementations[config.complianceImplementation]
        ) {
            revert UnsupportedInterface(
                config.complianceImplementation,
                bytes4(0)
            );
        }

        if (config.settlementToken == address(0)) {
            revert UnsupportedSettlementToken(config.settlementToken);
        }

        // Deploy one isolated compliance module and one immutable bond token for this approval.
        complianceModuleAddress = _deployComplianceModule(config);
        bondTokenAddress = _deployBondToken(config, complianceModuleAddress);

        // Consume the approval so the same packet cannot be replayed.
        approval.status = ApprovalStatus.CONSUMED;
        _createdBonds[approvalId] = CreatedBondRecord({
            bondToken: bondTokenAddress,
            complianceModule: complianceModuleAddress
        });

        // The compliance module is deployed before the bond token is bound so the token address is final.
        ComplianceModule(complianceModuleAddress).bindBondToken(
            bondTokenAddress
        );

        _emitBondCreated(config, bondTokenAddress, complianceModuleAddress);
    }

    /// @inheritdoc IBondFactory
    /// @dev Toggles the paused state for one factory-controlled domain.
    function pauseDomain(
        PauseDomain domain,
        bool paused
    ) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IBondFactory
    /// @dev Updates the platform admin and simultaneously transfers DEFAULT_ADMIN_ROLE
    /// so newly deployed ComplianceModules receive the correct governance address.
    function setPlatformAdmin(
        address newAdmin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ensureNonZero(newAdmin);

        address previousAdmin = platformAdmin;
        platformAdmin = newAdmin;

        if (!hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) {
            _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        }

        emit PlatformAdminUpdated(previousAdmin, newAdmin, msg.sender);
    }

    /// @inheritdoc IBondFactory
    /// @dev Returns the stored approval packet for one approval identifier.
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
        )
    {
        IssuanceApprovalRecord memory record = _issuanceApprovals[approvalId];
        return (
            record.issuer,
            record.complianceImplementation,
            record.status,
            record.expiresAt,
            record.metadataHash
        );
    }

    /// @inheritdoc IBondFactory
    /// @dev Returns whether one compliance implementation is currently enabled for new bonds.
    function isComplianceImplementationApproved(
        address implementation
    ) external view returns (bool) {
        return _approvedComplianceImplementations[implementation];
    }

    /// @inheritdoc IBondFactory
    /// @dev Returns the bond token and compliance module addresses created from one approval.
    function getBondAddresses(
        bytes32 approvalId
    ) external view returns (address bondToken, address complianceModule) {
        CreatedBondRecord memory record = _createdBonds[approvalId];
        return (record.bondToken, record.complianceModule);
    }

    /// @dev Deploys one upgradeable compliance module proxy for the new bond series.
    function _deployComplianceModule(
        BondConfig calldata config
    ) internal returns (address) {
        return
            address(
                new ERC1967Proxy(
                    config.complianceImplementation,
                    abi.encodeCall(
                        ComplianceModule.initialize,
                        (
                            platformAdmin,
                            address(this),
                            config.policyId,
                            config.policyVersion
                        )
                    )
                )
            );
    }

    /// @dev Deploys one immutable bond token wired to the issuance controller and compliance module.
    function _deployBondToken(
        BondConfig calldata config,
        address complianceModuleAddress
    ) internal returns (address) {
        return
            address(
                new BondToken(
                    config.issuer,
                    config.name,
                    config.symbol,
                    config.decimals,
                    config.faceValue,
                    config.couponRateBps,
                    config.maturityTimestamp,
                    config.settlementToken,
                    complianceModuleAddress,
                    issuanceController
                )
            );
    }

    /// @dev Emits the canonical bond creation event consumed by off-chain indexers.
    function _emitBondCreated(
        BondConfig calldata config,
        address bondTokenAddress,
        address complianceModuleAddress
    ) internal {
        emit BondCreated(
            bondTokenAddress,
            config.issuer,
            complianceModuleAddress,
            config.name,
            config.symbol,
            config.decimals,
            config.faceValue,
            config.couponRateBps,
            config.maturityTimestamp,
            config.settlementToken
        );
    }
}
