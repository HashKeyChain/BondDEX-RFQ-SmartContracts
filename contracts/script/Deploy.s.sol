// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../test/mocks/MockERC20Decimals.sol";
import {BaseDeploy} from "./BaseDeploy.s.sol";

/// @title Deploy
/// @notice 统一部署入口，通过 --sig 选择目标环境。
/// @dev 所有配置（含私钥）从 config/{env}.json 读取，零环境变量。
///   Anvil:   forge script Deploy --sig "anvil()" --broadcast --rpc-url http://127.0.0.1:8545
///   Testnet: forge script Deploy --sig "testnet()" --broadcast --rpc-url $(jq -r .rpcUrl config/testnet.json)
///   Mainnet: forge script Deploy --sig "mainnet()" --broadcast --rpc-url $(jq -r .rpcUrl config/mainnet.json)
contract Deploy is BaseDeploy {
    // ─── 入口函数 ────────────────────────────────────────────────────

    /// @dev 本地 Anvil 部署，自动铸造 Mock USDC。
    function anvil() external returns (DeploymentRecord memory record) {
        string memory config = vm.readFile(_configFile("anvil"));

        uint256 deployerPrivateKey = vm.parseJsonUint(
            config,
            ".deployerPrivateKey"
        );
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.parseJsonAddress(config, ".safeAdmin");
        if (safeAdmin == address(0)) safeAdmin = deployer;

        vm.startBroadcast(deployerPrivateKey);
        MockERC20Decimals mockToken = new MockERC20Decimals(
            "Mock USDC",
            "mUSDC",
            6
        );
        record = _deployCore(deployer, address(mockToken), safeAdmin, 31_337);
        vm.stopBroadcast();

        _logRecord("Anvil", record);
    }

    /// @dev HSK Testnet (chain 133) 部署，从 config/testnet.json 读取全部配置。
    function testnet() external returns (DeploymentRecord memory record) {
        string memory config = vm.readFile(_configFile("testnet"));

        uint256 deployerPrivateKey = vm.parseJsonUint(
            config,
            ".deployerPrivateKey"
        );
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.parseJsonAddress(config, ".safeAdmin");
        address settlementToken = vm.parseJsonAddress(
            config,
            ".settlementToken"
        );

        vm.startBroadcast(deployerPrivateKey);
        record = _deployCore(
            deployer,
            settlementToken,
            safeAdmin,
            HSK_TESTNET_CHAIN_ID
        );
        vm.stopBroadcast();

        _writeDeploymentRecord(record);
        _logRecord("Testnet", record);
    }

    /// @dev HSK Mainnet (chain 177) 部署，从 config/mainnet.json 读取全部配置。
    function mainnet() external returns (DeploymentRecord memory record) {
        string memory config = vm.readFile(_configFile("mainnet"));

        uint256 deployerPrivateKey = vm.parseJsonUint(
            config,
            ".deployerPrivateKey"
        );
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.parseJsonAddress(config, ".safeAdmin");
        address settlementToken = vm.parseJsonAddress(
            config,
            ".settlementToken"
        );

        vm.startBroadcast(deployerPrivateKey);
        record = _deployCore(
            deployer,
            settlementToken,
            safeAdmin,
            HSK_MAINNET_CHAIN_ID
        );
        vm.stopBroadcast();

        _writeDeploymentRecord(record);
        _logRecord("Mainnet", record);
    }

    // ─── 核心部署逻辑（共享） ────────────────────────────────────────

    function _deployCore(
        address deployer,
        address settlementToken,
        address safeAdmin,
        uint256 chainId
    ) internal returns (DeploymentRecord memory record) {
        // 部署 ComplianceModule
        ComplianceModule complianceImpl = new ComplianceModule();

        // 部署 BondIssuance
        BondIssuance issuanceImpl = new BondIssuance();
        BondIssuance issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(issuanceImpl),
                    abi.encodeCall(BondIssuance.initialize, (deployer))
                )
            )
        );

        // 部署 RFQSettlement
        RFQSettlement rfqImpl = new RFQSettlement();
        RFQSettlement settlement = RFQSettlement(
            address(
                new ERC1967Proxy(
                    address(rfqImpl),
                    abi.encodeCall(RFQSettlement.initialize, (deployer))
                )
            )
        );

        // 部署 BondFactory
        BondFactory factory = new BondFactory(deployer, address(issuance));

        // 返回部署记录
        record = DeploymentRecord({
            chainId: chainId,
            bondFactory: address(factory),
            bondIssuance: address(issuance),
            rfqSettlement: address(settlement),
            complianceImplementation: address(complianceImpl),
            bondIssuanceImplementation: address(issuanceImpl),
            rfqSettlementImplementation: address(rfqImpl),
            settlementToken: settlementToken,
            deployer: deployer,
            safeAdmin: safeAdmin
        });
    }

    // ─── 日志输出 ─────────────────────────────────────────────────────

    function _logRecord(
        string memory env,
        DeploymentRecord memory r
    ) internal pure {
        console2.log(string.concat("[", env, "] BondFactory:"), r.bondFactory);
        console2.log(
            string.concat("[", env, "] BondIssuance proxy:"),
            r.bondIssuance
        );
        console2.log(
            string.concat("[", env, "] RFQSettlement proxy:"),
            r.rfqSettlement
        );
        console2.log(
            string.concat("[", env, "] Settlement token:"),
            r.settlementToken
        );
    }
}
