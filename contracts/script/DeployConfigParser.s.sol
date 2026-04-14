// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {DeployConfig, TokenPolicy} from "./DeployTypes.s.sol";
import {MockERC20Decimals} from "../test/mocks/MockERC20Decimals.sol";

/// @title DeployConfigParser
/// @notice 从 config JSON 解析部署配置、校验参数合法性。
abstract contract DeployConfigParser is Script {
    // ─── JSON 反序列化辅助结构体 ──────────────────────────────────
    // 字段按字母序排列（Foundry abi.decode 要求）

    struct BondIssuancePolicyJson {
        bool issuanceEnabled;
        bool redemptionEnabled;
        bool settlementEnabled;
    }

    struct SettlementTokenJson {
        BondIssuancePolicyJson bondIssuancePolicy;
        bool rfqSettlementEnabled;
        address token;
    }

    // ─── 解析 ────────────────────────────────────────────────────

    function _parseConfig(string memory json) internal view returns (DeployConfig memory cfg) {
        cfg.deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPrivateKey);
        cfg.platformAdmin = vm.parseJsonAddress(json, ".platformAdmin");

        cfg.factoryAdmin = vm.parseJsonAddress(json, ".roles.bondFactory.admin");
        cfg.factoryIssuanceApprover = vm.parseJsonAddress(json, ".roles.bondFactory.issuanceApprover");
        cfg.factoryComplianceAdmin = vm.parseJsonAddress(json, ".roles.bondFactory.complianceAdmin");
        cfg.factoryPauser = vm.parseJsonAddress(json, ".roles.bondFactory.pauser");

        cfg.issuanceAdmin = vm.parseJsonAddress(json, ".roles.bondIssuance.admin");
        cfg.issuanceIssuanceApprover = vm.parseJsonAddress(json, ".roles.bondIssuance.issuanceApprover");
        cfg.issuanceSettlementAdmin = vm.parseJsonAddress(json, ".roles.bondIssuance.settlementAdmin");
        cfg.issuancePauser = vm.parseJsonAddress(json, ".roles.bondIssuance.pauser");
        cfg.issuanceUpgrader = vm.parseJsonAddress(json, ".roles.bondIssuance.upgrader");

        cfg.rfqAdmin = vm.parseJsonAddress(json, ".roles.rfqSettlement.admin");
        cfg.rfqSettlementAdmin = vm.parseJsonAddress(json, ".roles.rfqSettlement.settlementAdmin");
        cfg.rfqPauser = vm.parseJsonAddress(json, ".roles.rfqSettlement.pauser");
        cfg.rfqUpgrader = vm.parseJsonAddress(json, ".roles.rfqSettlement.upgrader");

        cfg.feeRecipient = vm.parseJsonAddress(json, ".feeConfig.feeRecipient");
        cfg.currentFeeBps = uint16(vm.parseJsonUint(json, ".feeConfig.currentFeeBps"));
        cfg.maxFeeBps = uint16(vm.parseJsonUint(json, ".feeConfig.maxFeeBps"));

        cfg.revokeDeployer = vm.parseJsonBool(json, ".revokeDeployer");
    }

    function _parseTokenPolicies(string memory json) internal pure returns (TokenPolicy[] memory) {
        bytes memory raw = vm.parseJson(json, ".settlementTokens");
        SettlementTokenJson[] memory parsed = abi.decode(raw, (SettlementTokenJson[]));

        TokenPolicy[] memory tokens = new TokenPolicy[](parsed.length);
        for (uint256 i = 0; i < parsed.length; i++) {
            tokens[i] = TokenPolicy({
                token: parsed[i].token,
                issuanceEnabled: parsed[i].bondIssuancePolicy.issuanceEnabled,
                settlementEnabled: parsed[i].bondIssuancePolicy.settlementEnabled,
                redemptionEnabled: parsed[i].bondIssuancePolicy.redemptionEnabled,
                rfqSettlementEnabled: parsed[i].rfqSettlementEnabled
            });
        }

        return tokens;
    }

    // ─── 校验 ─────────────────────────────────────────────────────

    /// @dev 所有关键地址必须非零。
    function _validateConfig(DeployConfig memory cfg, TokenPolicy[] memory tokens) internal pure {
        require(cfg.platformAdmin != address(0), "platformAdmin required");

        require(cfg.factoryAdmin != address(0), "roles.bondFactory.admin required");
        require(cfg.factoryIssuanceApprover != address(0), "roles.bondFactory.issuanceApprover required");
        require(cfg.factoryComplianceAdmin != address(0), "roles.bondFactory.complianceAdmin required");
        require(cfg.factoryPauser != address(0), "roles.bondFactory.pauser required");

        require(cfg.issuanceAdmin != address(0), "roles.bondIssuance.admin required");
        require(cfg.issuanceIssuanceApprover != address(0), "roles.bondIssuance.issuanceApprover required");
        require(cfg.issuanceSettlementAdmin != address(0), "roles.bondIssuance.settlementAdmin required");
        require(cfg.issuancePauser != address(0), "roles.bondIssuance.pauser required");
        require(cfg.issuanceUpgrader != address(0), "roles.bondIssuance.upgrader required");

        require(cfg.rfqAdmin != address(0), "roles.rfqSettlement.admin required");
        require(cfg.rfqSettlementAdmin != address(0), "roles.rfqSettlement.settlementAdmin required");
        require(cfg.rfqPauser != address(0), "roles.rfqSettlement.pauser required");
        require(cfg.rfqUpgrader != address(0), "roles.rfqSettlement.upgrader required");

        require(cfg.feeRecipient != address(0), "feeConfig.feeRecipient required");
        require(cfg.maxFeeBps <= 10_000, "maxFeeBps exceeds 100%");
        require(cfg.currentFeeBps <= cfg.maxFeeBps, "currentFeeBps > maxFeeBps");

        require(tokens.length > 0, "at least one settlementToken required");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i].token != address(0), "settlementTokens[].token required");
            for (uint256 j = 0; j < i; j++) {
                require(tokens[i].token != tokens[j].token, "duplicate settlementToken address");
            }
        }
    }

    // ─── Mock 代币 ───────────────────────────────────────────────

    /// @dev 为零地址代币自动部署 MockERC20（仅本地测试用途，testnet/mainnet 配置不应有零地址）。
    function _deployMockTokens(TokenPolicy[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].token == address(0)) {
                tokens[i].token = address(new MockERC20Decimals("Mock USDC", "mUSDC", 6));
            }
        }
    }
}
