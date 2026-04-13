// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    SettlementOrderEIP712
} from "../../src/libraries/SettlementOrderEIP712.sol";
import {Order, OrderSide} from "../../src/types/BondTypes.sol";

contract SettlementOrderEIP712Harness {
    function hashOrder(Order memory order) external pure returns (bytes32) {
        return SettlementOrderEIP712.hashOrder(order);
    }

    function domainSeparator(
        address verifyingContract,
        uint256 chainId
    ) external pure returns (bytes32) {
        return
            SettlementOrderEIP712.domainSeparator(verifyingContract, chainId);
    }

    function hashTypedData(
        Order memory order,
        address verifyingContract,
        uint256 chainId
    ) external pure returns (bytes32) {
        return
            SettlementOrderEIP712.hashTypedData(
                order,
                verifyingContract,
                chainId
            );
    }
}

contract SettlementOrderEIP712Test is Test {
    function test_hashChangesWhenNonceChanges() public {
        SettlementOrderEIP712Harness harness = new SettlementOrderEIP712Harness();
        Order memory first = _sampleOrder();
        Order memory second = _sampleOrder();
        second.nonce = 43;

        assertNotEq(harness.hashOrder(first), harness.hashOrder(second));
    }

    function test_typedHashChangesAcrossChainOrVerifyingContract() public {
        SettlementOrderEIP712Harness harness = new SettlementOrderEIP712Harness();
        Order memory order = _sampleOrder();

        bytes32 baseHash = harness.hashTypedData(order, address(0xB0D1), 133);
        bytes32 chainHash = harness.hashTypedData(order, address(0xB0D1), 177);
        bytes32 contractHash = harness.hashTypedData(
            order,
            address(0xCAFE),
            133
        );

        assertNotEq(baseHash, chainHash);
        assertNotEq(baseHash, contractHash);
    }

    function _sampleOrder() internal pure returns (Order memory) {
        return
            Order({
                maker: address(0xA11CE),
                taker: address(0xB0B),
                bondToken: address(0xB0D1),
                quoteToken: address(0xC0DE),
                bondAmount: 100e18,
                quoteAmount: 1_000_000e6,
                side: OrderSide.BUY,
                expiry: 1_900_000_000,
                nonce: 42,
                salt: 777,
                maxFeeBps: 10_000,
                accruedInterest: 0
            });
    }
}
