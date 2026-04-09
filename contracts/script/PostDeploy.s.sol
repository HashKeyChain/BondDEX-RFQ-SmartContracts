// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {BaseConfig} from "./BaseConfig.s.sol";

/// @title PostDeploy
/// @notice 部署后统一配置：角色授予 + 结算代币策略 + 可选权限移交。
/// @dev 合约地址从 deployments/{chainId}.json 读取，私钥从 config/{env}.json 读取，零环境变量。
///   仅配置角色:  forge script PostDeploy --sig "configureRoles()" --broadcast --rpc-url ...
///   配置并移交:  REVOKE_CALLER_ROLES=true forge script PostDeploy --sig "configureAndHandoff()" --broadcast --rpc-url ...
contract PostDeploy is BaseConfig {
    bytes32 internal constant ISSUANCE_APPROVER_ROLE =
        keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE =
        keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE =
        keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ─── 入口函数 ────────────────────────────────────────────────────

    /// @dev 仅授予 Safe 角色 + 配置结算代币策略，不撤销 deployer 权限。
    function configureRoles() external {
        (
            uint256 deployerPrivateKey,
            ,
            address safeAdmin,
            address settlementToken,
            BondFactory factory,
            BondIssuance issuance,
            RFQSettlement settlement
        ) = _loadContext();

        vm.startBroadcast(deployerPrivateKey);

        // 授予 Safe 角色
        _grantSafeRoles(factory, issuance, settlement, safeAdmin);
        // 配置结算代币策略
        _configureSettlementToken(issuance, settlement, settlementToken);

        vm.stopBroadcast();

        console2.log("Configured Safe roles for", safeAdmin);
        console2.log("Enabled settlement token", settlementToken);
    }

    /// @dev 授予 Safe 角色 + 配置结算代币 + 可选撤销 deployer 权限（完整移交流程）。
    function configureAndHandoff() external {
        (
            uint256 deployerPrivateKey,
            address deployer,
            address safeAdmin,
            address settlementToken,
            BondFactory factory,
            BondIssuance issuance,
            RFQSettlement settlement
        ) = _loadContext();
        bool revokeCaller = vm.envOr("REVOKE_CALLER_ROLES", false);

        vm.startBroadcast(deployerPrivateKey);

        // 授予 Safe 角色
        _grantSafeRoles(factory, issuance, settlement, safeAdmin);
        // 配置结算代币策略
        _configureSettlementToken(issuance, settlement, settlementToken);

        // 可选撤销 deployer 权限
        if (revokeCaller) {
            _revokeDeployerRoles(factory, issuance, settlement, deployer);
        }

        vm.stopBroadcast();

        console2.log("Configured Safe roles for", safeAdmin);
        console2.log("Enabled settlement token", settlementToken);
        console2.log("Caller role revocation:", revokeCaller);
    }

    // ─── 内部逻辑 ────────────────────────────────────────────────────

    /// @dev 私钥从 config/{env}.json 读取，合约地址从 deployments/{chainId}.json 读取。
    function _loadContext()
        internal
        view
        returns (
            uint256 deployerPrivateKey,
            address deployer,
            address safeAdmin,
            address settlementToken,
            BondFactory factory,
            BondIssuance issuance,
            RFQSettlement settlement
        )
    {
        string memory config = vm.readFile(
            _configFile(_envName(block.chainid))
        );
        deployerPrivateKey = vm.parseJsonUint(config, ".deployerPrivateKey");
        deployer = vm.addr(deployerPrivateKey);

        string memory deployJson = vm.readFile(
            string.concat(
                DEPLOYMENTS_ROOT,
                "/",
                vm.toString(block.chainid),
                ".json"
            )
        );
        safeAdmin = vm.parseJsonAddress(deployJson, ".safeAdmin");
        settlementToken = vm.parseJsonAddress(deployJson, ".settlementToken");
        factory = BondFactory(
            vm.parseJsonAddress(deployJson, ".contracts.bondFactory")
        );
        issuance = BondIssuance(
            vm.parseJsonAddress(deployJson, ".contracts.bondIssuance")
        );
        settlement = RFQSettlement(
            vm.parseJsonAddress(deployJson, ".contracts.rfqSettlement")
        );
    }

    function _grantSafeRoles(
        BondFactory factory,
        BondIssuance issuance,
        RFQSettlement settlement,
        address safeAdmin
    ) internal {
        // 将 platformAdmin 转移给 Safe，确保后续创建的 ComplianceModule 使用正确的 admin
        factory.setPlatformAdmin(safeAdmin);

        // 给safeAdmin授予所有角色
        factory.grantRole(ISSUANCE_APPROVER_ROLE, safeAdmin);
        factory.grantRole(COMPLIANCE_ADMIN_ROLE, safeAdmin);
        factory.grantRole(PAUSER_ROLE, safeAdmin);

        issuance.grantRole(0x00, safeAdmin);
        issuance.grantRole(SETTLEMENT_ADMIN_ROLE, safeAdmin);
        issuance.grantRole(PAUSER_ROLE, safeAdmin);
        issuance.grantRole(UPGRADER_ROLE, safeAdmin);

        settlement.grantRole(0x00, safeAdmin);
        settlement.grantRole(SETTLEMENT_ADMIN_ROLE, safeAdmin);
        settlement.grantRole(PAUSER_ROLE, safeAdmin);
        settlement.grantRole(UPGRADER_ROLE, safeAdmin);
    }

    function _configureSettlementToken(
        BondIssuance issuance,
        RFQSettlement settlement,
        address settlementToken
    ) internal {
        // 配置结算代币策略，BondIssuance只管一级市场的发行和到期赎回
        // 允许使用结算代币进行认购
        // 不允许使用结算代币进行结算
        // 允许使用结算代币进行赎回
        issuance.setSettlementTokenPolicy(settlementToken, true, false, true);
        // RFQSettlement管二级市场的结算
        // 允许使用结算代币进行结算
        settlement.setSettlementTokenPolicy(settlementToken, true);
    }

    function _revokeDeployerRoles(
        BondFactory factory,
        BondIssuance issuance,
        RFQSettlement settlement,
        address deployer
    ) internal {
        // 撤销 deployer 的所有角色
        factory.renounceRole(ISSUANCE_APPROVER_ROLE, deployer);
        factory.renounceRole(COMPLIANCE_ADMIN_ROLE, deployer);
        factory.renounceRole(PAUSER_ROLE, deployer);
        factory.renounceRole(0x00, deployer);

        issuance.renounceRole(SETTLEMENT_ADMIN_ROLE, deployer);
        issuance.renounceRole(PAUSER_ROLE, deployer);
        issuance.renounceRole(UPGRADER_ROLE, deployer);
        issuance.renounceRole(0x00, deployer);

        settlement.renounceRole(SETTLEMENT_ADMIN_ROLE, deployer);
        settlement.renounceRole(PAUSER_ROLE, deployer);
        settlement.renounceRole(UPGRADER_ROLE, deployer);
        settlement.renounceRole(0x00, deployer);
    }
}
