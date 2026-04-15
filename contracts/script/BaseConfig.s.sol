// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";

/// @title BaseConfig
/// @notice 全局路径常量与链标识，所有部署 / 配置脚本共享。
abstract contract BaseConfig is Script {
    uint256 internal constant HSK_TESTNET_CHAIN_ID = 133;
    uint256 internal constant HSK_MAINNET_CHAIN_ID = 177;

    string internal constant RELEASE_VERSION = "0.1.0-draft";
    string internal constant ABI_EXPORT_ROOT = "../abi-export";
    string internal constant DEPLOYMENTS_ROOT = "../deployments";
    string internal constant CONFIG_ROOT = "../config";

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

    /// @dev 返回指定环境的配置文件路径，如 ../config/testnet.json
    function _configFile(string memory env) internal pure returns (string memory) {
        return string.concat(CONFIG_ROOT, "/", env, ".json");
    }

    /// @dev 根据链 ID 返回配置文件的环境名（anvil / testnet / mainnet）。
    function _envName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == HSK_TESTNET_CHAIN_ID) {
            return "testnet";
        }

        if (chainId == HSK_MAINNET_CHAIN_ID) {
            return "mainnet";
        }

        return "anvil";
    }
}
