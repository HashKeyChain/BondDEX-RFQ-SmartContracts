// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ApprovalStatus, PauseDomain, Role} from "../types/BondTypes.sol";

error ZeroAddress();
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
