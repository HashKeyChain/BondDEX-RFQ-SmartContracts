// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {BondMath} from "../../src/libraries/BondMath.sol";

contract BondMathHarness {
    function scaleAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) external pure returns (uint256) {
        return BondMath.scaleAmount(amount, fromDecimals, toDecimals);
    }

    function mulBps(uint256 amount, uint256 bps) external pure returns (uint256) {
        return BondMath.mulBps(amount, bps);
    }

    function mulBpsUp(uint256 amount, uint256 bps) external pure returns (uint256) {
        return BondMath.mulBpsUp(amount, bps);
    }
}

contract BondMathTest is Test {
    BondMathHarness internal harness;

    function setUp() public {
        harness = new BondMathHarness();
    }

    function testFuzz_scaleRoundTrip(uint256 amount, uint8 fromDecimals, uint8 toDecimals) public view {
        amount = bound(amount, 1, type(uint128).max);
        fromDecimals = uint8(bound(fromDecimals, 0, 18));
        toDecimals = uint8(bound(toDecimals, 0, 18));

        uint256 scaled = harness.scaleAmount(amount, fromDecimals, toDecimals);
        uint256 roundTrip = harness.scaleAmount(scaled, toDecimals, fromDecimals);

        if (toDecimals >= fromDecimals) {
            assertEq(roundTrip, amount);
        } else {
            assertLe(roundTrip, amount);
        }
    }

    function testFuzz_mulBpsIsBounded(uint256 amount, uint16 bps) public view {
        amount = bound(amount, 1, type(uint128).max);
        bps = uint16(bound(uint256(bps), 0, 10_000));

        uint256 feeDown = harness.mulBps(amount, bps);
        uint256 feeUp = harness.mulBpsUp(amount, bps);

        assertLe(feeDown, amount);
        assertLe(feeUp, amount);
        assertGe(feeUp, feeDown);
    }
}
