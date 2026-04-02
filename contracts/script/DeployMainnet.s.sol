// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {BaseDeploy} from "./BaseDeploy.s.sol";

contract DeployMainnet is BaseDeploy {
    /// @dev Prepares the mainnet deployment transaction path and writes `deployments/177.json`.
    function run() external returns (DeploymentRecord memory record) {
        uint256 deployerPrivateKey = vm.envUint(_deployerKeyEnvKey(HSK_MAINNET_CHAIN_ID));
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.envAddress(_safeAdminEnvKey(HSK_MAINNET_CHAIN_ID));
        address settlementToken = vm.envAddress(_settlementTokenEnvKey(HSK_MAINNET_CHAIN_ID));

        vm.startBroadcast(deployerPrivateKey);

        ComplianceModule complianceImplementation = new ComplianceModule();
        BondIssuance issuanceImplementation = new BondIssuance();
        BondIssuance issuance = BondIssuance(
            address(new ERC1967Proxy(address(issuanceImplementation), abi.encodeCall(BondIssuance.initialize, (deployer))))
        );
        RFQSettlement rfqImplementation = new RFQSettlement();
        RFQSettlement settlement = RFQSettlement(
            address(new ERC1967Proxy(address(rfqImplementation), abi.encodeCall(RFQSettlement.initialize, (deployer))))
        );
        BondFactory factory = new BondFactory(deployer, address(issuance));

        vm.stopBroadcast();

        record = DeploymentRecord({
            chainId: HSK_MAINNET_CHAIN_ID,
            bondFactory: address(factory),
            bondIssuance: address(issuance),
            rfqSettlement: address(settlement),
            complianceImplementation: address(complianceImplementation),
            bondIssuanceImplementation: address(issuanceImplementation),
            rfqSettlementImplementation: address(rfqImplementation),
            settlementToken: settlementToken,
            deployer: deployer,
            safeAdmin: safeAdmin
        });

        _writeDeploymentRecord(record);

        console2.log("Mainnet manifest updated at", _deploymentFile(HSK_MAINNET_CHAIN_ID));
        console2.log("Use Safe to execute and verify the generated deployment flow.");
        console2.log("BondFactory:", address(factory));
        console2.log("BondIssuance proxy:", address(issuance));
        console2.log("RFQSettlement proxy:", address(settlement));
    }
}
