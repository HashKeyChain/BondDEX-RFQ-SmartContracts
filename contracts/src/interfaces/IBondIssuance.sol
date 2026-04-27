// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ApprovalStatus, PauseDomain, SubscriptionTerms } from "../types/BondTypes.sol";

interface IBondIssuance {
    function approveSubscription(
        bytes32 approvalId,
        address issuer,
        address bondToken,
        uint256 maxUnits,
        uint256 expiresAt
    ) external;
    function revokeSubscriptionApproval(bytes32 approvalId) external;
    function markSubscriptionExpired(bytes32 approvalId) external;
    function createSubscription(SubscriptionTerms calldata terms, bytes32 approvalId)
        external
        returns (bytes32 offerId);
    function closeSubscription(bytes32 offerId) external;
    function subscribe(bytes32 offerId, uint256 units) external;
    function setSettlementTokenPolicy(address token, bool enabledForIssuance, bool enabledForRedemption) external;
    function depositRedemption(address bondToken, uint256 amount) external;
    function claim(address bondToken) external;
    function claimFor(address bondToken, address holder) external;
    function setClaimDelegate(address delegate) external;
    function pauseDomain(PauseDomain domain, bool paused) external;
    function getSubscription(bytes32 offerId)
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
    function getClaimDelegate(address holder) external view returns (address);
    function getRedemptionState(address bondToken)
        external
        view
        returns (uint256 fundedAmount, uint256 claimedAmount, uint256 lastFundingAt);
    function isSettlementTokenEnabled(address token) external view returns (bool);
    function getSettlementTokenPolicy(address token)
        external
        view
        returns (bool issuanceEnabled, bool redemptionEnabled);
    function rescueTokens(address token, address to, uint256 amount) external;
    function releaseExcessRedemption(address bondToken) external;
    /// @dev AUDIT-FIX(N5): admin-only forced redemption for sanctioned/blacklisted holders.
    function forceRedeem(address bondToken, address holder, address recipient) external;
    function getSubscriptionApproval(bytes32 approvalId)
        external
        view
        returns (address issuer, address bondToken, uint256 maxUnits, uint256 expiresAt, ApprovalStatus status);
    function isDomainPaused(PauseDomain domain) external view returns (bool);
}
