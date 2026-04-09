// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeConfig, Order, PauseDomain} from "../types/BondTypes.sol";

/// @title IRFQSettlement
/// @notice Interface for signed RFQ order execution, cancellation, nonce management, and fee policy.
interface IRFQSettlement {
    /// @dev Executes one final signed order.
    /// NOTE: When the market maker is the quotePayer (i.e. SELL-side for taker), the
    /// quotePayer must have approved `quoteAmount + protocolFee` to this contract, because
    /// the fee is collected in a separate transfer from the same payer. Use {quoteFee} to
    /// pre-compute the total approval needed.
    /// @param order Final EIP-712 order payload.
    /// @param signature Maker signature over the typed order digest.
    function fillOrder(Order calldata order, bytes calldata signature) external;

    /// @dev Executes multiple final signed orders atomically.
    /// @param orders Final EIP-712 order payloads.
    /// @param signatures Maker signatures aligned by index.
    function batchFillOrders(
        Order[] calldata orders,
        bytes[] calldata signatures
    ) external;

    /// @dev Cancels one signed order by hashable payload.
    /// @param order Final EIP-712 order payload.
    function cancelOrder(Order calldata order) external;

    /// @dev Cancels multiple signed orders by payload.
    /// @param orders Final EIP-712 order payloads.
    function batchCancelOrders(Order[] calldata orders) external;

    /// @dev Invalidates all older orders for the caller by increasing the minimum valid nonce by one.
    function incrementNonce() external;

    /// @dev Jumps the maker nonce floor to an arbitrary higher value, bulk-invalidating older orders.
    /// @param newMinNonce New minimum valid nonce (must be strictly greater than current).
    function setMinimumNonce(uint256 newMinNonce) external;

    /// @dev Updates fee recipient and bounded fee policy.
    /// @param config Fee configuration payload.
    function setFeeConfig(FeeConfig calldata config) external;

    /// @dev Enables or disables one settlement token for RFQ execution.
    /// @param token Settlement token address.
    /// @param enabled Whether the token should be enabled.
    function setSettlementTokenPolicy(address token, bool enabled) external;

    /// @dev Sets the paused state for one settlement-controlled domain.
    /// @param domain Domain to update.
    /// @param paused Whether the domain should be paused.
    function pauseDomain(PauseDomain domain, bool paused) external;

    /// @dev Returns the EIP-712 typed-data hash used for signature validation.
    /// @param order Final EIP-712 order payload.
    /// @return orderHash Typed-data hash.
    function hashOrder(Order calldata order) external view returns (bytes32);

    /// @dev Returns whether one order hash has already been executed.
    /// @param orderHash Typed order hash.
    /// @return consumed True when the order has been consumed.
    function isOrderConsumed(bytes32 orderHash) external view returns (bool);

    /// @dev Returns whether one order hash has already been cancelled.
    /// @param orderHash Typed order hash.
    /// @return cancelled True when the order has been cancelled.
    function isOrderCancelled(bytes32 orderHash) external view returns (bool);

    /// @dev Returns the current minimum valid nonce for one maker.
    /// @param maker Maker address.
    /// @return nonce Minimum valid nonce.
    function currentNonce(address maker) external view returns (uint256);

    /// @dev Returns the active fee configuration.
    /// @return config Fee configuration payload.
    function feeConfig() external view returns (FeeConfig memory);

    /// @dev Returns the hard batch cap for atomic settlement.
    /// @return size Maximum number of orders allowed in one batch.
    function maxBatchSize() external view returns (uint256);

    /// @dev Returns whether one settlement token is enabled.
    /// @param token Settlement token address.
    /// @return enabled True when the token is enabled.
    function isSettlementTokenEnabled(
        address token
    ) external view returns (bool);

    /// @dev Returns whether one domain is paused.
    /// @param domain Domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(PauseDomain domain) external view returns (bool);

    /// @dev Quotes the protocol fee for a trade between two parties on a given bond.
    /// Returns 0 when both parties are market makers.
    /// @param bondToken Bond token address used to resolve the compliance module.
    /// @param partyA First participant address.
    /// @param partyB Second participant address.
    /// @param quoteAmount The payer's total input amount.
    /// @return feeAmount Estimated fee deducted from quoteAmount.
    function quoteFee(
        address bondToken,
        address partyA,
        address partyB,
        uint256 quoteAmount
    ) external view returns (uint256 feeAmount);
}
