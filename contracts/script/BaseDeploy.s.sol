// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BaseConfig} from "./BaseConfig.s.sol";

abstract contract BaseDeploy is BaseConfig {
    using Strings for uint256;

    error UnsupportedChain(uint256 chainId);

    struct DeploymentRecord {
        uint256 chainId;
        address bondFactory;
        address bondIssuance;
        address rfqSettlement;
        address complianceImplementation;
        address bondIssuanceImplementation;
        address rfqSettlementImplementation;
        address settlementToken;
        address deployer;
        address safeAdmin;
    }

    function _assertSupportedChain() internal view {
        if (!_isSupportedChain(block.chainid)) {
            revert UnsupportedChain(block.chainid);
        }
    }

    function _deploymentFile(uint256 chainId) internal pure returns (string memory) {
        return string.concat(DEPLOYMENTS_ROOT, "/", chainId.toString(), ".json");
    }

    function _defaultRecord(address safeAdmin) internal view returns (DeploymentRecord memory) {
        return DeploymentRecord({
            chainId: block.chainid,
            bondFactory: address(0),
            bondIssuance: address(0),
            rfqSettlement: address(0),
            complianceImplementation: address(0),
            bondIssuanceImplementation: address(0),
            rfqSettlementImplementation: address(0),
            settlementToken: address(0),
            deployer: address(0),
            safeAdmin: safeAdmin
        });
    }

    function _addressOrNull(address account) internal pure returns (string memory) {
        if (account == address(0)) {
            return "null";
        }

        return string.concat("\"", vm.toString(account), "\"");
    }

    function _writeDeploymentRecord(DeploymentRecord memory record) internal {
        string memory json = string.concat(
            "{\n",
            "  \"version\": \"",
            RELEASE_VERSION,
            "\",\n",
            "  \"chainId\": ",
            record.chainId.toString(),
            ",\n",
            "  \"network\": \"",
            _networkLabel(record.chainId),
            "\",\n",
            "  \"deployer\": ",
            _addressOrNull(record.deployer),
            ",\n",
            "  \"safeAdmin\": ",
            _addressOrNull(record.safeAdmin),
            ",\n",
            "  \"settlementToken\": ",
            _addressOrNull(record.settlementToken),
            ",\n",
            "  \"contracts\": {\n",
            "    \"complianceImplementation\": ",
            _addressOrNull(record.complianceImplementation),
            ",\n",
            "    \"bondIssuanceImplementation\": ",
            _addressOrNull(record.bondIssuanceImplementation),
            ",\n",
            "    \"bondIssuance\": ",
            _addressOrNull(record.bondIssuance),
            ",\n",
            "    \"rfqSettlementImplementation\": ",
            _addressOrNull(record.rfqSettlementImplementation),
            ",\n",
            "    \"rfqSettlement\": ",
            _addressOrNull(record.rfqSettlement),
            ",\n",
            "    \"bondFactory\": ",
            _addressOrNull(record.bondFactory),
            "\n",
            "  },\n",
            "  \"handoff\": {\n",
            "    \"status\": \"pending\",\n",
            "    \"roleMatrixPath\": \"QUICKSTART.md\"\n",
            "  }\n",
            "}\n"
        );

        vm.writeFile(_deploymentFile(record.chainId), json);
    }
}
