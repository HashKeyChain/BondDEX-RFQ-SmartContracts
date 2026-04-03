// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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
import {
    FeeConfig,
    Order,
    OrderSide,
    PauseDomain,
    Role
} from "./types/BondTypes.sol";
import {SettlementOrderEIP712} from "./libraries/SettlementOrderEIP712.sol";

/// @title RFQSettlement
/// @notice Secondary-market settlement engine for signed RFQ bond orders.
/// @dev Makers sign EIP-712 orders off-chain and investors execute them on-chain. The contract
/// validates signatures, nonce floors, allowlisted settlement tokens, compliance roles, and fee policy.
contract RFQSettlement is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    DomainPausable,
    RoleManaged,
    IRFQSettlement
{
    using SafeERC20 for IERC20;

    /// @notice Emitted when one RFQ order is executed successfully.
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

    /// @notice Emitted when a maker cancels one order payload.
    event OrderCancelled(
        bytes32 indexed orderHash,
        address indexed maker,
        address canceller
    );

    /// @notice Emitted when a maker invalidates all older orders by raising the nonce floor.
    event NonceIncremented(address indexed maker, uint256 newMinimumValidNonce);

    /// @notice Emitted when governance updates fee recipient or fee bounds.
    event FeeConfigUpdated(
        address indexed feeRecipient,
        address indexed operator,
        uint16 currentFeeBps,
        uint16 maxFeeBps
    );

    /// @notice Emitted when governance enables or disables a quote token for RFQ settlement.
    event SettlementTokenPolicyUpdated(
        address indexed token,
        bool enabled,
        address operator
    );

    /// @notice Hard cap on the number of orders that may be settled atomically in one batch.
    uint256 internal constant MAX_BATCH_SIZE = 24;

    /// @dev Reentrancy status flag where 1 means unlocked and 2 means entered.
    uint256 private _reentrancyStatus;

    /// @dev Active fee configuration applied to every executed order.
    FeeConfig private _feeConfig;

    /// @dev Allowlist of quote tokens that may be used in RFQ settlement.
    mapping(address token => bool enabled) private _settlementTokenPolicies;

    /// @dev Minimum valid nonce keyed by maker address.
    mapping(address maker => uint256 minimumValidNonce) private _nonceFloors;

    /// @dev Tracks whether an order hash has already been executed.
    mapping(bytes32 orderHash => bool consumed) private _consumedOrders;

    /// @dev Tracks whether an order hash has already been cancelled.
    mapping(bytes32 orderHash => bool cancelled) private _cancelledOrders;

    /// @dev Reserved storage gap for future proxy-safe upgrades.
    uint256[45] private __gap;

    /// @dev Locks the implementation contract so only proxies may initialize it.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes admin, pauser, and upgrader roles together with the default fee policy.
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
        _feeConfig = FeeConfig({
            feeRecipient: admin,
            currentFeeBps: 0,
            maxFeeBps: 1_000
        });
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Validates one signed order and executes the corresponding asset transfers.
    function fillOrder(
        Order calldata order,
        bytes calldata signature
    ) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);

        bytes32 orderHash = _validateOrder(order, signature, msg.sender);
        _executeOrder(order, orderHash, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Validates all orders first so the batch settles atomically or reverts as a whole.
    function batchFillOrders(
        Order[] calldata orders,
        bytes[] calldata signatures
    ) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);

        if (orders.length != signatures.length) {
            revert InvalidBatchLength(orders.length, signatures.length);
        }

        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }

        bytes32[] memory orderHashes = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            orderHashes[i] = _validateOrder(
                orders[i],
                signatures[i],
                msg.sender
            );
        }

        for (uint256 i = 0; i < orders.length; i++) {
            _executeOrder(orders[i], orderHashes[i], msg.sender);
        }
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Cancels one order so it can no longer be executed.
    function cancelOrder(Order calldata order) external {
        _cancelOrder(order, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Cancels multiple orders for the caller.
    function batchCancelOrders(Order[] calldata orders) external {
        for (uint256 i = 0; i < orders.length; i++) {
            _cancelOrder(orders[i], msg.sender);
        }
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Raises the maker nonce floor and invalidates all older signed orders.
    function incrementNonce() external {
        _nonceFloors[msg.sender] += 1;
        emit NonceIncremented(msg.sender, _nonceFloors[msg.sender]);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Updates fee recipient and fee bounds enforced during settlement.
    function setFeeConfig(
        FeeConfig calldata config
    ) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (config.feeRecipient == address(0)) {
            revert ZeroAddress();
        }

        if (
            config.maxFeeBps > 10_000 || config.currentFeeBps > config.maxFeeBps
        ) {
            revert InvalidFeeConfig(config.currentFeeBps, config.maxFeeBps);
        }

        _feeConfig = config;
        emit FeeConfigUpdated(
            config.feeRecipient,
            msg.sender,
            config.currentFeeBps,
            config.maxFeeBps
        );
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Enables or disables one quote token for RFQ settlement.
    function setSettlementTokenPolicy(
        address token,
        bool enabled
    ) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (token == address(0)) {
            revert ZeroAddress();
        }

        _settlementTokenPolicies[token] = enabled;
        emit SettlementTokenPolicyUpdated(token, enabled, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Toggles one settlement-controlled pause domain.
    function pauseDomain(
        PauseDomain domain,
        bool paused
    ) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Exposes the EIP-712 digest that makers sign off-chain.
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns whether the given order hash has already been consumed.
    function isOrderConsumed(bytes32 orderHash) external view returns (bool) {
        return _consumedOrders[orderHash];
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns the current minimum valid nonce for the maker.
    function currentNonce(address maker) external view returns (uint256) {
        return _nonceFloors[maker];
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns the currently active fee configuration.
    function feeConfig() external view returns (FeeConfig memory) {
        return _feeConfig;
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns the maximum number of orders allowed in one batch execution.
    function maxBatchSize() external pure returns (uint256) {
        return MAX_BATCH_SIZE;
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns whether the given quote token is enabled for settlement.
    function isSettlementTokenEnabled(
        address token
    ) public view returns (bool) {
        return _settlementTokenPolicies[token];
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Exposes inherited pause state for interface compliance and monitoring.
    function isDomainPaused(
        PauseDomain domain
    ) public view override(DomainPausable, IRFQSettlement) returns (bool) {
        return super.isDomainPaused(domain);
    }

    /// @dev Quotes protocol fee for one order quote amount using the current fee configuration.
    function _quoteFeeAmount(
        uint256 quoteAmount
    ) internal view returns (uint256) {
        return BondMath.mulBps(quoteAmount, _feeConfig.currentFeeBps);
    }

    /// @dev Computes the EIP-712 typed-data digest for one order.
    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        Order memory localOrder = order;
        return
            SettlementOrderEIP712.hashTypedData(
                localOrder,
                address(this),
                block.chainid
            );
    }

    /// @dev Validates token policy, expiry, taker binding, nonce floor, signature, and participant roles.
    function _validateOrder(
        Order calldata order,
        bytes calldata signature,
        address taker
    ) internal view returns (bytes32 orderHash) {
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
            revert InvalidOrderNonce(
                order.maker,
                order.nonce,
                minimumValidNonce
            );
        }

        address signer = ECDSA.recover(orderHash, signature);
        if (signer != order.maker) {
            revert InvalidSignature(order.maker, signer);
        }

        _requireParticipantRoles(order, taker);
    }

    /// @dev Requires the maker to be a whitelisted market maker and the taker to be a whitelisted investor.
    function _requireParticipantRoles(
        Order calldata order,
        address taker
    ) internal view {
        IComplianceModule complianceModule = IComplianceModule(
            IBondToken(order.bondToken).complianceModule()
        );

        if (!complianceModule.isWhitelisted(order.maker)) {
            revert NotWhitelisted(order.maker);
        }

        Role makerRole = complianceModule.roleOf(order.maker);
        if (makerRole != Role.MARKET_MAKER) {
            revert InvalidParticipantRole(
                order.maker,
                Role.MARKET_MAKER,
                makerRole
            );
        }

        if (!complianceModule.isWhitelisted(taker)) {
            revert NotWhitelisted(taker);
        }

        Role takerRole = complianceModule.roleOf(taker);
        if (takerRole != Role.INVESTOR) {
            revert InvalidParticipantRole(taker, Role.INVESTOR, takerRole);
        }
    }

    /// @dev Executes token transfers for one validated order and emits the canonical fill event.
    function _executeOrder(
        Order calldata order,
        bytes32 orderHash,
        address taker
    ) internal {
        _consumedOrders[orderHash] = true;

        uint256 feeAmount = _quoteFeeAmount(order.quoteAmount);
        (
            address quotePayer,
            address quoteReceiver,
            address bondPayer,
            address bondReceiver
        ) = _resolveSettlementParties(order, taker);

        // Quote tokens settle net of fees to the economic receiver.
        IERC20(order.quoteToken).safeTransferFrom(
            quotePayer,
            quoteReceiver,
            order.quoteAmount - feeAmount
        );
        if (feeAmount != 0) {
            IERC20(order.quoteToken).safeTransferFrom(
                quotePayer,
                _feeConfig.feeRecipient,
                feeAmount
            );
        }

        // Bond units move in the opposite direction of quote tokens.
        IERC20(order.bondToken).safeTransferFrom(
            bondPayer,
            bondReceiver,
            order.bondAmount
        );

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

    /// @dev Resolves token payers and receivers based on whether the maker is buying or selling bonds.
    function _resolveSettlementParties(
        Order calldata order,
        address taker
    )
        internal
        pure
        returns (
            address quotePayer,
            address quoteReceiver,
            address bondPayer,
            address bondReceiver
        )
    {
        if (order.side == OrderSide.BUY) {
            return (taker, order.maker, order.maker, taker);
        }

        return (order.maker, taker, taker, order.maker);
    }

    /// @dev Cancels one order after verifying that the caller is the maker and the order is still live.
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

    /// @dev Restricts UUPS upgrades to the configured upgrader role.
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /// @dev Minimal reentrancy guard for settlement entrypoints with token transfers.
    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "REENTRANT_CALL");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }
}
