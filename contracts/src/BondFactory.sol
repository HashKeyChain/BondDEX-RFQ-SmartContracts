// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BondToken} from "./BondToken.sol";
import {ComplianceModule} from "./compliance/ComplianceModule.sol";
import {DomainPausable} from "./abstracts/DomainPausable.sol";
import {RoleManaged} from "./abstracts/RoleManaged.sol";
import {
    ExpiredDeadline,
    InvalidApprovalState,
    InvalidBondConfig,
    InvalidIssueDate,
    UnauthorizedIssuer,
    UnsupportedInterface,
    UnsupportedSettlementToken,
    ZeroAddress,
    ZeroId
} from "./libraries/BondErrors.sol";
import {ApprovalStatus, BondConfig, PauseDomain} from "./types/BondTypes.sol";
import {IBondFactory} from "./interfaces/IBondFactory.sol";

/// @title BondFactory
/// @notice Control-plane contract that approves launches and deploys new bond instances.
/// @dev Intentionally NOT upgradeable to reduce attack surface; deploy a new factory if a bug is found.
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
        address indexed implementation, address indexed registrar, bytes4 interfaceId, bool enabled
    );

    event IssuanceApprovalExpired(bytes32 indexed approvalId, address indexed issuer, address operator);

    event PlatformAdminUpdated(address indexed previousAdmin, address indexed newAdmin, address indexed operator);

    /// @dev Split into two events to avoid stack-too-deep.
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
        address settlementToken,
        uint256 issueDate
    );

    event BondMetadata(
        address indexed bondToken, uint8 dayCountConvention, uint8 couponFrequency, uint8 bondCategory, bytes12 isin
    );

    address public immutable issuanceController;
    address public platformAdmin;

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
        if (approvalId == bytes32(0)) revert ZeroId();
        if (issuer == address(0) || complianceImplementation == address(0)) revert ZeroAddress();
        if (!_approvedComplianceImplementations[complianceImplementation]) {
            revert UnsupportedInterface(complianceImplementation, bytes4(0));
        }
        if (expiresAt != 0 && expiresAt <= block.timestamp) {
            revert ExpiredDeadline(expiresAt, block.timestamp);
        }

        ApprovalStatus currentStatus = _issuanceApprovals[approvalId].status;
        if (currentStatus != ApprovalStatus.NONE) revert InvalidApprovalState(currentStatus);

        _issuanceApprovals[approvalId] = IssuanceApprovalRecord({
            issuer: issuer,
            complianceImplementation: complianceImplementation,
            status: ApprovalStatus.ACTIVE,
            expiresAt: expiresAt,
            metadataHash: metadataHash
        });

        emit IssuanceApproved(approvalId, issuer, msg.sender, expiresAt, complianceImplementation, metadataHash);
    }

    /// @inheritdoc IBondFactory
    function revokeIssuance(bytes32 approvalId) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert InvalidApprovalState(record.status);
        record.status = ApprovalStatus.REVOKED;
        emit IssuanceRevoked(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondFactory
    function markIssuanceExpired(bytes32 approvalId) external {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert InvalidApprovalState(record.status);
        if (record.expiresAt == 0 || record.expiresAt > block.timestamp) {
            revert InvalidApprovalState(record.status);
        }
        record.status = ApprovalStatus.EXPIRED;
        emit IssuanceApprovalExpired(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondFactory
    function registerComplianceImplementation(address implementation, bytes4 interfaceId)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        if (implementation == address(0)) revert ZeroAddress();
        if (!IERC165(implementation).supportsInterface(interfaceId)) {
            revert UnsupportedInterface(implementation, interfaceId);
        }
        _approvedComplianceImplementations[implementation] = true;
        emit ComplianceImplementationRegistered(implementation, msg.sender, interfaceId, true);
    }

    /// @inheritdoc IBondFactory
    function disableComplianceImplementation(address implementation) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (implementation == address(0)) revert ZeroAddress();
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
        if (approval.status != ApprovalStatus.ACTIVE) revert InvalidApprovalState(approval.status);
        if (approval.expiresAt != 0 && approval.expiresAt <= block.timestamp) {
            revert ExpiredDeadline(approval.expiresAt, block.timestamp);
        }
        if (approval.issuer != msg.sender || config.issuer != msg.sender) {
            revert UnauthorizedIssuer(msg.sender, approval.issuer);
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
        try IERC20Metadata(config.settlementToken).decimals() returns (uint8 actualDecimals) {
            if (config.settlementTokenDecimals != actualDecimals) {
                revert InvalidBondConfig("settlementTokenDecimals mismatch");
            }
        } catch {
            revert UnsupportedSettlementToken(config.settlementToken);
        }
        if (bytes(config.name).length == 0) revert InvalidBondConfig("name must not be empty");
        if (bytes(config.symbol).length == 0) revert InvalidBondConfig("symbol must not be empty");
        if (config.faceValue == 0) revert InvalidBondConfig("faceValue must be > 0");
        if (config.maturityTimestamp <= block.timestamp) {
            revert InvalidBondConfig("maturityTimestamp must be in the future");
        }
        if (config.decimals > 18) revert InvalidBondConfig("decimals must be <= 18");
        if (config.couponRateBps > 10_000) {
            revert InvalidBondConfig("couponRateBps must be <= 10000");
        }
        if (config.issueDate < block.timestamp) {
            revert InvalidBondConfig("issueDate must not be in the past");
        }
        if (config.issueDate >= config.maturityTimestamp) {
            revert InvalidIssueDate(config.issueDate, config.maturityTimestamp);
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
    /// @dev Only updates platformAdmin; does NOT perform a full admin role transfer.
    function setPlatformAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ensureNonZero(newAdmin);
        address previousAdmin = platformAdmin;
        platformAdmin = newAdmin;

        if (!hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        if (previousAdmin != newAdmin && previousAdmin != msg.sender && hasRole(DEFAULT_ADMIN_ROLE, previousAdmin)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        }

        emit PlatformAdminUpdated(previousAdmin, newAdmin, msg.sender);
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
    function getBondAddresses(bytes32 approvalId) external view returns (address bondToken, address complianceModule) {
        CreatedBondRecord memory record = _createdBonds[approvalId];
        return (record.bondToken, record.complianceModule);
    }

    function _deployComplianceModule(BondConfig calldata config) internal returns (address) {
        return address(
            new ERC1967Proxy(
                config.complianceImplementation,
                abi.encodeCall(
                    ComplianceModule.initialize, (platformAdmin, address(this), config.policyId, config.policyVersion)
                )
            )
        );
    }

    function _deployBondToken(BondConfig calldata config, address complianceModuleAddress) internal returns (address) {
        return address(
            new BondToken(
                BondToken.ConstructorParams({
                    issuer: config.issuer,
                    name: config.name,
                    symbol: config.symbol,
                    decimals: config.decimals,
                    faceValue: config.faceValue,
                    couponRateBps: config.couponRateBps,
                    maturityTimestamp: config.maturityTimestamp,
                    settlementToken: config.settlementToken,
                    complianceModule: complianceModuleAddress,
                    issuanceController: issuanceController,
                    issueDate: config.issueDate,
                    dayCountConvention: config.dayCountConvention,
                    couponFrequency: config.couponFrequency,
                    bondCategory: config.bondCategory,
                    isin: config.isin
                })
            )
        );
    }

    function _emitBondCreated(BondConfig calldata config, address bondTokenAddress, address complianceModuleAddress)
        internal
    {
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
            config.settlementToken,
            config.issueDate
        );
        emit BondMetadata(
            bondTokenAddress,
            uint8(config.dayCountConvention),
            uint8(config.couponFrequency),
            uint8(config.bondCategory),
            config.isin
        );
    }
}
