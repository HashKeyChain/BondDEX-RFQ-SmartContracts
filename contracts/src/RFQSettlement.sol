// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
    AccruedInterestMismatch,
    ExpiredDeadline,
    FeeExceedsOrderLimit,
    InvalidBatchLength,
    InvalidBatchSize,
    InvalidFeeConfig,
    InvalidOrderNonce,
    InvalidOrderTaker,
    InvalidParticipantRole,
    InvalidSignature,
    InvestorToInvestorRestricted,
    OrderAlreadyCancelled,
    OrderAlreadyConsumed,
    UnauthorizedOrderMaker,
    NotWhitelisted,
    UnregisteredBondToken,
    UnsupportedSettlementToken,
    ZeroAddress,
    ZeroAmount
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
/// @notice Secondary-market settlement engine for signed RFQ bond orders with accrued interest.
/// @dev Makers sign EIP-712 orders off-chain and investors execute them on-chain. The contract
/// validates signatures, nonce floors, allowlisted settlement tokens, compliance roles, fee policy,
/// and accrued interest correctness.
contract RFQSettlement is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
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
        uint256 accruedInterest,
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

    /// @notice Emitted when governance registers or unregisters a bond token for RFQ settlement.
    event BondTokenRegistrationUpdated(
        address indexed bondToken,
        bool registered,
        address operator
    );

    /// @notice Emitted when governance updates the accrued interest tolerance window.
    event AiToleranceUpdated(uint256 newToleranceSeconds, address operator);

    /// @notice Hard cap on the number of orders that may be settled atomically in one batch.
    uint256 internal constant MAX_BATCH_SIZE = 24;

    /// @notice Default accrued interest tolerance window (5 minutes).
    uint256 internal constant DEFAULT_AI_TOLERANCE_SECONDS = 300;

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

    /// @dev Registry of bond tokens allowed in RFQ orders, preventing fake-token attacks.
    mapping(address bondToken => bool registered) private _registeredBondTokens;

    /// @dev Tolerance window in seconds for accrued interest validation.
    uint256 private _aiToleranceSeconds;

    /// @dev Reserved storage gap for future proxy-safe upgrades.
    uint256[44] private __gap;

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

        _feeConfig = FeeConfig({
            feeRecipient: admin,
            currentFeeBps: 0,
            maxFeeBps: 1_000
        });

        _aiToleranceSeconds = DEFAULT_AI_TOLERANCE_SECONDS;
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Validates one signed order and executes the corresponding asset transfers.
    function fillOrder(
        Order calldata order,
        bytes calldata signature
    ) external nonReentrant {
        _requireDomainActive(PauseDomain.SETTLEMENT);

        (bytes32 orderHash, Role makerRole, Role takerRole) = _validateOrder(
            order,
            signature,
            msg.sender
        );
        _executeOrder(order, orderHash, msg.sender, makerRole, takerRole);
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

        uint256 len = orders.length;
        bytes32[] memory orderHashes = new bytes32[](len);
        Role[] memory makerRoles = new Role[](len);
        Role[] memory takerRoles = new Role[](len);

        for (uint256 i = 0; i < len; i++) {
            (orderHashes[i], makerRoles[i], takerRoles[i]) = _validateOrder(
                orders[i],
                signatures[i],
                msg.sender
            );
        }

        for (uint256 i = 0; i < len; i++) {
            _executeOrder(
                orders[i],
                orderHashes[i],
                msg.sender,
                makerRoles[i],
                takerRoles[i]
            );
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
        if (orders.length == 0 || orders.length > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(orders.length, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < orders.length; i++) {
            _cancelOrder(orders[i], msg.sender);
        }
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Raises the maker nonce floor by one and invalidates all older signed orders.
    function incrementNonce() external {
        _nonceFloors[msg.sender] += 1;
        emit NonceIncremented(msg.sender, _nonceFloors[msg.sender]);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Jumps the maker nonce floor to an arbitrary higher value, bulk-invalidating older orders.
    function setMinimumNonce(uint256 newMinNonce) external {
        uint256 current = _nonceFloors[msg.sender];
        if (newMinNonce <= current) {
            revert InvalidOrderNonce(msg.sender, newMinNonce, current + 1);
        }
        _nonceFloors[msg.sender] = newMinNonce;
        emit NonceIncremented(msg.sender, newMinNonce);
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
    /// @dev Registers or unregisters a bond token for RFQ settlement.
    function setBondTokenRegistration(
        address bondToken,
        bool registered
    ) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (bondToken == address(0)) {
            revert ZeroAddress();
        }

        _registeredBondTokens[bondToken] = registered;
        emit BondTokenRegistrationUpdated(bondToken, registered, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Updates the tolerance window for accrued interest validation.
    function setAiToleranceSeconds(
        uint256 toleranceSeconds
    ) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        _aiToleranceSeconds = toleranceSeconds;
        emit AiToleranceUpdated(toleranceSeconds, msg.sender);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Returns whether a bond token is registered for RFQ settlement.
    function isBondTokenRegistered(
        address bondToken
    ) public view returns (bool) {
        return _registeredBondTokens[bondToken];
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
    /// @dev Returns whether the given order hash has already been cancelled.
    function isOrderCancelled(bytes32 orderHash) external view returns (bool) {
        return _cancelledOrders[orderHash];
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
    /// @dev Returns the current accrued interest tolerance in seconds.
    function aiToleranceSeconds() external view returns (uint256) {
        return _aiToleranceSeconds;
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Quotes the protocol fee for a trade between two parties on a given bond.
    /// Returns 0 when both parties are market makers (fee-exempt).
    /// The dirtyAmount should be quoteAmount + accruedInterest.
    function quoteFee(
        address bondToken,
        address partyA,
        address partyB,
        uint256 dirtyAmount
    ) external view returns (uint256 feeAmount) {
        if (!isBondTokenRegistered(bondToken)) {
            revert UnregisteredBondToken(bondToken);
        }

        IComplianceModule complianceModule = IComplianceModule(
            IBondToken(bondToken).complianceModule()
        );
        Role roleA = complianceModule.roleOf(partyA);
        Role roleB = complianceModule.roleOf(partyB);

        if (roleA == Role.MARKET_MAKER && roleB == Role.MARKET_MAKER) {
            return 0;
        }
        return _quoteFeeAmount(dirtyAmount);
    }

    /// @inheritdoc IRFQSettlement
    /// @dev Exposes inherited pause state for interface compliance and monitoring.
    function isDomainPaused(
        PauseDomain domain
    ) public view override(DomainPausable, IRFQSettlement) returns (bool) {
        return super.isDomainPaused(domain);
    }

    /// @dev Quotes protocol fee based on the dirty amount (quoteAmount + accruedInterest).
    function _quoteFeeAmount(
        uint256 dirtyAmount
    ) internal view returns (uint256) {
        return BondMath.mulBps(dirtyAmount, _feeConfig.currentFeeBps);
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

    /// @dev Validates bond token registry, token policy, expiry, taker binding, nonce floor,
    ///      signature, participant roles, and accrued interest.
    function _validateOrder(
        Order calldata order,
        bytes calldata signature,
        address taker
    )
        internal
        view
        returns (bytes32 orderHash, Role makerRole, Role takerRole)
    {
        if (order.bondAmount == 0 || order.quoteAmount == 0) {
            revert ZeroAmount();
        }

        if (!isBondTokenRegistered(order.bondToken)) {
            revert UnregisteredBondToken(order.bondToken);
        }

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

        (makerRole, takerRole) = _requireParticipantRoles(order, taker);

        _validateAccruedInterest(order);
    }

    /// @dev Validates that the declared accrued interest is within tolerance of the on-chain value.
    function _validateAccruedInterest(Order calldata order) internal view {
        IBondToken bt = IBondToken(order.bondToken);
        uint8 bondDecimals = IERC20Metadata(order.bondToken).decimals();

        uint256 aiPerUnit = bt.accruedInterestPerUnit(block.timestamp);
        uint256 expectedAI = Math.mulDiv(
            aiPerUnit,
            order.bondAmount,
            10 ** uint256(bondDecimals)
        );

        uint256 tolerance;
        if (_aiToleranceSeconds > 0) {
            uint256 aiPerUnitLater = bt.accruedInterestPerUnit(
                block.timestamp + _aiToleranceSeconds
            );
            uint256 expectedAILater = Math.mulDiv(
                aiPerUnitLater,
                order.bondAmount,
                10 ** uint256(bondDecimals)
            );
            tolerance = expectedAILater > expectedAI
                ? expectedAILater - expectedAI
                : 0;
        }

        if (
            order.accruedInterest > expectedAI + tolerance ||
            (expectedAI > tolerance &&
                order.accruedInterest < expectedAI - tolerance)
        ) {
            revert AccruedInterestMismatch(
                order.accruedInterest,
                expectedAI,
                tolerance
            );
        }
    }

    /// @dev Validates whitelist, roles, and direction. Returns roles for downstream fee logic.
    function _requireParticipantRoles(
        Order calldata order,
        address taker
    ) internal view returns (Role makerRole, Role takerRole) {
        IComplianceModule complianceModule = IComplianceModule(
            IBondToken(order.bondToken).complianceModule()
        );

        if (!complianceModule.isWhitelisted(order.maker)) {
            revert NotWhitelisted(order.maker);
        }

        if (!complianceModule.isWhitelisted(taker)) {
            revert NotWhitelisted(taker);
        }

        makerRole = complianceModule.roleOf(order.maker);
        takerRole = complianceModule.roleOf(taker);

        if (makerRole != Role.MARKET_MAKER && makerRole != Role.INVESTOR) {
            revert InvalidParticipantRole(
                order.maker,
                Role.MARKET_MAKER,
                makerRole
            );
        }

        if (takerRole != Role.MARKET_MAKER && takerRole != Role.INVESTOR) {
            revert InvalidParticipantRole(taker, Role.INVESTOR, takerRole);
        }

        if (makerRole == Role.INVESTOR && takerRole == Role.INVESTOR) {
            revert InvestorToInvestorRestricted(order.maker, taker);
        }
    }

    /// @dev Executes token transfers for one validated order and emits the canonical fill event.
    /// dirtyAmount = quoteAmount + accruedInterest. Fee is computed on dirtyAmount.
    /// Fee is always charged to the market-maker side:
    ///   - MM is quoteReceiver → MM receives dirtyAmount - fee
    ///   - MM is quotePayer   → MM pays dirtyAmount + fee (counterparty receives dirtyAmount)
    ///   - MM ↔ MM            → fee exempt
    function _executeOrder(
        Order calldata order,
        bytes32 orderHash,
        address taker,
        Role makerRole,
        Role takerRole
    ) internal {
        if (_consumedOrders[orderHash]) {
            revert OrderAlreadyConsumed(orderHash);
        }
        _consumedOrders[orderHash] = true;

        uint256 dirtyAmount = order.quoteAmount + order.accruedInterest;

        uint256 feeAmount = (makerRole == Role.MARKET_MAKER &&
            takerRole == Role.MARKET_MAKER)
            ? 0
            : _quoteFeeAmount(dirtyAmount);

        if (feeAmount > 0 && _feeConfig.currentFeeBps > order.maxFeeBps) {
            revert FeeExceedsOrderLimit(
                order.maxFeeBps,
                _feeConfig.currentFeeBps
            );
        }

        {
            (
                address quotePayer,
                address quoteReceiver,
                address bondPayer,
                address bondReceiver
            ) = _resolveSettlementParties(order, taker);

            // Fee deducted from quoteReceiver when quoteReceiver is MM;
            // otherwise quotePayer (MM) pays dirtyAmount + fee separately.
            if (
                feeAmount == 0 ||
                (
                    order.side == OrderSide.BUY
                        ? makerRole == Role.MARKET_MAKER
                        : takerRole == Role.MARKET_MAKER
                )
            ) {
                IERC20(order.quoteToken).safeTransferFrom(
                    quotePayer,
                    quoteReceiver,
                    dirtyAmount - feeAmount
                );
            } else {
                IERC20(order.quoteToken).safeTransferFrom(
                    quotePayer,
                    quoteReceiver,
                    dirtyAmount
                );
            }

            if (feeAmount != 0) {
                IERC20(order.quoteToken).safeTransferFrom(
                    quotePayer,
                    _feeConfig.feeRecipient,
                    feeAmount
                );
            }

            IERC20(order.bondToken).safeTransferFrom(
                bondPayer,
                bondReceiver,
                order.bondAmount
            );
        }

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

    /// @dev Resolves token payers and receivers based on the taker's order side (BUY = taker buys bonds).
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
}
