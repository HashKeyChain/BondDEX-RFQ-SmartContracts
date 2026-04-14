// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {FeeConfig} from "../../src/types/BondTypes.sol";
import {RFQSettlement} from "../../src/RFQSettlement.sol";

contract RFQSettlementMathHarness is RFQSettlement {
    function quoteFeeAmount(uint256 quoteAmount) external view returns (uint256) {
        return _quoteFeeAmount(quoteAmount);
    }
}

contract RFQSettlementMathTest is Test {
    RFQSettlementMathHarness internal harness;

    function setUp() public {
        RFQSettlementMathHarness implementation = new RFQSettlementMathHarness();
        harness = RFQSettlementMathHarness(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(RFQSettlement.initialize, (address(this), 1_000))))
        );
        harness.setFeeConfig(FeeConfig({feeRecipient: address(this), currentFeeBps: 100, maxFeeBps: 1_000}));
    }

    function testFuzz_quoteFeeMatchesMulDiv(uint256 quoteAmount) public view {
        quoteAmount = bound(quoteAmount, 1, type(uint128).max);

        assertEq(harness.quoteFeeAmount(quoteAmount), Math.mulDiv(quoteAmount, 100, 10_000));
    }
}
