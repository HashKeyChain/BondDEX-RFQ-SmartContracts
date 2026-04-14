// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ApprovalStatus,
    PauseDomain,
    SubscriptionTerms
} from "../types/BondTypes.sol";

/// @title IBondIssuance
/// @notice Interface for primary-market subscription management and post-maturity redemption flows.
interface IBondIssuance {
    /// @dev Approves one subscription window for a specific issuer and bond token.
    /// @param approvalId Unique approval identifier.
    /// @param issuer Issuer address allowed to consume the approval.
    /// @param bondToken Bond token that the subscription may target.
    /// @param maxUnits Upper bound on bond units the issuer may offer.
    /// @param expiresAt Optional expiry timestamp (0 = no expiry).
    function approveSubscription(
        bytes32 approvalId,
        address issuer,
        address bondToken,
        uint256 maxUnits,
        uint256 expiresAt
    ) external;

    /// @dev Revokes one active subscription approval.
    /// @param approvalId Subscription approval identifier to revoke.
    function revokeSubscriptionApproval(bytes32 approvalId) external;

    /// @dev Marks an active-but-expired subscription approval as EXPIRED on-chain.
    /// @param approvalId Approval identifier whose deadline has passed.
    function markSubscriptionExpired(bytes32 approvalId) external;

    /// @dev Creates one issuer-controlled subscription offer after consuming an approval.
    /// @param terms Subscription configuration payload.
    /// @param approvalId Subscription approval identifier to consume.
    /// @return offerId Created subscription offer identifier.
    function createSubscription(
        SubscriptionTerms calldata terms,
        bytes32 approvalId
    ) external returns (bytes32 offerId);

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

    /// @dev Returns the per-phase policy flags for one settlement token.
    /// @param token Settlement token address.
    /// @return issuanceEnabled True when the token may be used for subscriptions.
    /// @return settlementEnabled True when the token may be used for secondary settlement.
    /// @return redemptionEnabled True when the token may be used for redemption funding and payouts.
    function getSettlementTokenPolicy(
        address token
    )
        external
        view
        returns (
            bool issuanceEnabled,
            bool settlementEnabled,
            bool redemptionEnabled
        );

    /// @dev Allows the admin to recover tokens accidentally sent to this contract.
    /// Protects outstanding redemption liabilities across all bond series.
    /// @param token Token address to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external;

    /// @dev Releases provably excess redemption liability for one matured bond series.
    /// Computes actual obligation from outstanding supply and reduces tracked liability,
    /// making the excess available for rescue. Only callable after maturity by admin.
    /// @param bondToken Bond token address.
    function releaseExcessRedemption(address bondToken) external;

    /// @dev Returns one subscription approval record.
    /// @param approvalId Subscription approval identifier.
    /// @return issuer Approved issuer address.
    /// @return bondToken Approved bond token address.
    /// @return maxUnits Maximum bond units approved.
    /// @return expiresAt Expiry timestamp (0 = no expiry).
    /// @return status Approval lifecycle status.
    function getSubscriptionApproval(
        bytes32 approvalId
    )
        external
        view
        returns (
            address issuer,
            address bondToken,
            uint256 maxUnits,
            uint256 expiresAt,
            ApprovalStatus status
        );

    /// @dev Returns whether one domain is paused.
    /// @param domain Domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(PauseDomain domain) external view returns (bool);
}
