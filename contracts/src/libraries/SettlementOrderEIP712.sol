// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Order } from "../types/BondTypes.sol";

/// @title SettlementOrderEIP712
/// @notice EIP-712 hashing helpers for BondDEX RFQ orders.
library SettlementOrderEIP712 {
    /// @notice Human-readable EIP-712 domain name.
    string internal constant NAME = "BondDEX RFQSettlement";

    /// @notice Human-readable EIP-712 domain version.
    string internal constant VERSION = "1";

    /// @notice Type hash for the EIP-712 domain separator.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Type hash for the RFQ order payload.
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address taker,address bondToken,address quoteToken,uint256 bondAmount,uint256 quoteAmount,uint8 side,uint256 expiry,uint256 nonce,uint256 salt,uint16 maxFeeBps,uint256 accruedInterest)"
    );

    /// @notice Computes the EIP-712 domain separator for a specific contract and chain.
    /// @param verifyingContract Settlement contract that verifies the signature.
    /// @param chainId Chain identifier used by the typed-data domain.
    /// @return separator Domain separator hash.
    function domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(NAME)), keccak256(bytes(VERSION)), chainId, verifyingContract
            )
        );
    }

    /// @notice Hashes the RFQ order payload without the EIP-712 domain wrapper.
    /// @param order RFQ order payload.
    /// @return orderHash Struct hash for the order.
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

    /// @notice Produces the final EIP-712 digest signed by the maker.
    /// @param order RFQ order payload.
    /// @param verifyingContract Settlement contract that verifies the signature.
    /// @param chainId Chain identifier used by the typed-data domain.
    /// @return digest Final typed-data digest.
    function hashTypedData(Order memory order, address verifyingContract, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(domainSeparator(verifyingContract, chainId), hashOrder(order));
    }
}
