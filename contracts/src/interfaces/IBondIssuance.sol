// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PauseDomain, SubscriptionTerms} from "../types/BondTypes.sol";

/// @title IBondIssuance
/// @notice Interface for primary-market subscription management and post-maturity redemption flows.
interface IBondIssuance {
    /// @dev Creates one issuer-controlled subscription offer.
    /// @param terms Subscription configuration payload.
    /// @return offerId Created subscription offer identifier.
    function createSubscription(
        SubscriptionTerms calldata terms
    ) external returns (bytes32 offerId);

    /// @dev Updates one active subscription offer.
    /// @param offerId Subscription offer identifier.
    /// @param terms Updated subscription configuration payload.
    function updateSubscription(
        bytes32 offerId,
        SubscriptionTerms calldata terms
    ) external;

    /// @dev Closes one subscription offer so it cannot accept further fills.
    /// @param offerId Subscription offer identifier.
    function closeSubscription(bytes32 offerId) external;

    /// @dev Subscribes for bond units against one active offer.
    /// @param offerId Subscription offer identifier.
    /// @param units Bond amount in smallest bond units.
    function subscribe(bytes32 offerId, uint256 units) external;

    /// @dev Updates settlement-token policy flags across issuance-controlled flows.
    /// @param token Settlement token address.
    /// @param enabledForIssuance Whether issuance should allow the token.
    /// @param enabledForSettlement Whether settlement should allow the token.
    /// @param enabledForRedemption Whether redemption should allow the token.
    function setSettlementTokenPolicy(
        address token,
        bool enabledForIssuance,
        bool enabledForSettlement,
        bool enabledForRedemption
    ) external;

    /// @dev Deposits redemption funds for one matured bond.
    /// @param bondToken Bond token address.
    /// @param amount Settlement-token amount to deposit.
    function depositRedemption(address bondToken, uint256 amount) external;

    /// @dev Claims matured redemption directly for the caller.
    /// @param bondToken Bond token address.
    function claim(address bondToken) external;

    /// @dev Claims matured redemption for one holder while always paying the holder.
    /// @param bondToken Bond token address.
    /// @param holder Holder address receiving payout.
    function claimFor(address bondToken, address holder) external;

    /// @dev Sets or clears one operational claim delegate.
    /// @param delegate Delegate address, or zero address to revoke.
    function setClaimDelegate(address delegate) external;

    /// @dev Sets the paused state for one issuance-controlled domain.
    /// @param domain Domain to update.
    /// @param paused Whether the domain should be paused.
    function pauseDomain(PauseDomain domain, bool paused) external;

    /// @dev Returns one subscription offer record.
    /// @param offerId Subscription offer identifier.
    /// @return bondToken Bond token address.
    /// @return settlementToken Settlement token address.
    /// @return unitPrice Unit price in settlement-token smallest units.
    /// @return maxUnits Maximum bond amount.
    /// @return soldUnits Filled bond amount.
    /// @return opensAt Opening timestamp.
    /// @return closesAt Closing timestamp.
    /// @return status Offer status enum value.
    function getSubscription(
        bytes32 offerId
    )
        external
        view
        returns (
            address bondToken,
            address settlementToken,
            uint256 unitPrice,
            uint256 maxUnits,
            uint256 soldUnits,
            uint256 opensAt,
            uint256 closesAt,
            uint8 status
        );

    /// @dev Returns the current claim delegate for one holder.
    /// @param holder Holder address.
    /// @return delegate Delegate address or zero address.
    function getClaimDelegate(address holder) external view returns (address);

    /// @dev Returns the redemption funding state for one bond.
    /// @param bondToken Bond token address.
    /// @return fundedAmount Total deposited amount.
    /// @return claimedAmount Total claimed amount.
    /// @return lastFundingAt Latest deposit timestamp.
    function getRedemptionState(
        address bondToken
    )
        external
        view
        returns (
            uint256 fundedAmount,
            uint256 claimedAmount,
            uint256 lastFundingAt
        );

    /// @dev Returns whether one token is enabled in any issuance-controlled flow.
    /// @param token Settlement token address.
    /// @return enabled True when the token is enabled for at least one flow.
    function isSettlementTokenEnabled(
        address token
    ) external view returns (bool);

    /// @dev Allows the admin to recover tokens accidentally sent to this contract.
    /// @param token Token address to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external;

    /// @dev Returns whether one domain is paused.
    /// @param domain Domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(PauseDomain domain) external view returns (bool);
}
