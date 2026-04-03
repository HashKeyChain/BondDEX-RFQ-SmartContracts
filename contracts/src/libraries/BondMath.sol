// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {InvalidBasisPoints} from "./BondErrors.sol";

/// @title BondMath
/// @notice Utility math helpers shared by BondDEX pricing and payout logic.
library BondMath {
    /// @notice Fixed denominator used for basis-point calculations.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Scales an amount between two decimal systems.
    /// @param amount Amount in the source decimal system.
    /// @param fromDecimals Decimals used by the source amount.
    /// @param toDecimals Decimals required by the destination amount.
    /// @return scaledAmount Amount represented in the destination decimal system.
    function scaleAmount(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        }

        if (fromDecimals < toDecimals) {
            return amount * (10 ** uint256(toDecimals - fromDecimals));
        }

        return amount / (10 ** uint256(fromDecimals - toDecimals));
    }

    /// @notice Multiplies an amount by basis points and rounds down.
    /// @param amount Base amount.
    /// @param bps Basis-point multiplier.
    /// @return scaledAmount Rounded-down result.
    function mulBps(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        if (bps > BPS_DENOMINATOR) {
            revert InvalidBasisPoints(bps);
        }

        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    /// @notice Multiplies an amount by basis points and rounds up.
    /// @param amount Base amount.
    /// @param bps Basis-point multiplier.
    /// @return scaledAmount Rounded-up result.
    function mulBpsUp(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        if (bps > BPS_DENOMINATOR) {
            revert InvalidBasisPoints(bps);
        }

        return Math.mulDiv(amount, bps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }
}
