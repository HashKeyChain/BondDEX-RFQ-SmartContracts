// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BondCategory, CouponFrequency, DayCount} from "../types/BondTypes.sol";

/// @title IBondToken
/// @notice Interface for immutable bond tokens with controller-gated mint/burn and compliance checks.
interface IBondToken {
    /// @dev Mints bond units to one account from the authorized issuance controller.
    /// @param to Recipient address.
    /// @param amount Bond amount in smallest bond units.
    function mint(address to, uint256 amount) external;

    /// @dev Burns bond units from one account from the authorized issuance controller.
    /// @param from Account whose bonds are burned.
    /// @param amount Bond amount in smallest bond units.
    function burn(address from, uint256 amount) external;

    /// @dev Returns the face value per whole bond unit in settlement-token units.
    /// @return value Face value amount.
    function faceValue() external view returns (uint256);

    /// @dev Returns the annual coupon rate in basis points.
    /// @return bps Coupon rate basis points.
    function couponRateBps() external view returns (uint256);

    /// @dev Returns the maturity timestamp for the bond.
    /// @return timestamp Maturity timestamp.
    function maturityTimestamp() external view returns (uint256);

    /// @dev Returns the settlement token used for subscription, settlement, and redemption.
    /// @return token Settlement token address.
    function settlementToken() external view returns (address);

    /// @dev Returns the bound per-bond compliance module.
    /// @return module Compliance module address.
    function complianceModule() external view returns (address);

    /// @dev Returns the bound issuance controller address.
    /// @return controller Issuance controller address.
    function issuanceController() external view returns (address);

    /// @dev Returns the issuer address encoded into the bond definition.
    /// @return issuerAddress Issuer address.
    function issuer() external view returns (address);

    /// @dev Returns the predetermined interest accrual start date.
    /// All holders share the same issueDate; typically set after the subscription window closes.
    /// @return timestamp Issue date (Unix seconds).
    function issueDate() external view returns (uint256);

    /// @dev Returns the day count convention used for accrued interest calculation.
    /// @return convention Day count convention enum value.
    function dayCountConvention() external view returns (DayCount);

    /// @dev Returns the coupon payment frequency.
    /// @return frequency Coupon frequency enum value.
    function couponFrequency() external view returns (CouponFrequency);

    /// @dev Returns the bond category classification.
    /// @return category Bond category enum value.
    function bondCategory() external view returns (BondCategory);

    /// @dev Returns the ISIN code (ISO 6166) for the bond series.
    /// @return code 12-byte ISIN.
    function isin() external view returns (bytes12);

    /// @dev Computes the accrued interest per whole bond unit at the given timestamp.
    /// Returns 0 before issueDate; caps at maturityTimestamp for full-term interest.
    /// Used by RFQSettlement to validate secondary-market accrued interest and by
    /// BondIssuance to compute redemption payouts.
    /// @param timestamp Point in time for the calculation.
    /// @return amount Accrued interest in settlement-token units.
    function accruedInterestPerUnit(
        uint256 timestamp
    ) external view returns (uint256);

    /// @dev Evaluates one transfer restriction using ERC1404-style numeric codes.
    /// @param from Sender address.
    /// @param to Receiver address.
    /// @param amount Transfer amount in smallest bond units.
    /// @return restrictionCode Numeric restriction code where zero means success.
    function detectTransferRestriction(
        address from,
        address to,
        uint256 amount
    ) external view returns (uint8);

    /// @dev Returns the stable human-readable message for one restriction code.
    /// @param restrictionCode Numeric restriction code.
    /// @return message Restriction message string.
    function messageForTransferRestriction(
        uint8 restrictionCode
    ) external pure returns (string memory);
}
