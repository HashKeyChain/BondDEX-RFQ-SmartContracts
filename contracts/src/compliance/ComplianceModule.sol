// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DomainPausable} from "../abstracts/DomainPausable.sol";
import {RoleManaged} from "../abstracts/RoleManaged.sol";
import {
    BondTokenAlreadyBound,
    InvalidArrayLength,
    ZeroAddress
} from "../libraries/BondErrors.sol";
import {IComplianceModule} from "../interfaces/IComplianceModule.sol";
import {PauseDomain, Role} from "../types/BondTypes.sol";

contract ComplianceModule is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    DomainPausable,
    RoleManaged,
    IComplianceModule
{
    bytes32 public constant BOND_FACTORY_ROLE = keccak256("BOND_FACTORY_ROLE");

    uint8 public constant SUCCESS_CODE = 0;
    uint8 public constant UNBOUND_BOND_CODE = 1;
    uint8 public constant SENDER_NOT_WHITELISTED_CODE = 2;
    uint8 public constant RECEIVER_NOT_WHITELISTED_CODE = 3;
    uint8 public constant INVALID_SENDER_ROLE_CODE = 4;
    uint8 public constant INVALID_RECEIVER_ROLE_CODE = 5;
    uint8 public constant INVALID_DIRECTION_CODE = 6;
    uint8 public constant TRANSFERS_PAUSED_CODE = 7;

    event WhitelistUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        bool allowed,
        address operator
    );
    event RoleUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        Role role,
        address operator
    );
    event PolicyMetadataUpdated(
        address indexed bondToken,
        address indexed complianceModule,
        bytes32 policyId,
        uint256 policyVersion
    );

    address public bondToken;
    bytes32 private _policyId;
    uint256 private _policyVersion;
    mapping(address account => bool allowed) private _whitelist;
    mapping(address account => Role role) private _roles;
    uint256[46] private __gap;

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
    }

    /// @inheritdoc IComplianceModule
    function setWhitelist(address account, bool allowed) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _whitelist[account] = allowed;
        emit WhitelistUpdated(bondToken, account, address(this), allowed, msg.sender);
    }

    /// @inheritdoc IComplianceModule
    function batchSetWhitelist(address[] calldata accounts, bool[] calldata allowed)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        if (accounts.length != allowed.length) {
            revert InvalidArrayLength();
        }

        for (uint256 i = 0; i < accounts.length; i++) {
            _whitelist[accounts[i]] = allowed[i];
            emit WhitelistUpdated(bondToken, accounts[i], address(this), allowed[i], msg.sender);
        }
    }

    /// @inheritdoc IComplianceModule
    function setRole(address account, Role role) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _roles[account] = role;
        emit RoleUpdated(bondToken, account, address(this), role, msg.sender);
    }

    /// @inheritdoc IComplianceModule
    function batchSetRole(address[] calldata accounts, Role[] calldata roles)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        if (accounts.length != roles.length) {
            revert InvalidArrayLength();
        }

        for (uint256 i = 0; i < accounts.length; i++) {
            _roles[accounts[i]] = roles[i];
            emit RoleUpdated(bondToken, accounts[i], address(this), roles[i], msg.sender);
        }
    }

    /// @inheritdoc IComplianceModule
    function setPolicyMetadata(bytes32 policyId_, uint256 policyVersion_)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        _policyId = policyId_;
        _policyVersion = policyVersion_;
        emit PolicyMetadataUpdated(bondToken, address(this), policyId_, policyVersion_);
    }

    /// @inheritdoc IComplianceModule
    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IComplianceModule
    function isWhitelisted(address account) external view returns (bool) {
        return _whitelist[account];
    }

    /// @inheritdoc IComplianceModule
    function roleOf(address account) external view returns (Role) {
        return _roles[account];
    }

    /// @inheritdoc IComplianceModule
    function isDomainPaused(PauseDomain domain)
        public
        view
        override(DomainPausable, IComplianceModule)
        returns (bool)
    {
        return super.isDomainPaused(domain);
    }

    /// @inheritdoc IComplianceModule
    function checkTransfer(address from, address to, uint256) external view returns (uint8) {
        if (bondToken == address(0)) {
            return UNBOUND_BOND_CODE;
        }

        if (isDomainPaused(PauseDomain.SETTLEMENT)) {
            return TRANSFERS_PAUSED_CODE;
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

        bool validDirection =
            (fromRole == Role.MARKET_MAKER && toRole == Role.INVESTOR)
                || (fromRole == Role.INVESTOR && toRole == Role.MARKET_MAKER);

        if (!validDirection) {
            return INVALID_DIRECTION_CODE;
        }

        return SUCCESS_CODE;
    }

    /// @inheritdoc IComplianceModule
    function policyId() external view returns (bytes32) {
        return _policyId;
    }

    /// @inheritdoc IComplianceModule
    function policyVersion() external view returns (uint256) {
        return _policyVersion;
    }

    /// @dev Declares ERC165 support for the compliance module interface.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IComplianceModule).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Restricts UUPS upgrades to the configured upgrader role.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
