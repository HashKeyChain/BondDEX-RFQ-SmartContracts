// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

contract BondFactory is AccessControl, DomainPausable, RoleManaged, IBondFactory {
    struct IssuanceApprovalRecord {
        address issuer;
        address complianceImplementation;
        ApprovalStatus status;
        uint256 expiresAt;
        bytes32 metadataHash;
    }

    struct CreatedBondRecord {
        address bondToken;
        address complianceModule;
    }

    event IssuanceApproved(
        bytes32 indexed approvalId,
        address indexed issuer,
        address approver,
        uint256 expiresAt,
        address complianceImplementation,
        bytes32 metadataHash
    );
    event IssuanceRevoked(bytes32 indexed approvalId, address indexed issuer, address revoker);
    event ComplianceImplementationRegistered(
        address indexed implementation,
        address indexed registrar,
        bytes4 interfaceId,
        bool enabled
    );
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

    address public immutable issuanceController;
    address public immutable platformAdmin;

    mapping(bytes32 approvalId => IssuanceApprovalRecord record) private _issuanceApprovals;
    mapping(address implementation => bool approved) private _approvedComplianceImplementations;
    mapping(bytes32 approvalId => CreatedBondRecord record) private _createdBonds;

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
            approvalId, issuer, msg.sender, expiresAt, complianceImplementation, metadataHash
        );
    }

    /// @inheritdoc IBondFactory
    function revokeIssuance(bytes32 approvalId) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        record.status = ApprovalStatus.REVOKED;
        emit IssuanceRevoked(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondFactory
    function registerComplianceImplementation(address implementation, bytes4 interfaceId)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        if (implementation == address(0)) {
            revert ZeroAddress();
        }

        if (!IERC165(implementation).supportsInterface(interfaceId)) {
            revert UnsupportedInterface(implementation, interfaceId);
        }

        _approvedComplianceImplementations[implementation] = true;
        emit ComplianceImplementationRegistered(implementation, msg.sender, interfaceId, true);
    }

    /// @inheritdoc IBondFactory
    function disableComplianceImplementation(address implementation) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _approvedComplianceImplementations[implementation] = false;
        emit ComplianceImplementationRegistered(implementation, msg.sender, bytes4(0), false);
    }

    /// @inheritdoc IBondFactory
    function createBond(BondConfig calldata config, bytes32 approvalId)
        external
        returns (address bondTokenAddress, address complianceModuleAddress)
    {
        _requireDomainActive(PauseDomain.FACTORY);

        IssuanceApprovalRecord storage approval = _issuanceApprovals[approvalId];
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
            approval.complianceImplementation != config.complianceImplementation
                || !_approvedComplianceImplementations[config.complianceImplementation]
        ) {
            revert UnsupportedInterface(config.complianceImplementation, bytes4(0));
        }

        if (config.settlementToken == address(0)) {
            revert UnsupportedSettlementToken(config.settlementToken);
        }

        complianceModuleAddress = _deployComplianceModule(config);
        bondTokenAddress = _deployBondToken(config, complianceModuleAddress);

        approval.status = ApprovalStatus.CONSUMED;
        _createdBonds[approvalId] =
            CreatedBondRecord({bondToken: bondTokenAddress, complianceModule: complianceModuleAddress});

        ComplianceModule(complianceModuleAddress).bindBondToken(bondTokenAddress);

        _emitBondCreated(config, bondTokenAddress, complianceModuleAddress);
    }

    /// @inheritdoc IBondFactory
    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IBondFactory
    function getIssuanceApproval(bytes32 approvalId)
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
        return (record.issuer, record.complianceImplementation, record.status, record.expiresAt, record.metadataHash);
    }

    /// @inheritdoc IBondFactory
    function isComplianceImplementationApproved(address implementation) external view returns (bool) {
        return _approvedComplianceImplementations[implementation];
    }

    /// @inheritdoc IBondFactory
    function getBondAddresses(bytes32 approvalId)
        external
        view
        returns (address bondToken, address complianceModule)
    {
        CreatedBondRecord memory record = _createdBonds[approvalId];
        return (record.bondToken, record.complianceModule);
    }

    function _deployComplianceModule(BondConfig calldata config) internal returns (address) {
        return address(
            new ERC1967Proxy(
                config.complianceImplementation,
                abi.encodeCall(
                    ComplianceModule.initialize,
                    (platformAdmin, address(this), config.policyId, config.policyVersion)
                )
            )
        );
    }

    function _deployBondToken(BondConfig calldata config, address complianceModuleAddress)
        internal
        returns (address)
    {
        return address(
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
