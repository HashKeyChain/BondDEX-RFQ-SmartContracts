// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum Role { NONE, ISSUER, MARKET_MAKER, INVESTOR }

enum OrderSide { BUY, SELL }

enum PauseDomain { FACTORY, SUBSCRIPTION, SETTLEMENT, COMPLIANCE_ADMIN, REDEMPTION_FUNDING, CLAIMS }

enum ApprovalStatus { NONE, ACTIVE, CONSUMED, REVOKED, EXPIRED }

enum SubscriptionStatus { NONE, ACTIVE, CLOSED, CANCELLED }

enum DayCount { ACT_365, ACT_360 }

enum CouponFrequency { BULLET, ANNUAL }

enum BondCategory { CORPORATE, GOVERNMENT, CONVERTIBLE, ABS }

struct BondConfig {
    address issuer;
    string name;
    string symbol;
    uint8 decimals;
    uint256 faceValue;
    uint256 couponRateBps;
    uint256 maturityTimestamp;
    address settlementToken;
    uint8 settlementTokenDecimals;
    address complianceImplementation;
    bytes32 policyId;
    uint256 policyVersion;
    uint256 issueDate;
    DayCount dayCountConvention;
    CouponFrequency couponFrequency;
    BondCategory bondCategory;
    bytes12 isin;
}

struct SubscriptionTerms {
    address bondToken;
    address settlementToken;
    uint256 unitPrice;
    uint256 maxUnits;
    uint256 opensAt;
    uint256 closesAt;
}

struct Order {
    address maker;
    address taker;
    address bondToken;
    address quoteToken;
    uint256 bondAmount;
    uint256 quoteAmount;
    OrderSide side;
    uint256 expiry;
    uint256 nonce;
    uint256 salt;
    uint16 maxFeeBps;
    uint256 accruedInterest;
}

struct FeeConfig {
    address feeRecipient;
    uint16 currentFeeBps;
    uint16 maxFeeBps;
}
