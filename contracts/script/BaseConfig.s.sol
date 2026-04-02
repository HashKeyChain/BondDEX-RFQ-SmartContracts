// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

abstract contract BaseConfig is Script {
    uint256 internal constant HSK_TESTNET_CHAIN_ID = 133;
    uint256 internal constant HSK_MAINNET_CHAIN_ID = 177;

    string internal constant RELEASE_VERSION = "0.1.0-draft";
    string internal constant ABI_EXPORT_ROOT = "../abi-export";
    string internal constant DEPLOYMENTS_ROOT = "../deployments";

    function _isSupportedChain(uint256 chainId) internal pure returns (bool) {
        return chainId == HSK_TESTNET_CHAIN_ID || chainId == HSK_MAINNET_CHAIN_ID;
    }

    function _networkLabel(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "testnet";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "mainnet";
        }

        return "local";
    }

    function _rpcEnvKey(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "HSK_TESTNET_RPC_URL";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "HSK_MAINNET_RPC_URL";
        }

        return "ANVIL_RPC_URL";
    }

    function _safeAdminEnvKey(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "TESTNET_SAFE_ADMIN";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "MAINNET_SAFE_ADMIN";
        }

        return "ANVIL_SAFE_ADMIN";
    }

    function _settlementTokenEnvKey(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "TESTNET_SETTLEMENT_TOKEN";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "MAINNET_SETTLEMENT_TOKEN";
        }

        return "ANVIL_SETTLEMENT_TOKEN";
    }

    function _deployerKeyEnvKey(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "TESTNET_DEPLOYER_PRIVATE_KEY";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "MAINNET_DEPLOYER_PRIVATE_KEY";
        }

        return "ANVIL_PRIVATE_KEY";
    }
}
