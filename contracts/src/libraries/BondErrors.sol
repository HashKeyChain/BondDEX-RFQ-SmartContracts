// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ApprovalStatus, PauseDomain, Role} from "../types/BondTypes.sol";

/// @title BondErrors
/// @notice Shared custom errors used across the BondDEX protocol contracts.

/// @notice Thrown when a required address argument is the zero address.
error ZeroAddress();

/// @notice Thrown when two calldata arrays expected to align by index do not match in length.
error InvalidArrayLength();

/// @notice Thrown when a basis-point value exceeds 10,000.
error InvalidBasisPoints(uint256 value);

/// @notice Thrown when an approval record is used while in the wrong lifecycle state.
error InvalidApprovalState(ApprovalStatus currentStatus);

/// @notice Thrown when a lifecycle domain is paused.
error DomainPaused(PauseDomain domain);

/// @notice Thrown when a pause flag is set to the value it already holds.
error DomainAlreadySet(PauseDomain domain, bool paused);

/// @notice Thrown when an account is missing a required role.
error UnauthorizedRole(address account, bytes32 role);

/// @notice Thrown when a settlement token is not enabled for the attempted operation.
error UnsupportedSettlementToken(address token);

/// @notice Thrown when a deadline-bound object is already expired.
error ExpiredDeadline(uint256 expiry, uint256 currentTimestamp);

/// @notice Thrown when a compliance implementation does not expose the required interface.
error UnsupportedInterface(address implementation, bytes4 interfaceId);

/// @notice Thrown when a compliance module is asked to bind a second bond token.
error BondTokenAlreadyBound(address currentBondToken);

/// @notice Thrown when a caller other than the authorized controller tries to mint or burn.
error UnauthorizedController(address caller);

/// @notice Thrown when a transfer violates the compliance policy restriction code.
error TransferRestricted(uint8 restrictionCode);

/// @notice Thrown when an operation expects an active subscription but the offer is not active.
error SubscriptionNotActive(bytes32 offerId);

/// @notice Thrown when a subscription attempt is outside the offer window.
error SubscriptionWindowClosed(bytes32 offerId, uint256 currentTimestamp);

/// @notice Thrown when a subscription request exceeds remaining offer capacity.
error SubscriptionCapExceeded(
    bytes32 offerId,
    uint256 requestedUnits,
    uint256 remainingUnits
);

/// @notice Thrown when an account does not hold the compliance role required for an action.
error InvalidParticipantRole(
    address account,
    Role requiredRole,
    Role actualRole
);

/// @notice Thrown when an account is not present in the active whitelist.
error NotWhitelisted(address account);

/// @notice Reserved error for logic that is intentionally left unimplemented.
error NotYetImplemented();

/// @notice Thrown when a redemption claim is attempted before bond maturity.
error BondNotMatured(
    address bondToken,
    uint256 maturityTimestamp,
    uint256 currentTimestamp
);

/// @notice Thrown when a holder has no redeemable bond balance.
error NoClaimableBalance(address holder, address bondToken);

/// @notice Thrown when available redemption funding is lower than the required payout.
error InsufficientRedemptionFunding(
    address bondToken,
    uint256 availableAmount,
    uint256 requiredAmount
);

/// @notice Thrown when a caller is neither the holder nor the configured claim delegate.
error UnauthorizedClaimCaller(address caller, address holder, address delegate);

/// @notice Thrown when a recovered order signer does not match the expected maker.
error InvalidSignature(address expectedSigner, address actualSigner);

/// @notice Thrown when an RFQ order has already been executed.
error OrderAlreadyConsumed(bytes32 orderHash);

/// @notice Thrown when an RFQ order has already been cancelled.
error OrderAlreadyCancelled(bytes32 orderHash);

/// @notice Thrown when an order nonce is below the maker's current nonce floor.
error InvalidOrderNonce(
    address maker,
    uint256 providedNonce,
    uint256 minimumValidNonce
);

/// @notice Thrown when an order is bound to a different taker than the caller.
error InvalidOrderTaker(address expectedTaker, address actualCaller);

/// @notice Thrown when batch orders and signatures arrays differ in length.
error InvalidBatchLength(uint256 ordersLength, uint256 signaturesLength);

/// @notice Thrown when batch size is zero or exceeds the configured hard cap.
error InvalidBatchSize(uint256 providedSize, uint256 maxAllowedSize);

/// @notice Thrown when someone other than the order maker tries to cancel the order.
error UnauthorizedOrderMaker(address caller, address maker);

/// @notice Thrown when fee configuration violates the configured basis-point bounds.
error InvalidFeeConfig(uint256 currentFeeBps, uint256 maxFeeBps);
