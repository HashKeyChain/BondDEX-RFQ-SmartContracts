// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BondCategory, CouponFrequency, DayCount } from "../types/BondTypes.sol";

interface IBondToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function faceValue() external view returns (uint256);
    function couponRateBps() external view returns (uint256);
    function maturityTimestamp() external view returns (uint256);
    function settlementToken() external view returns (address);
    /// @dev AUDIT-FIX(N13): exposes the settlement token's decimals captured at deployment.
    function settlementTokenDecimals() external view returns (uint8);
    function complianceModule() external view returns (address);
    function issuanceController() external view returns (address);
    function issuer() external view returns (address);
    function issueDate() external view returns (uint256);
    function dayCountConvention() external view returns (DayCount);
    function couponFrequency() external view returns (CouponFrequency);
    function bondCategory() external view returns (BondCategory);
    function isin() external view returns (bytes12);
    /// @dev AUDIT-FIX(N7): high-precision total accrued interest in settlement token smallest units.
    ///      Replaces the legacy lossy `accruedInterestPerUnit` (removed in v0.3.0). For the historical
    ///      "per-unit" value pass `bondAmount = 10**decimals()`.
    function accruedInterestFor(uint256 bondAmount, uint256 timestamp) external view returns (uint256);
    /// @dev AUDIT-FIX(N13): principal of the given bond amount in settlement token smallest units.
    function principalOf(uint256 bondAmount) external view returns (uint256);
    function detectTransferRestriction(address from, address to, uint256 amount) external view returns (uint8);
    function detectTransferRestriction(address from, address to, uint256 amount, address operator)
        external
        view
        returns (uint8);
    function messageForTransferRestriction(uint8 restrictionCode) external pure returns (string memory);
}
