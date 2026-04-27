// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ApprovalStatus, PauseDomain, Role } from "../types/BondTypes.sol";

error ZeroAddress();
error ZeroId();
error InvalidArrayLength();
error InvalidBasisPoints(uint256 value);
error InvalidApprovalState(ApprovalStatus currentStatus);
error DomainPaused(PauseDomain domain);
error DomainAlreadySet(PauseDomain domain, bool paused);
error UnauthorizedRole(address account, bytes32 role);
error UnsupportedSettlementToken(address token);
error ExpiredDeadline(uint256 expiry, uint256 currentTimestamp);
error UnsupportedInterface(address implementation, bytes4 interfaceId);
error BondTokenAlreadyBound(address currentBondToken);
error UnauthorizedController(address caller);
error TransferRestricted(uint8 restrictionCode);
error SubscriptionNotActive(bytes32 offerId);
error SubscriptionWindowClosed(bytes32 offerId, uint256 currentTimestamp);
error SubscriptionCapExceeded(bytes32 offerId, uint256 requestedUnits, uint256 remainingUnits);
error InvalidParticipantRole(address account, Role requiredRole, Role actualRole);
error NotWhitelisted(address account);
error NotYetImplemented();
error BondNotMatured(address bondToken, uint256 maturityTimestamp, uint256 currentTimestamp);
error NoClaimableBalance(address holder, address bondToken);
error InsufficientRedemptionFunding(address bondToken, uint256 availableAmount, uint256 requiredAmount);
error UnauthorizedClaimCaller(address caller, address holder, address delegate);
error InvalidSignature(address expectedSigner, address actualSigner);
error OrderAlreadyConsumed(bytes32 orderHash);
error OrderAlreadyCancelled(bytes32 orderHash);
error InvalidOrderNonce(address maker, uint256 providedNonce, uint256 minimumValidNonce);
error InvalidOrderTaker(address expectedTaker, address actualCaller);
error InvalidBatchLength(uint256 ordersLength, uint256 signaturesLength);
error InvalidBatchSize(uint256 providedSize, uint256 maxAllowedSize);
error UnauthorizedOrderMaker(address caller, address maker);
error InvalidFeeConfig(uint256 currentFeeBps, uint256 maxFeeBps);
error FeeExceedsOrderLimit(uint16 orderMaxFeeBps, uint16 currentFeeBps);
error InvestorToInvestorRestricted(address partyA, address partyB);
error UnauthorizedIssuer(address caller, address expectedIssuer);
error SubscriptionApprovalNotActive(bytes32 approvalId, ApprovalStatus currentStatus);
error MaxUnitsExceedsApproval(bytes32 approvalId, uint256 requested, uint256 approved);
error InsufficientRescuableBalance(address token, uint256 rescuableAmount, uint256 requestedAmount);
error InvalidBondConfig(string reason);
error ZeroAmount();
error UnregisteredBondToken(address bondToken);
error InvalidSubscriptionWindow(uint256 opensAt, uint256 closesAt);
error BondAlreadyMatured(address bondToken, uint256 maturityTimestamp, uint256 currentTimestamp);
error AccruedInterestMismatch(uint256 declared, uint256 expected, uint256 tolerance);
error InvalidIssueDate(uint256 issueDate, uint256 maturityTimestamp);
error SubscriptionWindowExceedsIssueDate(uint256 closesAt, uint256 issueDate);
error FeeCapImmutable();
error InvalidAiTolerance(uint256 provided, uint256 min, uint256 max);
error SubscriptionWindowMissingCloseTime();
error SubscriptionWindowAlreadyClosed(uint256 closesAt, uint256 currentTimestamp);
// AUDIT-FIX(N1): raised when an RFQ order's quoteToken does not match the bond's native settlementToken.
error QuoteTokenMismatch(address quoteToken, address settlementToken);
// AUDIT-FIX(N3): raised when the BondConfig submitted to createBond does not hash to the approved metadataHash.
error BondConfigHashMismatch(bytes32 expected, bytes32 provided);
// AUDIT-FIX(N10): raised when a SubscriptionTerms.closesAt extends past the approval expiry window.
error SubscriptionWindowExceedsApprovalExpiry(uint256 closesAt, uint256 approvalExpiresAt);
// AUDIT-FIX(N11): raised when an admin attempts to disable redemption while liability is still outstanding for the token.
error SettlementTokenHasRedemptionLiability(address token, uint256 outstandingLiability);
