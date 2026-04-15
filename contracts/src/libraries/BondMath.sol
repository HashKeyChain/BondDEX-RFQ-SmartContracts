// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { InvalidBasisPoints } from "./BondErrors.sol";

library BondMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function scaleAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * (10 ** uint256(toDecimals - fromDecimals));
        return amount / (10 ** uint256(fromDecimals - toDecimals));
    }

    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > BPS_DENOMINATOR) revert InvalidBasisPoints(bps);
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    function mulBpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > BPS_DENOMINATOR) revert InvalidBasisPoints(bps);
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }
}
