// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../test/mocks/MockERC20Decimals.sol";
import {BaseDeploy} from "./BaseDeploy.s.sol";

contract DeployAnvil is BaseDeploy {
    /// @dev Deploys the local Anvil stack with a mock stablecoin for smoke testing.
    function run() external returns (DeploymentRecord memory record) {
        uint256 deployerPrivateKey =
            vm.envOr(_deployerKeyEnvKey(0), uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.envOr(_safeAdminEnvKey(0), deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockERC20Decimals settlementToken = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
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
            chainId: 31_337,
            bondFactory: address(factory),
            bondIssuance: address(issuance),
            rfqSettlement: address(settlement),
            complianceImplementation: address(complianceImplementation),
            bondIssuanceImplementation: address(issuanceImplementation),
            rfqSettlementImplementation: address(rfqImplementation),
            settlementToken: address(settlementToken),
            deployer: deployer,
            safeAdmin: safeAdmin
        });

        console2.log("Anvil settlement token:", address(settlementToken));
        console2.log("Anvil BondFactory:", address(factory));
        console2.log("Anvil BondIssuance proxy:", address(issuance));
        console2.log("Anvil RFQSettlement proxy:", address(settlement));
    }
}
