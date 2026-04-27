// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    InvalidBasisPoints,
    InvalidBatchLength,
    InvalidBatchSize,
    InvalidFeeConfig,
    InvalidOrderNonce,
    InvalidOrderTaker,
    InvalidParticipantRole,
    InvalidSignature,
    OrderAlreadyCancelled,
    OrderAlreadyConsumed,
    QuoteTokenMismatch,
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
    /// @dev AUDIT-FIX(N15): emitted whenever an admin refreshes the cached EIP-712 domain separator.
    event DomainSeparatorRefreshed(uint256 chainId, bytes32 domainSeparator, address indexed operator);

    uint256 internal constant MAX_BATCH_SIZE = 24;
    uint256 internal constant DEFAULT_AI_TOLERANCE_SECONDS = 300;
    uint256 internal constant MIN_AI_TOLERANCE_SECONDS = 10;
    uint256 internal constant MAX_AI_TOLERANCE_SECONDS = 30 days;

    FeeConfig private _feeConfig;
    mapping(address token => bool enabled) private _settlementTokenPolicies;
    mapping(address maker => uint256 minimumValidNonce) private _nonceFloors;
    mapping(bytes32 orderHash => bool consumed) private _consumedOrders;
    mapping(bytes32 orderHash => bool cancelled) private _cancelledOrders;
    mapping(address bondToken => bool registered) private _registeredBondTokens;
    uint256 private _aiToleranceSeconds;
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    uint256[41] private __gap;

    constructor() { _disableInitializers(); }

    /// @dev AUDIT-FIX(N11) revisited: principle of least privilege at initialization. Only
    ///      DEFAULT_ADMIN_ROLE is granted to the initial admin; secondary governance roles
    ///      (SETTLEMENT_ADMIN_ROLE / PAUSER_ROLE / UPGRADER_ROLE) must be granted explicitly via
    ///      standard AccessControl. The initial admin can immediately self-grant any role they
    ///      need because DEFAULT_ADMIN_ROLE is the OZ default `getRoleAdmin` for every role.
    function initialize(address admin, uint16 maxFeeBps_) external initializer {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(admin);
        // AUDIT-FIX(N16): out-of-range maxFeeBps must raise InvalidBasisPoints, not InvalidFeeConfig.
        if (maxFeeBps_ > 10_000) revert InvalidBasisPoints(maxFeeBps_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _feeConfig = FeeConfig({ feeRecipient: admin, currentFeeBps: 0, maxFeeBps: maxFeeBps_ });
        _aiToleranceSeconds = DEFAULT_AI_TOLERANCE_SECONDS;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = SettlementOrderEIP712.domainSeparator(address(this), block.chainid);
    }

    function fillOrder(Order calldata order, bytes calldata signature) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);
        (bytes32 orderHash, bool isFeeExempt) = _validateOrder(order, signature, msg.sender);
        _executeOrder(order, orderHash, msg.sender, isFeeExempt);
    }

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

    function cancelOrder(Order calldata order) external { _cancelOrder(order, msg.sender); }

    function batchCancelOrders(Order[] calldata orders) external {
        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }
        for (uint256 i = 0; i < orders.length; i++) { _cancelOrder(orders[i], msg.sender); }
    }

    function incrementNonce() external {
        _nonceFloors[msg.sender] += 1;
        emit NonceIncremented(msg.sender, _nonceFloors[msg.sender]);
    }

    function setMinimumNonce(uint256 newMinNonce) external {
        uint256 current = _nonceFloors[msg.sender];
        if (newMinNonce <= current) revert InvalidOrderNonce(msg.sender, newMinNonce, current + 1);
        _nonceFloors[msg.sender] = newMinNonce;
        emit NonceIncremented(msg.sender, newMinNonce);
    }

    function setFeeConfig(FeeConfig calldata config) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(config.feeRecipient);
        if (config.maxFeeBps != _feeConfig.maxFeeBps) revert FeeCapImmutable();
        if (config.currentFeeBps > config.maxFeeBps) revert InvalidFeeConfig(config.currentFeeBps, config.maxFeeBps);
        _feeConfig = config;
        emit FeeConfigUpdated(config.feeRecipient, msg.sender, config.currentFeeBps, config.maxFeeBps);
    }

    function setSettlementTokenPolicy(address token, bool enabled) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(token);
        _settlementTokenPolicies[token] = enabled;
        emit SettlementTokenPolicyUpdated(token, enabled, msg.sender);
    }

    function setBondTokenRegistration(address bondToken, bool registered) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(bondToken);
        _registeredBondTokens[bondToken] = registered;
        emit BondTokenRegistrationUpdated(bondToken, registered, msg.sender);
    }

    function setAiToleranceSeconds(uint256 toleranceSeconds) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (toleranceSeconds < MIN_AI_TOLERANCE_SECONDS || toleranceSeconds > MAX_AI_TOLERANCE_SECONDS) {
            revert InvalidAiTolerance(toleranceSeconds, MIN_AI_TOLERANCE_SECONDS, MAX_AI_TOLERANCE_SECONDS);
        }
        _aiToleranceSeconds = toleranceSeconds;
        emit AiToleranceUpdated(toleranceSeconds, msg.sender);
    }

    function isBondTokenRegistered(address bondToken) public view returns (bool) {
        return _registeredBondTokens[bondToken];
    }

    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    function hashOrder(Order calldata order) external view returns (bytes32) { return _hashOrder(order); }

    function isOrderConsumed(bytes32 orderHash) external view returns (bool) { return _consumedOrders[orderHash]; }

    function isOrderCancelled(bytes32 orderHash) external view returns (bool) { return _cancelledOrders[orderHash]; }

    function currentNonce(address maker) external view returns (uint256) { return _nonceFloors[maker]; }

    function feeConfig() external view returns (FeeConfig memory) { return _feeConfig; }

    function maxBatchSize() external pure returns (uint256) { return MAX_BATCH_SIZE; }

    function isSettlementTokenEnabled(address token) public view returns (bool) {
        return _settlementTokenPolicies[token];
    }

    function aiToleranceSeconds() external view returns (uint256) { return _aiToleranceSeconds; }

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

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(token);
        _ensureNonZero(to);
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount, msg.sender);
    }

    /// @notice Recompute and overwrite the cached EIP-712 domain separator.
    /// @dev AUDIT-FIX(N15): RFQSettlement caches the EIP-712 domain separator at initialization.
    ///      A UUPS upgrade that changes SettlementOrderEIP712.NAME or VERSION would otherwise leave
    ///      the cached value stale (initialize is not re-run during upgrades), causing fresh
    ///      signatures generated by upgraded frontends to be rejected on-chain. Admin must call
    ///      this immediately after any such upgrade.
    function refreshDomainSeparator() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = SettlementOrderEIP712.domainSeparator(address(this), block.chainid);
        emit DomainSeparatorRefreshed(_cachedChainId, _cachedDomainSeparator, msg.sender);
    }

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

    function isDomainPaused(PauseDomain domain) public view override(DomainPausable, IRFQSettlement) returns (bool) {
        return super.isDomainPaused(domain);
    }

    function _quoteFeeAmount(uint256 dirtyAmount) internal view returns (uint256) {
        return BondMath.mulBps(dirtyAmount, _feeConfig.currentFeeBps);
    }

    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        bytes32 separator = block.chainid == _cachedChainId
            ? _cachedDomainSeparator
            : SettlementOrderEIP712.domainSeparator(address(this), block.chainid);
        Order memory localOrder = order;
        return MessageHashUtils.toTypedDataHash(separator, SettlementOrderEIP712.hashOrder(localOrder));
    }

    function _validateOrder(Order calldata order, bytes calldata signature, address taker)
        internal
        view
        returns (bytes32 orderHash, bool isFeeExempt)
    {
        if (order.bondAmount == 0 || order.quoteAmount == 0) revert ZeroAmount();
        if (!isBondTokenRegistered(order.bondToken)) revert UnregisteredBondToken(order.bondToken);
        // AUDIT-FIX(N1): the RFQ accruedInterest field is denominated in the bond's native settlement
        //                token; mixing a different quoteToken (e.g. an 18-decimal asset) into
        //                dirtyAmount = quoteAmount + accruedInterest causes a catastrophic decimal
        //                collision. Reject any order whose quoteToken does not match.
        address bondSettlement = IBondToken(order.bondToken).settlementToken();
        if (order.quoteToken != bondSettlement) revert QuoteTokenMismatch(order.quoteToken, bondSettlement);
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

    /// @dev AUDIT-FIX(N7): use BondToken.accruedInterestFor (deferred-division mulDiv) for AI verification.
    ///                     The legacy lossy `accruedInterestPerUnit` helper was removed in v0.3.0.
    /// @dev AUDIT-FIX(N8): when the on-chain expected accrued interest is exactly zero (e.g. trades
    ///                     occurring before issueDate or at the issueDate boundary) the maker must
    ///                     not be allowed to inject any non-zero accruedInterest — no tolerance is
    ///                     applied for that case.
    function _validateAccruedInterest(Order calldata order) internal view {
        IBondToken bt = IBondToken(order.bondToken);
        uint256 expectedAI = bt.accruedInterestFor(order.bondAmount, block.timestamp);
        if (expectedAI == 0) {
            if (order.accruedInterest != 0) {
                revert AccruedInterestMismatch(order.accruedInterest, 0, 0);
            }
            return;
        }
        uint256 tolerance;
        if (_aiToleranceSeconds > 0) {
            uint256 expectedAILater = bt.accruedInterestFor(order.bondAmount, block.timestamp + _aiToleranceSeconds);
            tolerance = expectedAILater > expectedAI ? expectedAILater - expectedAI : 0;
        }
        if (tolerance == 0) tolerance = 1;
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
