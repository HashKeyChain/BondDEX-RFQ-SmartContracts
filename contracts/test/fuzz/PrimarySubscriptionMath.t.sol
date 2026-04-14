// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {BondIssuance} from "../../src/BondIssuance.sol";

contract BondIssuanceMathHarness is BondIssuance {
    function quoteSubscriptionCost(uint256 units, uint256 unitPrice, uint8 bondDecimals)
        external
        pure
        returns (uint256)
    {
        return _quoteSubscriptionCost(units, unitPrice, bondDecimals);
    }
}

contract PrimarySubscriptionMathTest is Test {
    BondIssuanceMathHarness internal harness;

    function setUp() public {
        harness = new BondIssuanceMathHarness();
    }

    function testFuzz_quoteSubscriptionCostMatchesMulDivCeil(uint256 units, uint256 unitPrice, uint8 bondDecimals)
        public
        view
    {
        units = bound(units, 1, type(uint128).max);
        unitPrice = bound(unitPrice, 1, type(uint96).max);
        bondDecimals = uint8(bound(bondDecimals, 0, 18));

        uint256 expected = Math.mulDiv(unitPrice, units, 10 ** uint256(bondDecimals), Math.Rounding.Ceil);
        uint256 actual = harness.quoteSubscriptionCost(units, unitPrice, bondDecimals);

        assertEq(actual, expected);
    }
}
