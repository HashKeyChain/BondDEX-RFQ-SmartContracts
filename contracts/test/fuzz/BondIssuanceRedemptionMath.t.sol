// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondIssuance} from "../../src/BondIssuance.sol";

contract BondIssuanceRedemptionHarness is BondIssuance {
    function quoteRedemptionPayout(uint256 bondAmount, uint256 faceValue, uint256 couponRateBps, uint8 bondDecimals)
        external
        pure
        returns (uint256)
    {
        uint256 principal = Math.mulDiv(bondAmount, faceValue, 10 ** uint256(bondDecimals));
        uint256 interest = Math.mulDiv(principal, couponRateBps, 10_000);
        return principal + interest;
    }
}

contract BondIssuanceRedemptionMathTest is Test {
    BondIssuanceRedemptionHarness internal harness;

    function setUp() public {
        BondIssuanceRedemptionHarness implementation = new BondIssuanceRedemptionHarness();
        harness = BondIssuanceRedemptionHarness(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(BondIssuance.initialize, (address(this)))))
        );
    }

    function testFuzz_quoteRedemptionPayoutMatchesPrincipalPlusCoupon(
        uint256 bondAmount,
        uint256 faceValue,
        uint16 couponRateBps,
        uint8 bondDecimals
    ) public view {
        bondAmount = bound(bondAmount, 1, type(uint128).max);
        faceValue = bound(faceValue, 1, type(uint96).max);
        couponRateBps = uint16(bound(uint256(couponRateBps), 0, 10_000));
        bondDecimals = uint8(bound(bondDecimals, 0, 18));

        uint256 principal = Math.mulDiv(bondAmount, faceValue, 10 ** uint256(bondDecimals));
        uint256 interest = Math.mulDiv(principal, couponRateBps, 10_000);
        uint256 payout = harness.quoteRedemptionPayout(bondAmount, faceValue, couponRateBps, bondDecimals);

        assertEq(payout, principal + interest);
    }
}
