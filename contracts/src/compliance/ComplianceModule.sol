// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DomainPausable} from "../abstracts/DomainPausable.sol";
import {RoleManaged} from "../abstracts/RoleManaged.sol";
import {
    BondTokenAlreadyBound,
    InvalidArrayLength,
    InvalidBatchSize,
    InvalidParticipantRole,
    ZeroAddress
} from "../libraries/BondErrors.sol";
import {IComplianceModule} from "../interfaces/IComplianceModule.sol";
import {PauseDomain, Role} from "../types/BondTypes.sol";

/// @title ComplianceModule
/// @notice Per-bond compliance policy enforcing whitelist and role-based transfer rules.
/// @dev Each bond series receives its own module instance so policy metadata, whitelist state,
/// and role assignments can evolve independently while the transfer gate remains on-chain.
contract ComplianceModule is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    DomainPausable,
    RoleManaged,
    IComplianceModule
{
    /// @notice Role granted to the factory so it can bind the deployed bond token once.
    bytes32 public constant BOND_FACTORY_ROLE = keccak256("BOND_FACTORY_ROLE");

    /// @notice Transfer restriction code for a fully valid transfer.
    uint8 public constant SUCCESS_CODE = 0;

    /// @notice Transfer restriction code when the module is not yet bound to a bond token.
    uint8 public constant UNBOUND_BOND_CODE = 1;

    /// @notice Transfer restriction code when the sender is not whitelisted.
    uint8 public constant SENDER_NOT_WHITELISTED_CODE = 2;

    /// @notice Transfer restriction code when the receiver is not whitelisted.
    uint8 public constant RECEIVER_NOT_WHITELISTED_CODE = 3;

    /// @notice Transfer restriction code when the sender has an invalid compliance role.
    uint8 public constant INVALID_SENDER_ROLE_CODE = 4;

    /// @notice Transfer restriction code when the receiver has an invalid compliance role.
    uint8 public constant INVALID_RECEIVER_ROLE_CODE = 5;

    /// @notice Transfer restriction code when the transfer direction is not allowed.
    uint8 public constant INVALID_DIRECTION_CODE = 6;

    /// @notice Transfer restriction code when settlement transfers are paused.
    uint8 public constant TRANSFERS_PAUSED_CODE = 7;

    /// @notice Transfer restriction code when the transfer operator is not authorized.
    uint8 public constant UNAUTHORIZED_OPERATOR_CODE = 8;

    /// @notice Maximum number of accounts that may be updated in a single batch call.
    uint256 internal constant MAX_BATCH_SIZE = 200;

    /// @notice Emitted when one whitelist entry changes.
    event WhitelistUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        bool allowed,
        address operator
    );

    /// @notice Emitted when one account role changes.
    event RoleUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        Role role,
        address operator
    );

    /// @notice Emitted when the compliance module is bound to its bond token.
    event BondTokenBound(address indexed bondToken, address indexed complianceModule);

    /// @notice Emitted when provider-facing compliance metadata changes.
    event PolicyMetadataUpdated(
        address indexed bondToken, address indexed complianceModule, bytes32 policyId, uint256 policyVersion
    );

    /// @notice Emitted when an authorized transfer operator is added or removed.
    event TransferOperatorUpdated(address indexed bondToken, address indexed operator, bool authorized, address admin);

    /// @notice Bound bond token governed by this module.
    address public bondToken;

    /// @dev Provider-facing policy identifier stored for off-chain reference.
    bytes32 private _policyId;

    /// @dev Provider-facing policy version stored for off-chain reference.
    uint256 private _policyVersion;

    /// @dev Whitelist state keyed by account.
    mapping(address account => bool allowed) private _whitelist;

    /// @dev Compliance role assignments keyed by account.
    mapping(address account => Role role) private _roles;

    /// @dev Authorized transfer operators (e.g. RFQSettlement) allowed to move bonds between users.
    mapping(address operator => bool authorized) private _authorizedOperators;

    /// @dev Reserved storage gap for future upgrades.
    uint256[44] private __gap;

    /// @dev Locks the implementation contract and requires proxy initialization.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes role holders and provider-facing policy metadata.
    function initialize(address admin, address factory, bytes32 policyId_, uint256 policyVersion_)
        external
        initializer
    {
        if (admin == address(0) || factory == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(BOND_FACTORY_ROLE, factory);

        _policyId = policyId_;
        _policyVersion = policyVersion_;
    }

    /// @dev Binds the per-bond compliance instance to exactly one bond token.
    function bindBondToken(address bondToken_) external onlyRole(BOND_FACTORY_ROLE) {
        if (bondToken_ == address(0)) {
            revert ZeroAddress();
        }

        if (bondToken != address(0)) {
            revert BondTokenAlreadyBound(bondToken);
        }

        bondToken = bondToken_;
        emit BondTokenBound(bondToken_, address(this));
    }

    /// @inheritdoc IComplianceModule
    /// @dev Updates whitelist status for one account and emits the canonical audit event.
    function setWhitelist(address account, bool allowed) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (account == address(0)) revert ZeroAddress();
        _whitelist[account] = allowed;
        emit WhitelistUpdated(bondToken, account, address(this), allowed, msg.sender);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Batch-updates whitelist state for multiple accounts.
    function batchSetWhitelist(address[] calldata accounts, bool[] calldata allowed)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (accounts.length != allowed.length) {
            revert InvalidArrayLength();
        }
        if (accounts.length == 0 || accounts.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(accounts.length, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            _whitelist[accounts[i]] = allowed[i];
            emit WhitelistUpdated(bondToken, accounts[i], address(this), allowed[i], msg.sender);
        }
    }

    /// @inheritdoc IComplianceModule
    /// @dev Assigns one compliance role to one account. Setting Role.NONE clears
    /// the previous role assignment. Valid values: NONE, ISSUER, MARKET_MAKER, INVESTOR.
    function setRole(address account, Role role) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (uint8(role) > uint8(Role.INVESTOR)) {
            revert InvalidParticipantRole(account, Role.INVESTOR, role);
        }
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        _roles[account] = role;
        emit RoleUpdated(bondToken, account, address(this), role, msg.sender);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Batch-updates role assignments for multiple accounts.
    function batchSetRole(address[] calldata accounts, Role[] calldata roles) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (accounts.length != roles.length) {
            revert InvalidArrayLength();
        }
        if (accounts.length == 0 || accounts.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(accounts.length, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            if (uint8(roles[i]) > uint8(Role.INVESTOR)) {
                revert InvalidParticipantRole(accounts[i], Role.INVESTOR, roles[i]);
            }
            _roles[accounts[i]] = roles[i];
            emit RoleUpdated(bondToken, accounts[i], address(this), roles[i], msg.sender);
        }
    }

    /// @inheritdoc IComplianceModule
    /// @dev Updates provider-facing policy metadata without touching whitelist state.
    function setPolicyMetadata(bytes32 policyId_, uint256 policyVersion_) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        _policyId = policyId_;
        _policyVersion = policyVersion_;
        emit PolicyMetadataUpdated(bondToken, address(this), policyId_, policyVersion_);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Toggles one compliance-controlled pause domain.
    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Registers or removes an authorized transfer operator.
    function setTransferOperator(address operator, bool authorized) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        _authorizedOperators[operator] = authorized;
        emit TransferOperatorUpdated(bondToken, operator, authorized, msg.sender);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Returns whether the given address is an authorized transfer operator.
    function isTransferOperator(address operator) external view returns (bool) {
        return _authorizedOperators[operator];
    }

    /// @inheritdoc IComplianceModule
    /// @dev Returns whether the account is currently whitelisted.
    function isWhitelisted(address account) external view returns (bool) {
        return _whitelist[account];
    }

    /// @inheritdoc IComplianceModule
    /// @dev Returns the assigned compliance role for the account.
    function roleOf(address account) external view returns (Role) {
        return _roles[account];
    }

    /// @inheritdoc IComplianceModule
    /// @dev Exposes inherited pause state for interface compliance and monitoring.
    function isDomainPaused(PauseDomain domain) public view override(DomainPausable, IComplianceModule) returns (bool) {
        return super.isDomainPaused(domain);
    }

    /// @inheritdoc IComplianceModule
    /// @dev Evaluates the full transfer policy and returns an ERC1404-style restriction code.
    /// NOTE: The `amount` parameter is intentionally unused — the current policy is purely
    /// address/role-based. Future upgrades via UUPS can add per-transfer or cumulative limits.
    /// The `operator` parameter is the address that initiated the transfer on the bond token
    /// (msg.sender to transfer/transferFrom). Only authorized operators (e.g. RFQSettlement)
    /// may trigger user-to-user transfers, ensuring all trades go through the platform.
    function checkTransfer(address from, address to, uint256, address operator) external view returns (uint8) {
        if (bondToken == address(0)) {
            return UNBOUND_BOND_CODE;
        }

        if (isDomainPaused(PauseDomain.SETTLEMENT)) {
            return TRANSFERS_PAUSED_CODE;
        }

        if (!_authorizedOperators[operator]) {
            return UNAUTHORIZED_OPERATOR_CODE;
        }

        if (!_whitelist[from]) {
            return SENDER_NOT_WHITELISTED_CODE;
        }

        if (!_whitelist[to]) {
            return RECEIVER_NOT_WHITELISTED_CODE;
        }

        Role fromRole = _roles[from];
        Role toRole = _roles[to];

        if (fromRole != Role.MARKET_MAKER && fromRole != Role.INVESTOR) {
            return INVALID_SENDER_ROLE_CODE;
        }

        if (toRole != Role.MARKET_MAKER && toRole != Role.INVESTOR) {
            return INVALID_RECEIVER_ROLE_CODE;
        }

        if (fromRole == Role.INVESTOR && toRole == Role.INVESTOR) {
            return INVALID_DIRECTION_CODE;
        }

        return SUCCESS_CODE;
    }

    /// @inheritdoc IComplianceModule
    /// @dev Returns the provider-facing policy identifier.
    function policyId() external view returns (bytes32) {
        return _policyId;
    }

    /// @inheritdoc IComplianceModule
    /// @dev Returns the provider-facing policy version.
    function policyVersion() external view returns (uint256) {
        return _policyVersion;
    }

    /// @dev Declares ERC165 support for the compliance module interface.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IComplianceModule).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Restricts UUPS upgrades to the configured upgrader role.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
