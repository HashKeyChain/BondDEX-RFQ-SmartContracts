// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {IComplianceModule} from "../src/interfaces/IComplianceModule.sol";
import {FeeConfig} from "../src/types/BondTypes.sol";
import {DeployConfig, TokenPolicy, DeployResult} from "./DeployTypes.s.sol";
import {DeployConfigParser} from "./DeployConfigParser.s.sol";
import {DeployJsonWriter} from "./DeployJsonWriter.s.sol";

/// @title FullDeploy
/// @notice 一站式部署：部署合约 → 注册合规模板 → 配置结算代币 → 配置手续费 → 逐角色授权 → 撤销 deployer → 输出完整清单。
/// @dev 角色地址与策略从 config/{env}.json 读取；部署者私钥通过 DEPLOYER_PRIVATE_KEY 环境变量传入。
///   Anvil:   DEPLOYER_PRIVATE_KEY=0x... forge script FullDeploy --sig "anvil()" --broadcast --rpc-url http://127.0.0.1:8545
///   Testnet: DEPLOYER_PRIVATE_KEY=0x... forge script FullDeploy --sig "testnet()" --broadcast --rpc-url $(jq -r .rpcUrl config/testnet.json)
///   Mainnet: DEPLOYER_PRIVATE_KEY=0x... forge script FullDeploy --sig "mainnet()" --broadcast --rpc-url $(jq -r .rpcUrl config/mainnet.json)
contract FullDeploy is DeployConfigParser, DeployJsonWriter {
    // ─── 角色常量 ────────────────────────────────────────────────

    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE = keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ─── 入口函数 ────────────────────────────────────────────────

    function anvil() external {
        _run("anvil");
    }

    function testnet() external {
        require(block.chainid == HSK_TESTNET_CHAIN_ID, "chainId mismatch: expected 133 (testnet)");
        _run("testnet");
    }

    function mainnet() external {
        require(block.chainid == HSK_MAINNET_CHAIN_ID, "chainId mismatch: expected 177 (mainnet)");
        _run("mainnet");
    }

    /// @dev 统一部署流水线：解析配置 → 部署 Mock 代币（零地址时） → 校验 → 部署合约 → 配置授权 → 撤销 → 输出。
    function _run(string memory env) internal {
        string memory json = vm.readFile(_configFile(env));
        DeployConfig memory cfg = _parseConfig(json);
        TokenPolicy[] memory tokens = _parseTokenPolicies(json);

        vm.startBroadcast(cfg.deployerPrivateKey);

        _deployMockTokens(tokens);
        _validateConfig(cfg, tokens);
        DeployResult memory r = _deployAll(cfg);
        _configureAll(cfg, r, tokens);

        vm.stopBroadcast();

        _writeOutput(cfg, r, tokens);
        _logResult(env, cfg, r, tokens);
    }

    // ─── 合约部署 ────────────────────────────────────────────────

    function _deployAll(DeployConfig memory cfg) internal returns (DeployResult memory r) {
        r.complianceImpl = address(new ComplianceModule());

        r.bondIssuanceImpl = address(new BondIssuance());
        r.bondIssuance =
            address(new ERC1967Proxy(r.bondIssuanceImpl, abi.encodeCall(BondIssuance.initialize, (cfg.deployer))));

        r.rfqSettlementImpl = address(new RFQSettlement());
        r.rfqSettlement = address(
            new ERC1967Proxy(
                r.rfqSettlementImpl, abi.encodeCall(RFQSettlement.initialize, (cfg.deployer, cfg.maxFeeBps))
            )
        );

        r.bondFactory = address(new BondFactory(cfg.deployer, r.bondIssuance));
    }

    // ─── 配置 + 授权 + 移交 ──────────────────────────────────────

    function _configureAll(DeployConfig memory cfg, DeployResult memory r, TokenPolicy[] memory tokens) internal {
        BondFactory factory = BondFactory(r.bondFactory);
        BondIssuance issuance = BondIssuance(r.bondIssuance);
        RFQSettlement settlement = RFQSettlement(r.rfqSettlement);

        // ① 注册 ComplianceModule 实现模板
        factory.registerComplianceImplementation(r.complianceImpl, type(IComplianceModule).interfaceId);

        // ② 配置全部结算代币策略
        for (uint256 i = 0; i < tokens.length; i++) {
            issuance.setSettlementTokenPolicy(
                tokens[i].token, tokens[i].issuanceEnabled, tokens[i].settlementEnabled, tokens[i].redemptionEnabled
            );
            settlement.setSettlementTokenPolicy(tokens[i].token, tokens[i].rfqSettlementEnabled);
        }

        // ③ 配置 RFQ 手续费
        settlement.setFeeConfig(
            FeeConfig({feeRecipient: cfg.feeRecipient, currentFeeBps: cfg.currentFeeBps, maxFeeBps: cfg.maxFeeBps})
        );

        // ④ 设置 platformAdmin
        factory.setPlatformAdmin(cfg.platformAdmin);

        // ⑤⑥⑦ 逐角色授权
        _grantFactoryRoles(factory, cfg);
        _grantIssuanceRoles(issuance, cfg);
        _grantSettlementRoles(settlement, cfg);

        // ⑧ 选择性撤销 deployer 角色（已移交给他人的角色才撤销）
        if (cfg.revokeDeployer) {
            _revokeDeployerRoles(factory, issuance, settlement, cfg);
        }
    }

    function _grantFactoryRoles(BondFactory factory, DeployConfig memory cfg) internal {
        factory.grantRole(0x00, cfg.factoryAdmin);
        factory.grantRole(ISSUANCE_APPROVER_ROLE, cfg.factoryIssuanceApprover);
        factory.grantRole(COMPLIANCE_ADMIN_ROLE, cfg.factoryComplianceAdmin);
        factory.grantRole(PAUSER_ROLE, cfg.factoryPauser);
    }

    function _grantIssuanceRoles(BondIssuance issuance, DeployConfig memory cfg) internal {
        issuance.grantRole(0x00, cfg.issuanceAdmin);
        issuance.grantRole(ISSUANCE_APPROVER_ROLE, cfg.issuanceIssuanceApprover);
        issuance.grantRole(SETTLEMENT_ADMIN_ROLE, cfg.issuanceSettlementAdmin);
        issuance.grantRole(PAUSER_ROLE, cfg.issuancePauser);
        issuance.grantRole(UPGRADER_ROLE, cfg.issuanceUpgrader);
    }

    function _grantSettlementRoles(RFQSettlement settlement, DeployConfig memory cfg) internal {
        settlement.grantRole(0x00, cfg.rfqAdmin);
        settlement.grantRole(SETTLEMENT_ADMIN_ROLE, cfg.rfqSettlementAdmin);
        settlement.grantRole(PAUSER_ROLE, cfg.rfqPauser);
        settlement.grantRole(UPGRADER_ROLE, cfg.rfqUpgrader);
    }

    /// @dev 选择性撤销 deployer 角色：仅 renounce 已移交给其他地址的角色。
    ///      若某角色的目标地址就是 deployer，则保留该角色并输出警告。
    function _revokeDeployerRoles(
        BondFactory factory,
        BondIssuance issuance,
        RFQSettlement settlement,
        DeployConfig memory cfg
    ) internal {
        address d = cfg.deployer;
        uint256 retained;

        // ── BondFactory ──
        retained += _renounceIf(
            factory, ISSUANCE_APPROVER_ROLE, d, cfg.factoryIssuanceApprover, "BondFactory.ISSUANCE_APPROVER_ROLE"
        );
        retained += _renounceIf(
            factory, COMPLIANCE_ADMIN_ROLE, d, cfg.factoryComplianceAdmin, "BondFactory.COMPLIANCE_ADMIN_ROLE"
        );
        retained += _renounceIf(factory, PAUSER_ROLE, d, cfg.factoryPauser, "BondFactory.PAUSER_ROLE");
        // DEFAULT_ADMIN_ROLE: setPlatformAdmin 也会授予 admin，两者都要检查
        if (cfg.factoryAdmin != d && cfg.platformAdmin != d) {
            factory.renounceRole(0x00, d);
        } else {
            console2.log("  [RETAINED] BondFactory.DEFAULT_ADMIN_ROLE -> deployer");
            retained++;
        }

        // ── BondIssuance ──
        retained += _renounceIf(
            issuance, ISSUANCE_APPROVER_ROLE, d, cfg.issuanceIssuanceApprover, "BondIssuance.ISSUANCE_APPROVER_ROLE"
        );
        retained += _renounceIf(
            issuance, SETTLEMENT_ADMIN_ROLE, d, cfg.issuanceSettlementAdmin, "BondIssuance.SETTLEMENT_ADMIN_ROLE"
        );
        retained += _renounceIf(issuance, PAUSER_ROLE, d, cfg.issuancePauser, "BondIssuance.PAUSER_ROLE");
        retained += _renounceIf(issuance, UPGRADER_ROLE, d, cfg.issuanceUpgrader, "BondIssuance.UPGRADER_ROLE");
        if (cfg.issuanceAdmin != d) {
            issuance.renounceRole(0x00, d);
        } else {
            console2.log("  [RETAINED] BondIssuance.DEFAULT_ADMIN_ROLE -> deployer");
            retained++;
        }

        // ── RFQSettlement ──
        retained += _renounceIf(
            settlement, SETTLEMENT_ADMIN_ROLE, d, cfg.rfqSettlementAdmin, "RFQSettlement.SETTLEMENT_ADMIN_ROLE"
        );
        retained += _renounceIf(settlement, PAUSER_ROLE, d, cfg.rfqPauser, "RFQSettlement.PAUSER_ROLE");
        retained += _renounceIf(settlement, UPGRADER_ROLE, d, cfg.rfqUpgrader, "RFQSettlement.UPGRADER_ROLE");
        if (cfg.rfqAdmin != d) {
            settlement.renounceRole(0x00, d);
        } else {
            console2.log("  [RETAINED] RFQSettlement.DEFAULT_ADMIN_ROLE -> deployer");
            retained++;
        }

        if (retained > 0) {
            console2.log("  [WARN] deployer retained roles:", retained);
        }
    }

    /// @dev 若 assignee != deployer 则 renounce 该角色；否则保留并记录警告。返回 1 表示保留，0 表示已撤销。
    function _renounceIf(BondFactory target, bytes32 role, address deployer, address assignee, string memory label)
        internal
        returns (uint256)
    {
        if (assignee != deployer) {
            target.renounceRole(role, deployer);
            return 0;
        }
        console2.log(string.concat("  [RETAINED] ", label, " -> deployer"));
        return 1;
    }

    function _renounceIf(BondIssuance target, bytes32 role, address deployer, address assignee, string memory label)
        internal
        returns (uint256)
    {
        if (assignee != deployer) {
            target.renounceRole(role, deployer);
            return 0;
        }
        console2.log(string.concat("  [RETAINED] ", label, " -> deployer"));
        return 1;
    }

    function _renounceIf(RFQSettlement target, bytes32 role, address deployer, address assignee, string memory label)
        internal
        returns (uint256)
    {
        if (assignee != deployer) {
            target.renounceRole(role, deployer);
            return 0;
        }
        console2.log(string.concat("  [RETAINED] ", label, " -> deployer"));
        return 1;
    }
}
