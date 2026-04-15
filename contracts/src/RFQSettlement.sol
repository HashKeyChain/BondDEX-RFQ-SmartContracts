// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { DomainPausable } from "./abstracts/DomainPausable.sol";
import { RoleManaged } from "./abstracts/RoleManaged.sol";
import { BondMath } from "./libraries/BondMath.sol";
import {
    AccruedInterestMismatch,
    BondAlreadyMatured,
    ExpiredDeadline,
    FeeCapImmutable,
    FeeExceedsOrderLimit,
    InvalidAiTolerance,
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
    UnregisteredBondToken,
    UnsupportedSettlementToken,
    ZeroAddress,
    ZeroAmount
} from "./libraries/BondErrors.sol";
import { IComplianceModule } from "./interfaces/IComplianceModule.sol";
import { IBondToken } from "./interfaces/IBondToken.sol";
import { IRFQSettlement } from "./interfaces/IRFQSettlement.sol";
import { FeeConfig, Order, OrderSide, PauseDomain, Role } from "./types/BondTypes.sol";
import { SettlementOrderEIP712 } from "./libraries/SettlementOrderEIP712.sol";

/// @title RFQSettlement
/// @notice Secondary-market settlement engine for signed RFQ bond orders with accrued interest.
contract RFQSettlement is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
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
        uint256 accruedInterest,
        uint256 feeAmount,
        address feeRecipient
    );
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker, address canceller);
    event NonceIncremented(address indexed maker, uint256 newMinimumValidNonce);
    event FeeConfigUpdated(
        address indexed feeRecipient, address indexed operator, uint16 currentFeeBps, uint16 maxFeeBps
    );
    event SettlementTokenPolicyUpdated(address indexed token, bool enabled, address operator);
    event BondTokenRegistrationUpdated(address indexed bondToken, bool registered, address operator);
    event AiToleranceUpdated(uint256 newToleranceSeconds, address operator);
    event TokensRescued(address indexed token, address indexed to, uint256 amount, address indexed operator);

    uint256 internal constant MAX_BATCH_SIZE = 24;
    uint256 internal constant DEFAULT_AI_TOLERANCE_SECONDS = 300;
    uint256 internal constant MIN_AI_TOLERANCE_SECONDS = 10;
    uint256 internal constant MAX_AI_TOLERANCE_SECONDS = 30 days;

    FeeConfig private _feeConfig;
    mapping(address token => bool enabled) private _settlementTokenPolicies;
    mapping(address maker => uint256 minimumValidNonce) private _nonceFloors;
    mapping(bytes32 orderHash => bool consumed) private _consumedOrders;
    mapping(bytes32 orderHash => bool cancelled) private _cancelledOrders;
    /// @dev Prevents fake-token attacks by restricting which bond tokens can be used.
    mapping(address bondToken => bool registered) private _registeredBondTokens;
    uint256 private _aiToleranceSeconds;
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    uint256[41] private __gap;

    constructor() {
        _disableInitializers();
    }

    /// @param admin Default administrator address.
    /// @param maxFeeBps_ Fee cap in basis points, immutable after initialization.
    function initialize(address admin, uint16 maxFeeBps_) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (maxFeeBps_ > 10_000) revert InvalidFeeConfig(0, maxFeeBps_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLEMENT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _feeConfig = FeeConfig({ feeRecipient: admin, currentFeeBps: 0, maxFeeBps: maxFeeBps_ });
        _aiToleranceSeconds = DEFAULT_AI_TOLERANCE_SECONDS;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = SettlementOrderEIP712.domainSeparator(address(this), block.chainid);
    }

    /// @inheritdoc IRFQSettlement
    function fillOrder(Order calldata order, bytes calldata signature) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);
        (bytes32 orderHash, bool isFeeExempt) = _validateOrder(order, signature, msg.sender);
        _executeOrder(order, orderHash, msg.sender, isFeeExempt);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Validates all orders first so the batch settles atomically or reverts as a whole.
    function batchFillOrders(Order[] calldata orders, bytes[] calldata signatures) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);
        if (orders.length != signatures.length) revert InvalidBatchLength(orders.length, signatures.length);
        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }

        uint256 len = orders.length;
        bytes32[] memory orderHashes = new bytes32[](len);
        bool[] memory feeExemptions = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            (orderHashes[i], feeExemptions[i]) = _validateOrder(orders[i], signatures[i], msg.sender);
        }
        for (uint256 i = 0; i < len; i++) {
            _executeOrder(orders[i], orderHashes[i], msg.sender, feeExemptions[i]);
        }
    }

    /// @inheritdoc IRFQSettlement
    function cancelOrder(Order calldata order) external {
        _cancelOrder(order, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function batchCancelOrders(Order[] calldata orders) external {
        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }
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
    function setMinimumNonce(uint256 newMinNonce) external {
        uint256 current = _nonceFloors[msg.sender];
        if (newMinNonce <= current) revert InvalidOrderNonce(msg.sender, newMinNonce, current + 1);
        _nonceFloors[msg.sender] = newMinNonce;
        emit NonceIncremented(msg.sender, newMinNonce);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev maxFeeBps is immutable after initialization.
    function setFeeConfig(FeeConfig calldata config) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (config.feeRecipient == address(0)) revert ZeroAddress();
        if (config.maxFeeBps != _feeConfig.maxFeeBps) revert FeeCapImmutable();
        if (config.currentFeeBps > config.maxFeeBps) revert InvalidFeeConfig(config.currentFeeBps, config.maxFeeBps);
        _feeConfig = config;
        emit FeeConfigUpdated(config.feeRecipient, msg.sender, config.currentFeeBps, config.maxFeeBps);
    }

    /// @inheritdoc IRFQSettlement
    function setSettlementTokenPolicy(address token, bool enabled) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        _settlementTokenPolicies[token] = enabled;
        emit SettlementTokenPolicyUpdated(token, enabled, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function setBondTokenRegistration(address bondToken, bool registered) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (bondToken == address(0)) revert ZeroAddress();
        _registeredBondTokens[bondToken] = registered;
        emit BondTokenRegistrationUpdated(bondToken, registered, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function setAiToleranceSeconds(uint256 toleranceSeconds) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (toleranceSeconds < MIN_AI_TOLERANCE_SECONDS || toleranceSeconds > MAX_AI_TOLERANCE_SECONDS) {
            revert InvalidAiTolerance(toleranceSeconds, MIN_AI_TOLERANCE_SECONDS, MAX_AI_TOLERANCE_SECONDS);
        }
        _aiToleranceSeconds = toleranceSeconds;
        emit AiToleranceUpdated(toleranceSeconds, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function isBondTokenRegistered(address bondToken) public view returns (bool) {
        return _registeredBondTokens[bondToken];
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
    function isOrderCancelled(bytes32 orderHash) external view returns (bool) {
        return _cancelledOrders[orderHash];
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
    function aiToleranceSeconds() external view returns (uint256) {
        return _aiToleranceSeconds;
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns 0 when both parties are market makers (fee-exempt).
    function quoteFee(address bondToken, address partyA, address partyB, uint256 dirtyAmount)
        external
        view
        returns (uint256 feeAmount)
    {
        if (!isBondTokenRegistered(bondToken)) revert UnregisteredBondToken(bondToken);
        IComplianceModule complianceModule = IComplianceModule(IBondToken(bondToken).complianceModule());
        Role roleA = complianceModule.roleOf(partyA);
        Role roleB = complianceModule.roleOf(partyB);
        if (roleA == Role.MARKET_MAKER && roleB == Role.MARKET_MAKER) return 0;
        return _quoteFeeAmount(dirtyAmount);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev RFQSettlement never holds funds, so full balance is always rescuable.
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f",
            SettlementOrderEIP712.NAME,
            SettlementOrderEIP712.VERSION,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /// @inheritdoc IRFQSettlement
    function isDomainPaused(PauseDomain domain) public view override(DomainPausable, IRFQSettlement) returns (bool) {
        return super.isDomainPaused(domain);
    }

    function _quoteFeeAmount(uint256 dirtyAmount) internal view returns (uint256) {
        return BondMath.mulBps(dirtyAmount, _feeConfig.currentFeeBps);
    }

    /// @dev Uses cached domain separator; recomputes on chain fork.
    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        bytes32 separator = block.chainid == _cachedChainId
            ? _cachedDomainSeparator
            : SettlementOrderEIP712.domainSeparator(address(this), block.chainid);
        Order memory localOrder = order;
        return MessageHashUtils.toTypedDataHash(separator, SettlementOrderEIP712.hashOrder(localOrder));
    }

    /// @return orderHash EIP-712 typed-data digest.
    /// @return isFeeExempt True when both maker and taker are market makers.
    function _validateOrder(Order calldata order, bytes calldata signature, address taker)
        internal
        view
        returns (bytes32 orderHash, bool isFeeExempt)
    {
        if (order.bondAmount == 0 || order.quoteAmount == 0) revert ZeroAmount();
        if (!isBondTokenRegistered(order.bondToken)) revert UnregisteredBondToken(order.bondToken);
        {
            uint256 maturity = IBondToken(order.bondToken).maturityTimestamp();
            if (block.timestamp >= maturity) revert BondAlreadyMatured(order.bondToken, maturity, block.timestamp);
        }
        if (!isSettlementTokenEnabled(order.quoteToken)) revert UnsupportedSettlementToken(order.quoteToken);
        if (order.expiry <= block.timestamp) revert ExpiredDeadline(order.expiry, block.timestamp);
        if (order.taker != address(0) && order.taker != taker) revert InvalidOrderTaker(order.taker, taker);

        orderHash = _hashOrder(order);
        if (_consumedOrders[orderHash]) revert OrderAlreadyConsumed(orderHash);
        if (_cancelledOrders[orderHash]) revert OrderAlreadyCancelled(orderHash);

        uint256 minimumValidNonce = _nonceFloors[order.maker];
        if (order.nonce < minimumValidNonce) revert InvalidOrderNonce(order.maker, order.nonce, minimumValidNonce);

        address signer = ECDSA.recover(orderHash, signature);
        if (signer != order.maker) revert InvalidSignature(order.maker, signer);

        (Role makerRole, Role takerRole) = _requireParticipantRoles(order, taker);
        isFeeExempt = makerRole == Role.MARKET_MAKER && takerRole == Role.MARKET_MAKER;
        _validateAccruedInterest(order);
    }

    /// @dev When tolerance rounds to zero (small faceValue), a floor of 1 unit is applied.
    function _validateAccruedInterest(Order calldata order) internal view {
        IBondToken bt = IBondToken(order.bondToken);
        uint8 bondDecimals = IERC20Metadata(order.bondToken).decimals();
        uint256 aiPerUnit = bt.accruedInterestPerUnit(block.timestamp);
        uint256 expectedAI = Math.mulDiv(aiPerUnit, order.bondAmount, 10 ** uint256(bondDecimals));

        uint256 tolerance;
        if (_aiToleranceSeconds > 0) {
            uint256 expectedAILater = Math.mulDiv(
                bt.accruedInterestPerUnit(block.timestamp + _aiToleranceSeconds),
                order.bondAmount,
                10 ** uint256(bondDecimals)
            );
            tolerance = expectedAILater > expectedAI ? expectedAILater - expectedAI : 0;
        }
        if (tolerance == 0 && expectedAI > 0) tolerance = 1;

        if (
            order.accruedInterest > expectedAI + tolerance
                || (expectedAI > tolerance && order.accruedInterest < expectedAI - tolerance)
        ) {
            revert AccruedInterestMismatch(order.accruedInterest, expectedAI, tolerance);
        }
    }

    function _requireParticipantRoles(Order calldata order, address taker)
        internal
        view
        returns (Role makerRole, Role takerRole)
    {
        IComplianceModule complianceModule = IComplianceModule(IBondToken(order.bondToken).complianceModule());
        if (!complianceModule.isWhitelisted(order.maker)) revert NotWhitelisted(order.maker);
        if (!complianceModule.isWhitelisted(taker)) revert NotWhitelisted(taker);
        makerRole = complianceModule.roleOf(order.maker);
        takerRole = complianceModule.roleOf(taker);
        if (makerRole != Role.MARKET_MAKER) revert InvalidParticipantRole(order.maker, Role.MARKET_MAKER, makerRole);
        if (takerRole != Role.MARKET_MAKER && takerRole != Role.INVESTOR) {
            revert InvalidParticipantRole(taker, Role.INVESTOR, takerRole);
        }
    }

    /// @dev Fee is always charged to the market-maker side:
    ///   BUY → MM receives dirtyAmount - fee; SELL → MM pays dirtyAmount + fee; MM-to-MM → exempt
    function _executeOrder(Order calldata order, bytes32 orderHash, address taker, bool isFeeExempt) internal {
        if (_consumedOrders[orderHash]) revert OrderAlreadyConsumed(orderHash);
        _consumedOrders[orderHash] = true;

        uint256 dirtyAmount = order.quoteAmount + order.accruedInterest;
        uint256 feeAmount = isFeeExempt ? 0 : _quoteFeeAmount(dirtyAmount);
        if (feeAmount > 0 && _feeConfig.currentFeeBps > order.maxFeeBps) {
            revert FeeExceedsOrderLimit(order.maxFeeBps, _feeConfig.currentFeeBps);
        }
        _transferSettlement(order, taker, dirtyAmount, feeAmount);
        emit OrderFilled(
            orderHash,
            order.maker,
            taker,
            order.bondToken,
            order.quoteToken,
            uint8(order.side),
            order.bondAmount,
            order.quoteAmount,
            order.accruedInterest,
            feeAmount,
            _feeConfig.feeRecipient
        );
    }

    function _resolveSettlementParties(Order calldata order, address taker)
        internal
        pure
        returns (address quotePayer, address quoteReceiver, address bondPayer, address bondReceiver)
    {
        if (order.side == OrderSide.BUY) return (taker, order.maker, order.maker, taker);
        return (order.maker, taker, taker, order.maker);
    }

    function _transferSettlement(Order calldata order, address taker, uint256 dirtyAmount, uint256 feeAmount) private {
        (address quotePayer, address quoteReceiver, address bondPayer, address bondReceiver) =
            _resolveSettlementParties(order, taker);
        // BUY: fee deducted from MM receipts; SELL: MM pays extra fee on top
        bool deductFeeFromReceipt = feeAmount > 0 && order.side == OrderSide.BUY;
        IERC20(order.quoteToken)
            .safeTransferFrom(quotePayer, quoteReceiver, deductFeeFromReceipt ? dirtyAmount - feeAmount : dirtyAmount);
        if (feeAmount > 0) IERC20(order.quoteToken).safeTransferFrom(quotePayer, _feeConfig.feeRecipient, feeAmount);
        IERC20(order.bondToken).safeTransferFrom(bondPayer, bondReceiver, order.bondAmount);
    }

    function _cancelOrder(Order calldata order, address caller) internal {
        if (caller != order.maker) revert UnauthorizedOrderMaker(caller, order.maker);
        bytes32 orderHash = _hashOrder(order);
        if (_consumedOrders[orderHash]) revert OrderAlreadyConsumed(orderHash);
        if (_cancelledOrders[orderHash]) revert OrderAlreadyCancelled(orderHash);
        _cancelledOrders[orderHash] = true;
        emit OrderCancelled(orderHash, order.maker, caller);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
