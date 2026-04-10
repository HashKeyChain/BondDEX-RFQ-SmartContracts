// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Participant roles recognized by compliance policies.
enum Role {
    NONE,
    ISSUER,
    MARKET_MAKER,
    INVESTOR
}

/// @notice Direction of one RFQ order from the taker's perspective — BUY means the taker buys bonds.
enum OrderSide {
    BUY,
    SELL
}

/// @notice Independently pausable protocol domains.
enum PauseDomain {
    FACTORY,
    SUBSCRIPTION,
    SETTLEMENT,
    COMPLIANCE_ADMIN,
    REDEMPTION_FUNDING,
    CLAIMS
}

/// @notice Lifecycle states for issuance approvals stored by the factory.
enum ApprovalStatus {
    ACTIVE,
    CONSUMED,
    REVOKED,
    EXPIRED
}

/// @notice Lifecycle states for subscription offers.
enum SubscriptionStatus {
    DRAFT,
    ACTIVE,
    CLOSED,
    CANCELLED
}

/// @notice Immutable configuration used by the factory to deploy one bond series.
struct BondConfig {
    /// @notice Issuer allowed to launch and service the bond.
    address issuer;
    /// @notice Bond token name.
    string name;
    /// @notice Bond token symbol.
    string symbol;
    /// @notice Bond token decimals.
    uint8 decimals;
    /// @notice Face value per whole bond unit in settlement-token units.
    uint256 faceValue;
    /// @notice Coupon rate in basis points.
    uint256 couponRateBps;
    /// @notice Redemption maturity timestamp.
    uint256 maturityTimestamp;
    /// @notice Settlement token address shared across the lifecycle.
    address settlementToken;
    /// @notice Settlement token decimals captured for off-chain reference.
    uint8 settlementTokenDecimals;
    /// @notice Compliance implementation template used for the bond.
    address complianceImplementation;
    /// @notice Provider-facing policy identifier for the compliance module.
    bytes32 policyId;
    /// @notice Provider-facing policy version.
    uint256 policyVersion;
}

/// @notice Mutable subscription terms set by the issuer for primary issuance.
struct SubscriptionTerms {
    /// @notice Bond token offered in the subscription.
    address bondToken;
    /// @notice Settlement token accepted for payment.
    address settlementToken;
    /// @notice Price per whole bond unit in settlement-token smallest units.
    uint256 unitPrice;
    /// @notice Maximum bond amount offered through the window.
    uint256 maxUnits;
    /// @notice Opening timestamp for the offer.
    uint256 opensAt;
    /// @notice Closing timestamp for the offer.
    uint256 closesAt;
}

/// @notice Final RFQ order payload signed by the maker.
struct Order {
    /// @notice Party (market maker or investor) signing the order.
    address maker;
    /// @notice Optional fixed taker; zero address means any taker may execute.
    address taker;
    /// @notice Bond token being bought or sold.
    address bondToken;
    /// @notice Quote token paid against the bond transfer.
    address quoteToken;
    /// @notice Bond amount in smallest bond units.
    uint256 bondAmount;
    /// @notice Quote amount in smallest quote-token units.
    uint256 quoteAmount;
    /// @notice Order side from the taker's perspective — BUY means the taker buys bonds.
    OrderSide side;
    /// @notice Expiry timestamp after which execution is invalid.
    uint256 expiry;
    /// @notice Maker nonce checked against the settlement nonce floor.
    uint256 nonce;
    /// @notice Extra uniqueness salt used for otherwise identical orders.
    uint256 salt;
}

/// @notice Governance-controlled fee policy for RFQ settlement.
struct FeeConfig {
    /// @notice Recipient of protocol fees.
    address feeRecipient;
    /// @notice Active fee in basis points.
    uint16 currentFeeBps;
    /// @notice Upper bound that the active fee may not exceed.
    uint16 maxFeeBps;
}
