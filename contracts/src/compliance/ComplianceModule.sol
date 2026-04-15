// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { DomainPausable } from "../abstracts/DomainPausable.sol";
import { RoleManaged } from "../abstracts/RoleManaged.sol";
import {
    BondTokenAlreadyBound, InvalidArrayLength, InvalidBatchSize, InvalidParticipantRole, ZeroAddress
} from "../libraries/BondErrors.sol";
import { IComplianceModule } from "../interfaces/IComplianceModule.sol";
import { PauseDomain, Role } from "../types/BondTypes.sol";

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
    uint8 public constant UNAUTHORIZED_OPERATOR_CODE = 8;
    uint256 internal constant MAX_BATCH_SIZE = 200;

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
    event BondTokenBound(address indexed bondToken, address indexed complianceModule);
    event PolicyMetadataUpdated(
        address indexed bondToken, address indexed complianceModule, bytes32 policyId, uint256 policyVersion
    );
    event TransferOperatorUpdated(address indexed bondToken, address indexed operator, bool authorized, address admin);

    address public bondToken;
    bytes32 private _policyId;
    uint256 private _policyVersion;
    mapping(address account => bool allowed) private _whitelist;
    mapping(address account => Role role) private _roles;
    mapping(address operator => bool authorized) private _authorizedOperators;
    uint256[44] private __gap;

    constructor() { _disableInitializers(); }

    function initialize(address admin, address factory, bytes32 policyId_, uint256 policyVersion_)
        external
        initializer
    {
        if (admin == address(0) || factory == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(BOND_FACTORY_ROLE, factory);
        _policyId = policyId_;
        _policyVersion = policyVersion_;
    }

    function bindBondToken(address bondToken_) external onlyRole(BOND_FACTORY_ROLE) {
        if (bondToken_ == address(0)) revert ZeroAddress();
        if (bondToken != address(0)) revert BondTokenAlreadyBound(bondToken);
        bondToken = bondToken_;
        emit BondTokenBound(bondToken_, address(this));
    }

    function setWhitelist(address account, bool allowed) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (account == address(0)) revert ZeroAddress();
        _whitelist[account] = allowed;
        emit WhitelistUpdated(bondToken, account, address(this), allowed, msg.sender);
    }

    function batchSetWhitelist(address[] calldata accounts, bool[] calldata allowed)
        external
        onlyRole(COMPLIANCE_ADMIN_ROLE)
    {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (accounts.length != allowed.length) revert InvalidArrayLength();
        if (accounts.length == 0 || accounts.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(accounts.length, MAX_BATCH_SIZE);
        }
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            _whitelist[accounts[i]] = allowed[i];
            emit WhitelistUpdated(bondToken, accounts[i], address(this), allowed[i], msg.sender);
        }
    }

    function setRole(address account, Role role) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (uint8(role) > uint8(Role.INVESTOR)) revert InvalidParticipantRole(account, Role.INVESTOR, role);
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        _roles[account] = role;
        emit RoleUpdated(bondToken, account, address(this), role, msg.sender);
    }

    function batchSetRole(address[] calldata accounts, Role[] calldata roles) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        if (accounts.length != roles.length) revert InvalidArrayLength();
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

    function setPolicyMetadata(bytes32 policyId_, uint256 policyVersion_) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        _requireDomainActive(PauseDomain.COMPLIANCE_ADMIN);
        _policyId = policyId_;
        _policyVersion = policyVersion_;
        emit PolicyMetadataUpdated(bondToken, address(this), policyId_, policyVersion_);
    }

    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    function setTransferOperator(address operator, bool authorized) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        _authorizedOperators[operator] = authorized;
        emit TransferOperatorUpdated(bondToken, operator, authorized, msg.sender);
    }

    function isTransferOperator(address operator) external view returns (bool) {
        return _authorizedOperators[operator];
    }

    function isWhitelisted(address account) external view returns (bool) { return _whitelist[account]; }

    function roleOf(address account) external view returns (Role) { return _roles[account]; }

    function isDomainPaused(PauseDomain domain) public view override(DomainPausable, IComplianceModule) returns (bool) {
        return super.isDomainPaused(domain);
    }

    function checkTransfer(address from, address to, uint256, address operator) external view returns (uint8) {
        if (bondToken == address(0)) return UNBOUND_BOND_CODE;
        if (isDomainPaused(PauseDomain.SETTLEMENT)) return TRANSFERS_PAUSED_CODE;
        if (!_authorizedOperators[operator]) return UNAUTHORIZED_OPERATOR_CODE;
        if (!_whitelist[from]) return SENDER_NOT_WHITELISTED_CODE;
        if (!_whitelist[to]) return RECEIVER_NOT_WHITELISTED_CODE;
        Role fromRole = _roles[from];
        Role toRole = _roles[to];
        if (fromRole != Role.MARKET_MAKER && fromRole != Role.INVESTOR) return INVALID_SENDER_ROLE_CODE;
        if (toRole != Role.MARKET_MAKER && toRole != Role.INVESTOR) return INVALID_RECEIVER_ROLE_CODE;
        if (fromRole == Role.INVESTOR && toRole == Role.INVESTOR) return INVALID_DIRECTION_CODE;
        return SUCCESS_CODE;
    }

    function policyId() external view returns (bytes32) { return _policyId; }

    function policyVersion() external view returns (uint256) { return _policyVersion; }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IComplianceModule).interfaceId || super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
