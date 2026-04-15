// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { console2 } from "forge-std/console2.sol";
import { BaseConfig } from "./BaseConfig.s.sol";
import { DeployConfig, TokenPolicy, DeployResult } from "./DeployTypes.s.sol";
import { RFQSettlement } from "../src/RFQSettlement.sol";

/// @title DeployJsonWriter
/// @notice 部署结果 JSON 序列化与日志输出。
abstract contract DeployJsonWriter is BaseConfig {
    using Strings for uint256;

    // ─── 写入 ────────────────────────────────────────────────────

    function _writeOutput(DeployConfig memory cfg, DeployResult memory r, TokenPolicy[] memory tokens) internal {
        string memory json = string.concat(
            _jsonHeader(),
            _jsonMeta(cfg),
            _jsonContracts(r),
            _jsonConfig(cfg, r, tokens),
            _jsonRoles(cfg),
            _jsonHandoff(cfg),
            "}\n"
        );
        string memory filePath = string.concat(DEPLOYMENTS_ROOT, "/", block.chainid.toString(), ".json");
        vm.writeFile(filePath, json);
    }

    // ─── 日志 ────────────────────────────────────────────────────

    function _logResult(string memory env, DeployConfig memory cfg, DeployResult memory r, TokenPolicy[] memory tokens)
        internal
        pure
    {
        console2.log(string.concat("\n[", env, "] Full deployment complete"));
        console2.log("  BondFactory:       ", r.bondFactory);
        console2.log("  BondIssuance:      ", r.bondIssuance);
        console2.log("  RFQSettlement:     ", r.rfqSettlement);
        console2.log("  ComplianceImpl:    ", r.complianceImpl);
        for (uint256 i = 0; i < tokens.length; i++) {
            console2.log("  Settlement token:  ", tokens[i].token);
        }
        console2.log("  Fee recipient:     ", cfg.feeRecipient);
        console2.log("  Fee bps:           ", uint256(cfg.currentFeeBps));
        console2.log("  Platform admin:    ", cfg.platformAdmin);
        console2.log("  Deployer revoked:  ", cfg.revokeDeployer);
    }

    // ─── JSON 片段 ───────────────────────────────────────────────

    function _jsonHeader() internal view returns (string memory) {
        return string.concat(
            "{\n",
            '  "version": "',
            RELEASE_VERSION,
            '",\n',
            '  "chainId": ',
            block.chainid.toString(),
            ",\n",
            '  "network": "',
            _envName(block.chainid),
            '",\n',
            '  "deployedAt": ',
            block.timestamp.toString(),
            ",\n",
            '  "blockNumber": ',
            block.number.toString(),
            ",\n"
        );
    }

    function _jsonMeta(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '  "deployer": ', _qa(cfg.deployer), ",\n", '  "platformAdmin": ', _qa(cfg.platformAdmin), ",\n"
        );
    }

    function _jsonContracts(DeployResult memory r) internal pure returns (string memory) {
        return string.concat(
            '  "contracts": {\n',
            '    "bondFactory": ',
            _qa(r.bondFactory),
            ",\n",
            '    "bondIssuance": ',
            _qa(r.bondIssuance),
            ",\n",
            _jsonContractsImpl(r),
            "  },\n"
        );
    }

    function _jsonContractsImpl(DeployResult memory r) internal pure returns (string memory) {
        return string.concat(
            '    "bondIssuanceImplementation": ',
            _qa(r.bondIssuanceImpl),
            ",\n",
            '    "rfqSettlement": ',
            _qa(r.rfqSettlement),
            ",\n",
            '    "rfqSettlementImplementation": ',
            _qa(r.rfqSettlementImpl),
            ",\n",
            '    "complianceImplementation": ',
            _qa(r.complianceImpl),
            "\n"
        );
    }

    function _jsonConfig(DeployConfig memory cfg, DeployResult memory r, TokenPolicy[] memory tokens)
        internal
        view
        returns (string memory)
    {
        uint256 aiTolerance = RFQSettlement(r.rfqSettlement).aiToleranceSeconds();
        return string.concat(
            '  "configuration": {\n',
            _jsonTokenPolicies(tokens),
            _jsonFeeConfig(cfg),
            '    "aiToleranceSeconds": ',
            aiTolerance.toString(),
            ",\n",
            '    "complianceImplementationRegistered": true\n',
            "  },\n"
        );
    }

    function _jsonTokenPolicies(TokenPolicy[] memory tokens) internal pure returns (string memory) {
        string memory items = "";
        for (uint256 i = 0; i < tokens.length; i++) {
            if (i > 0) items = string.concat(items, ",\n");
            items = string.concat(items, _jsonSingleToken(tokens[i]));
        }
        return string.concat('    "settlementTokens": [\n', items, "\n    ],\n");
    }

    function _jsonSingleToken(TokenPolicy memory t) internal pure returns (string memory) {
        return string.concat(
            "      {\n",
            '        "token": ',
            _qa(t.token),
            ",\n",
            _jsonSingleTokenPolicy(t),
            '        "rfqSettlementEnabled": ',
            _bs(t.rfqSettlementEnabled),
            "\n",
            "      }"
        );
    }

    function _jsonSingleTokenPolicy(TokenPolicy memory t) internal pure returns (string memory) {
        return string.concat(
            '        "bondIssuancePolicy": {\n',
            '          "issuanceEnabled": ',
            _bs(t.issuanceEnabled),
            ",\n",
            '          "settlementEnabled": ',
            _bs(t.settlementEnabled),
            ",\n",
            '          "redemptionEnabled": ',
            _bs(t.redemptionEnabled),
            "\n",
            "        },\n"
        );
    }

    function _jsonFeeConfig(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '    "feeConfig": {\n',
            '      "feeRecipient": ',
            _qa(cfg.feeRecipient),
            ",\n",
            '      "currentFeeBps": ',
            uint256(cfg.currentFeeBps).toString(),
            ",\n",
            '      "maxFeeBps": ',
            uint256(cfg.maxFeeBps).toString(),
            "\n",
            "    },\n"
        );
    }

    function _jsonRoles(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '  "roles": {\n',
            _jsonFactoryRolesOut(cfg),
            _jsonIssuanceRolesOut(cfg),
            _jsonSettlementRolesOut(cfg),
            "  },\n"
        );
    }

    function _jsonFactoryRolesOut(DeployConfig memory cfg) internal pure returns (string memory) {
        string memory adminNote = cfg.platformAdmin != cfg.factoryAdmin
            ? string.concat(
                '      "DEFAULT_ADMIN_ROLE_NOTE": "platformAdmin ',
                vm.toString(cfg.platformAdmin),
                ' also holds DEFAULT_ADMIN_ROLE via setPlatformAdmin side-effect",\n'
            )
            : "";
        return string.concat(
            '    "bondFactory": {\n',
            '      "DEFAULT_ADMIN_ROLE": ',
            _qa(cfg.factoryAdmin),
            ",\n",
            adminNote,
            '      "ISSUANCE_APPROVER_ROLE": ',
            _qa(cfg.factoryIssuanceApprover),
            ",\n",
            '      "COMPLIANCE_ADMIN_ROLE": ',
            _qa(cfg.factoryComplianceAdmin),
            ",\n",
            '      "PAUSER_ROLE": ',
            _qa(cfg.factoryPauser),
            "\n",
            "    },\n"
        );
    }

    function _jsonIssuanceRolesOut(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '    "bondIssuance": {\n',
            '      "DEFAULT_ADMIN_ROLE": ',
            _qa(cfg.issuanceAdmin),
            ",\n",
            '      "ISSUANCE_APPROVER_ROLE": ',
            _qa(cfg.issuanceIssuanceApprover),
            ",\n",
            '      "SETTLEMENT_ADMIN_ROLE": ',
            _qa(cfg.issuanceSettlementAdmin),
            ",\n",
            '      "PAUSER_ROLE": ',
            _qa(cfg.issuancePauser),
            ",\n",
            '      "UPGRADER_ROLE": ',
            _qa(cfg.issuanceUpgrader),
            "\n",
            "    },\n"
        );
    }

    function _jsonSettlementRolesOut(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '    "rfqSettlement": {\n',
            '      "DEFAULT_ADMIN_ROLE": ',
            _qa(cfg.rfqAdmin),
            ",\n",
            '      "SETTLEMENT_ADMIN_ROLE": ',
            _qa(cfg.rfqSettlementAdmin),
            ",\n",
            '      "PAUSER_ROLE": ',
            _qa(cfg.rfqPauser),
            ",\n",
            '      "UPGRADER_ROLE": ',
            _qa(cfg.rfqUpgrader),
            "\n",
            "    }\n"
        );
    }

    function _jsonHandoff(DeployConfig memory cfg) internal pure returns (string memory) {
        return string.concat(
            '  "handoff": {\n',
            '    "deployerRolesRevoked": ',
            _bs(cfg.revokeDeployer),
            ",\n",
            '    "deployer": ',
            _qa(cfg.deployer),
            "\n",
            "  }\n"
        );
    }

    // ─── 字符串工具 ──────────────────────────────────────────────

    function _qa(address a) internal pure returns (string memory) {
        return string.concat('"', vm.toString(a), '"');
    }

    function _bs(bool v) internal pure returns (string memory) {
        return v ? "true" : "false";
    }
}
