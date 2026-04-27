// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { BondToken } from "./BondToken.sol";
import { ComplianceModule } from "./compliance/ComplianceModule.sol";
import { DomainPausable } from "./abstracts/DomainPausable.sol";
import { RoleManaged } from "./abstracts/RoleManaged.sol";
import {
    BondConfigHashMismatch,
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
import { ApprovalStatus, BondConfig, PauseDomain } from "./types/BondTypes.sol";
import { IBondFactory } from "./interfaces/IBondFactory.sol";

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

    /// @dev AUDIT-FIX(N11) revisited: follow the principle of least privilege at construction time.
    ///      Only DEFAULT_ADMIN_ROLE is granted to the initial admin; secondary governance roles
    ///      (ISSUANCE_APPROVER_ROLE / COMPLIANCE_ADMIN_ROLE / PAUSER_ROLE) must be granted
    ///      explicitly via the standard AccessControl `grantRole` API. This eliminates the
    ///      "previous admin retains hidden privileges" risk N11 warns about, because no admin ever
    ///      holds a role they were not explicitly granted.
    ///      Since OpenZeppelin's AccessControl makes DEFAULT_ADMIN_ROLE the default `getRoleAdmin`
    ///      for every role, the initial admin can immediately self-grant any role they need.
    constructor(address admin, address issuanceController_) {
        _ensureNonZero(admin);
        _ensureNonZero(issuanceController_);
        platformAdmin = admin;
        issuanceController = issuanceController_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

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
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiredDeadline(expiresAt, block.timestamp);
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

    function revokeIssuance(bytes32 approvalId) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert InvalidApprovalState(record.status);
        record.status = ApprovalStatus.REVOKED;
        emit IssuanceRevoked(approvalId, record.issuer, msg.sender);
    }

    function markIssuanceExpired(bytes32 approvalId) external {
        IssuanceApprovalRecord storage record = _issuanceApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert InvalidApprovalState(record.status);
        if (record.expiresAt == 0 || record.expiresAt > block.timestamp) revert InvalidApprovalState(record.status);
        record.status = ApprovalStatus.EXPIRED;
        emit IssuanceApprovalExpired(approvalId, record.issuer, msg.sender);
    }

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

    function disableComplianceImplementation(address implementation) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (implementation == address(0)) revert ZeroAddress();
        _approvedComplianceImplementations[implementation] = false;
        emit ComplianceImplementationRegistered(implementation, msg.sender, bytes4(0), false);
    }

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
        if (config.settlementToken == address(0)) revert UnsupportedSettlementToken(config.settlementToken);
        // AUDIT-FIX(N13): pre-validate raw config format errors before binding-hash check so that
        //                 callers continue to receive precise InvalidBondConfig reasons.
        if (bytes(config.name).length == 0) revert InvalidBondConfig("name must not be empty");
        if (bytes(config.symbol).length == 0) revert InvalidBondConfig("symbol must not be empty");
        if (config.faceValue == 0) revert InvalidBondConfig("faceValue must be > 0");
        if (config.maturityTimestamp <= block.timestamp) {
            revert InvalidBondConfig("maturityTimestamp must be in the future");
        }
        if (config.decimals > 18) revert InvalidBondConfig("decimals must be <= 18");
        if (config.couponRateBps > 10_000) revert InvalidBondConfig("couponRateBps must be <= 10000");
        if (config.issueDate < block.timestamp) revert InvalidBondConfig("issueDate must not be in the past");
        if (config.issueDate >= config.maturityTimestamp) {
            revert InvalidIssueDate(config.issueDate, config.maturityTimestamp);
        }
        // AUDIT-FIX(N13): defer the live ERC20Metadata.decimals() probe to BondToken's constructor so
        //                 the only external call performed before state mutation is the integrity hash
        //                 verification (no external call), keeping createBond reentrancy-safe.
        if (config.settlementTokenDecimals > 18) {
            revert InvalidBondConfig("settlementTokenDecimals must be <= 18");
        }
        // AUDIT-FIX(N3): bind the BondConfig to the approver's pre-committed metadataHash so a
        //                malicious issuer cannot bait-and-switch parameters between approval and deploy.
        bytes32 actualHash = _hashBondConfig(config);
        if (actualHash != approval.metadataHash) {
            revert BondConfigHashMismatch(approval.metadataHash, actualHash);
        }
        // AUDIT-FIX(N12): mark the approval as CONSUMED before any external call (e.g. the constructor
        //                 of a malicious settlementToken / compliance impl could re-enter createBond).
        approval.status = ApprovalStatus.CONSUMED;
        complianceModuleAddress = _deployComplianceModule(config);
        bondTokenAddress = _deployBondToken(config, complianceModuleAddress);
        _createdBonds[approvalId] =
            CreatedBondRecord({ bondToken: bondTokenAddress, complianceModule: complianceModuleAddress });
        ComplianceModule(complianceModuleAddress).bindBondToken(bondTokenAddress);
        _emitBondCreated(config, bondTokenAddress, complianceModuleAddress);
    }

    /// @inheritdoc IBondFactory
    /// @dev AUDIT-FIX(N3): canonical BondConfig hashing routine. Approvers must compute this hash
    ///      off-chain and submit it via approveIssuance.metadataHash; the issuer must then submit
    ///      the exact same struct in createBond.
    function hashBondConfig(BondConfig calldata config) external pure returns (bytes32) {
        return _hashBondConfig(config);
    }

    function _hashBondConfig(BondConfig calldata config) internal pure returns (bytes32) {
        return keccak256(abi.encode(config));
    }

    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @notice Update the storage field consumed by `_deployComplianceModule` as the initial admin
    ///         of newly deployed ComplianceModule proxies.
    /// @dev AUDIT-FIX(N11) revisited: this function ONLY rotates the `platformAdmin` storage field.
    ///      It deliberately performs NO AccessControl role management — `platformAdmin` and the
    ///      BondFactory's DEFAULT_ADMIN_ROLE / ISSUANCE_APPROVER_ROLE / COMPLIANCE_ADMIN_ROLE /
    ///      PAUSER_ROLE are independent concepts. Combined with the "constructor only grants
    ///      DEFAULT_ADMIN_ROLE" change, the previous admin never silently keeps secondary roles
    ///      after a handover (because they never had them in the first place — admins explicitly
    ///      grant whatever they need via standard AccessControl).
    /// @dev SECURITY NOTE — Governance handover SOP: when migrating BondFactory governance to a new
    ///      address, follow the standard AccessControl flow:
    ///        1. `grantRole(DEFAULT_ADMIN_ROLE, newGovernance)` — promote the new admin first;
    ///        2. transfer / re-grant any secondary roles (ISSUANCE_APPROVER_ROLE etc.) the new
    ///           admin should hold;
    ///        3. revoke the previous admin's roles in reverse order (secondary first, then
    ///           DEFAULT_ADMIN_ROLE last to avoid bricking) — or have them call `renounceRole`.
    function setPlatformAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ensureNonZero(newAdmin);
        address previousAdmin = platformAdmin;
        platformAdmin = newAdmin;
        emit PlatformAdminUpdated(previousAdmin, newAdmin, msg.sender);
    }

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

    function isComplianceImplementationApproved(address implementation) external view returns (bool) {
        return _approvedComplianceImplementations[implementation];
    }

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
                    // AUDIT-FIX(N13): forward the approved settlement decimals into BondToken so its
                    //                 constructor can re-validate against the live ERC20 metadata.
                    settlementTokenDecimals: config.settlementTokenDecimals,
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
