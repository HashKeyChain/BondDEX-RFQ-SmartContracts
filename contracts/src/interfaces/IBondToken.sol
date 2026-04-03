// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    /// @dev Returns the coupon rate in basis points.
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
