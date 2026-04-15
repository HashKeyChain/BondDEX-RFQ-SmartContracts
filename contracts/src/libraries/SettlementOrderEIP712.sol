// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Order } from "../types/BondTypes.sol";

library SettlementOrderEIP712 {
    string internal constant NAME = "BondDEX RFQSettlement";
    string internal constant VERSION = "1";

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address bondToken,address quoteToken,uint256 bondAmount,uint256 quoteAmount,uint8 side,uint256 expiry,uint256 nonce,uint256 salt,uint16 maxFeeBps,uint256 accruedInterest)"
    );

    function domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(VERSION)), chainId, verifyingContract
            )
        );
    }

    function hashOrder(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.taker,
                order.bondToken,
                order.quoteToken,
                order.bondAmount,
                order.quoteAmount,
                uint8(order.side),
                order.expiry,
                order.nonce,
                order.salt,
                order.maxFeeBps,
                order.accruedInterest
            )
        );
    }

    function hashTypedData(Order memory order, address verifyingContract, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(domainSeparator(verifyingContract, chainId), hashOrder(order));
    }
}
