// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {BaseConfig} from "./BaseConfig.s.sol";

contract ExportAbi is BaseConfig {
    string[] internal contractNames = [
        "BondFactory",
        "BondToken",
        "BondIssuance",
        "RFQSettlement",
        "ComplianceModule"
    ];

    /// @dev Exports ABI JSON files and writes release metadata for downstream consumers.
    function run() external {
        string memory root = vm.projectRoot();
        string memory outRoot = string.concat(root, "/out/");
        string memory abiRoot = string.concat(root, "/", ABI_EXPORT_ROOT, "/abi/");
        string memory metadataPath = string.concat(root, "/", ABI_EXPORT_ROOT, "/metadata/metadata.json");

        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            string memory artifactPath = string.concat(outRoot, name, ".sol/", name, ".json");
            string[] memory command = new string[](3);
            command[0] = "bash";
            command[1] = "-lc";
            command[2] = string.concat("jq '.abi' \"", artifactPath, "\"");
            string memory abiJson = string(vm.ffi(command));
            vm.writeFile(string.concat(abiRoot, name, ".abi.json"), abiJson);
            console2.log("Exported ABI for", name);
        }

        vm.writeFile(metadataPath, _metadataJson());
        console2.log("Release metadata target:", metadataPath);
    }

    function _metadataJson() internal view returns (string memory) {
        return string.concat(
            "{\n",
            "  \"version\": \"",
            RELEASE_VERSION,
            "\",\n",
            "  \"contractCommit\": \"UNSET_COMMIT\",\n",
            "  \"exportedAt\": \"",
            vm.toString(block.timestamp),
            "\",\n",
            "  \"contracts\": [\n",
            "    \"BondFactory\",\n",
            "    \"BondToken\",\n",
            "    \"BondIssuance\",\n",
            "    \"RFQSettlement\",\n",
            "    \"ComplianceModule\"\n",
            "  ],\n",
            "  \"networks\": {\n",
            "    \"133\": \"../addresses/133.json\",\n",
            "    \"177\": \"../addresses/177.json\"\n",
            "  },\n",
            "  \"eventInterface\": \"event-interface.md\",\n",
            "  \"notes\": \"Update contractCommit and production addresses after promotion.\"\n",
            "}\n"
        );
    }
}
