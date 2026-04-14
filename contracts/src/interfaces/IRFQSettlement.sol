// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeConfig, Order, PauseDomain} from "../types/BondTypes.sol";

/// @title IRFQSettlement
/// @notice Interface for signed RFQ order execution, cancellation, nonce management, and fee policy.
interface IRFQSettlement {
    /// @dev Executes one final signed order.
    /// NOTE: The quotePayer must have approved `dirtyAmount + protocolFee` where
    /// dirtyAmount = quoteAmount + accruedInterest. Use {quoteFee} to pre-compute.
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

    /// @dev Registers or unregisters a bond token for RFQ settlement.
    /// Only registered bond tokens may appear in executable orders.
    /// @param bondToken Bond token address.
    /// @param registered Whether the token should be registered.
    function setBondTokenRegistration(
        address bondToken,
        bool registered
    ) external;

    /// @dev Updates the tolerance window for accrued interest validation.
    /// @param toleranceSeconds Maximum allowed deviation in seconds.
    function setAiToleranceSeconds(uint256 toleranceSeconds) external;

    /// @dev Returns whether a bond token is registered for RFQ settlement.
    /// @param bondToken Bond token address.
    /// @return registered True when the bond token is registered.
    function isBondTokenRegistered(
        address bondToken
    ) external view returns (bool);

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

    /// @dev Returns the current accrued interest tolerance in seconds.
    /// @return seconds Tolerance window.
    function aiToleranceSeconds() external view returns (uint256);

    /// @dev Returns whether one domain is paused.
    /// @param domain Domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(PauseDomain domain) external view returns (bool);

    /// @dev Quotes the protocol fee for a trade between two parties on a given bond.
    /// Returns 0 when both parties are market makers.
    /// @param bondToken Bond token address used to resolve the compliance module.
    /// @param partyA First participant address.
    /// @param partyB Second participant address.
    /// @param dirtyAmount The full settlement amount (quoteAmount + accruedInterest).
    /// @return feeAmount Estimated fee.
    function quoteFee(
        address bondToken,
        address partyA,
        address partyB,
        uint256 dirtyAmount
    ) external view returns (uint256 feeAmount);

    /// @dev Allows the admin to recover tokens accidentally sent to this contract.
    /// @param token Token address to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external;

    /// @dev EIP-5267 domain discovery for wallet and SDK interoperability.
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
        );
}
