// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DomainPausable} from "./abstracts/DomainPausable.sol";
import {RoleManaged} from "./abstracts/RoleManaged.sol";
import {BondMath} from "./libraries/BondMath.sol";
import {
    ExpiredDeadline,
    InvalidBatchLength,
    InvalidBatchSize,
    InvalidFeeConfig,
    InvalidOrderNonce,
    InvalidOrderTaker,
    InvalidParticipantRole,
    InvalidSignature,
    OrderAlreadyCancelled,
    OrderAlreadyConsumed,
    UnauthorizedOrderMaker,
    NotWhitelisted,
    UnsupportedSettlementToken,
    ZeroAddress
} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {IRFQSettlement} from "./interfaces/IRFQSettlement.sol";
import {FeeConfig, Order, OrderSide, PauseDomain, Role} from "./types/BondTypes.sol";
import {SettlementOrderEIP712} from "./libraries/SettlementOrderEIP712.sol";

contract RFQSettlement is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    DomainPausable,
    RoleManaged,
    IRFQSettlement
{
    using SafeERC20 for IERC20;

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        address bondToken,
        address quoteToken,
        uint8 side,
        uint256 bondAmount,
        uint256 quoteAmount,
        uint256 feeAmount,
        address feeRecipient
    );
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker, address canceller);
    event NonceIncremented(address indexed maker, uint256 newMinimumValidNonce);
    event FeeConfigUpdated(
        address indexed feeRecipient,
        address indexed operator,
        uint16 currentFeeBps,
        uint16 maxFeeBps
    );
    event SettlementTokenPolicyUpdated(address indexed token, bool enabled, address operator);

    uint256 internal constant MAX_BATCH_SIZE = 24;

    uint256 private _reentrancyStatus;
    FeeConfig private _feeConfig;
    mapping(address token => bool enabled) private _settlementTokenPolicies;
    mapping(address maker => uint256 minimumValidNonce) private _nonceFloors;
    mapping(bytes32 orderHash => bool consumed) private _consumedOrders;
    mapping(bytes32 orderHash => bool cancelled) private _cancelledOrders;
    uint256[45] private __gap;

    constructor() {
        _disableInitializers();
    }

    /// @dev 初始化结算控制平面的管理员、暂停和升级角色。
    function initialize(address admin) external initializer {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLEMENT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        _reentrancyStatus = 1;
        _feeConfig = FeeConfig({feeRecipient: admin, currentFeeBps: 0, maxFeeBps: 1_000});
    }

    /// @inheritdoc IRFQSettlement
    function fillOrder(Order calldata order, bytes calldata signature) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);

        bytes32 orderHash = _validateOrder(order, signature, msg.sender);
        _executeOrder(order, orderHash, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function batchFillOrders(Order[] calldata orders, bytes[] calldata signatures) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);

        if (orders.length != signatures.length) {
            revert InvalidBatchLength(orders.length, signatures.length);
        }

        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }

        bytes32[] memory orderHashes = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            orderHashes[i] = _validateOrder(orders[i], signatures[i], msg.sender);
        }

        for (uint256 i = 0; i < orders.length; i++) {
            _executeOrder(orders[i], orderHashes[i], msg.sender);
        }
    }

    /// @inheritdoc IRFQSettlement
    function cancelOrder(Order calldata order) external {
        _cancelOrder(order, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function batchCancelOrders(Order[] calldata orders) external {
        for (uint256 i = 0; i < orders.length; i++) {
            _cancelOrder(orders[i], msg.sender);
        }
    }

    /// @inheritdoc IRFQSettlement
    function incrementNonce() external {
        _nonceFloors[msg.sender] += 1;
        emit NonceIncremented(msg.sender, _nonceFloors[msg.sender]);
    }

    /// @inheritdoc IRFQSettlement
    function setFeeConfig(FeeConfig calldata config) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (config.feeRecipient == address(0)) {
            revert ZeroAddress();
        }

        if (config.maxFeeBps > 10_000 || config.currentFeeBps > config.maxFeeBps) {
            revert InvalidFeeConfig(config.currentFeeBps, config.maxFeeBps);
        }

        _feeConfig = config;
        emit FeeConfigUpdated(config.feeRecipient, msg.sender, config.currentFeeBps, config.maxFeeBps);
    }

    /// @inheritdoc IRFQSettlement
    function setSettlementTokenPolicy(address token, bool enabled)
        external
        onlyRole(SETTLEMENT_ADMIN_ROLE)
    {
        if (token == address(0)) {
            revert ZeroAddress();
        }

        _settlementTokenPolicies[token] = enabled;
        emit SettlementTokenPolicyUpdated(token, enabled, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IRFQSettlement
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /// @inheritdoc IRFQSettlement
    function isOrderConsumed(bytes32 orderHash) external view returns (bool) {
        return _consumedOrders[orderHash];
    }

    /// @inheritdoc IRFQSettlement
    function currentNonce(address maker) external view returns (uint256) {
        return _nonceFloors[maker];
    }

    /// @inheritdoc IRFQSettlement
    function feeConfig() external view returns (FeeConfig memory) {
        return _feeConfig;
    }

    /// @inheritdoc IRFQSettlement
    function maxBatchSize() external pure returns (uint256) {
        return MAX_BATCH_SIZE;
    }

    /// @inheritdoc IRFQSettlement
    function isSettlementTokenEnabled(address token) public view returns (bool) {
        return _settlementTokenPolicies[token];
    }

    /// @inheritdoc IRFQSettlement
    function isDomainPaused(PauseDomain domain)
        public
        view
        override(DomainPausable, IRFQSettlement)
        returns (bool)
    {
        return super.isDomainPaused(domain);
    }

    /// @dev 供 fuzz / 单测复用的手续费报价辅助函数。
    function _quoteFeeAmount(uint256 quoteAmount) internal view returns (uint256) {
        return BondMath.mulBps(quoteAmount, _feeConfig.currentFeeBps);
    }

    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        Order memory localOrder = order;
        return SettlementOrderEIP712.hashTypedData(localOrder, address(this), block.chainid);
    }

    function _validateOrder(Order calldata order, bytes calldata signature, address taker)
        internal
        view
        returns (bytes32 orderHash)
    {
        if (!isSettlementTokenEnabled(order.quoteToken)) {
            revert UnsupportedSettlementToken(order.quoteToken);
        }

        if (order.expiry <= block.timestamp) {
            revert ExpiredDeadline(order.expiry, block.timestamp);
        }

        if (order.taker != address(0) && order.taker != taker) {
            revert InvalidOrderTaker(order.taker, taker);
        }

        orderHash = _hashOrder(order);

        if (_consumedOrders[orderHash]) {
            revert OrderAlreadyConsumed(orderHash);
        }

        if (_cancelledOrders[orderHash]) {
            revert OrderAlreadyCancelled(orderHash);
        }

        uint256 minimumValidNonce = _nonceFloors[order.maker];
        if (order.nonce < minimumValidNonce) {
            revert InvalidOrderNonce(order.maker, order.nonce, minimumValidNonce);
        }

        address signer = ECDSA.recover(orderHash, signature);
        if (signer != order.maker) {
            revert InvalidSignature(order.maker, signer);
        }

        _requireParticipantRoles(order, taker);
    }

    function _requireParticipantRoles(Order calldata order, address taker) internal view {
        IComplianceModule complianceModule = IComplianceModule(IBondToken(order.bondToken).complianceModule());

        if (!complianceModule.isWhitelisted(order.maker)) {
            revert NotWhitelisted(order.maker);
        }

        Role makerRole = complianceModule.roleOf(order.maker);
        if (makerRole != Role.MARKET_MAKER) {
            revert InvalidParticipantRole(order.maker, Role.MARKET_MAKER, makerRole);
        }

        if (!complianceModule.isWhitelisted(taker)) {
            revert NotWhitelisted(taker);
        }

        Role takerRole = complianceModule.roleOf(taker);
        if (takerRole != Role.INVESTOR) {
            revert InvalidParticipantRole(taker, Role.INVESTOR, takerRole);
        }
    }

    function _executeOrder(Order calldata order, bytes32 orderHash, address taker) internal {
        _consumedOrders[orderHash] = true;

        uint256 feeAmount = _quoteFeeAmount(order.quoteAmount);
        (address quotePayer, address quoteReceiver, address bondPayer, address bondReceiver) =
            _resolveSettlementParties(order, taker);

        IERC20(order.quoteToken).safeTransferFrom(quotePayer, quoteReceiver, order.quoteAmount - feeAmount);
        if (feeAmount != 0) {
            IERC20(order.quoteToken).safeTransferFrom(quotePayer, _feeConfig.feeRecipient, feeAmount);
        }

        IERC20(order.bondToken).safeTransferFrom(bondPayer, bondReceiver, order.bondAmount);

        emit OrderFilled(
            orderHash,
            order.maker,
            taker,
            order.bondToken,
            order.quoteToken,
            uint8(order.side),
            order.bondAmount,
            order.quoteAmount,
            feeAmount,
            _feeConfig.feeRecipient
        );
    }

    function _resolveSettlementParties(Order calldata order, address taker)
        internal
        pure
        returns (address quotePayer, address quoteReceiver, address bondPayer, address bondReceiver)
    {
        if (order.side == OrderSide.BUY) {
            return (taker, order.maker, order.maker, taker);
        }

        return (order.maker, taker, taker, order.maker);
    }

    function _cancelOrder(Order calldata order, address caller) internal {
        if (caller != order.maker) {
            revert UnauthorizedOrderMaker(caller, order.maker);
        }

        bytes32 orderHash = _hashOrder(order);
        if (_consumedOrders[orderHash]) {
            revert OrderAlreadyConsumed(orderHash);
        }

        if (_cancelledOrders[orderHash]) {
            revert OrderAlreadyCancelled(orderHash);
        }

        _cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, order.maker, caller);
    }

    /// @dev 仅允许升级角色执行 UUPS 升级。
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "REENTRANT_CALL");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }
}
