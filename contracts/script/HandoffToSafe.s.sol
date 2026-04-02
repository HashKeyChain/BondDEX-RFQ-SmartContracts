// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {BaseConfig} from "./BaseConfig.s.sol";

contract HandoffToSafe is BaseConfig {
    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE = keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev Grants Safe roles first and optionally renounces caller privileges for handoff.
    function run() external {
        uint256 chainId = block.chainid;
        uint256 deployerPrivateKey = vm.envUint(_deployerKeyEnvKey(chainId));
        address deployer = vm.addr(deployerPrivateKey);
        address safeAdmin = vm.envAddress(_safeAdminEnvKey(chainId));
        bool revokeCaller = vm.envOr("REVOKE_CALLER_ROLES", false);

        BondFactory factory = BondFactory(vm.envAddress("BOND_FACTORY"));
        BondIssuance issuance = BondIssuance(vm.envAddress("BOND_ISSUANCE"));
        RFQSettlement settlement = RFQSettlement(vm.envAddress("RFQ_SETTLEMENT"));

        vm.startBroadcast(deployerPrivateKey);

        factory.grantRole(0x00, safeAdmin);
        issuance.grantRole(0x00, safeAdmin);
        settlement.grantRole(0x00, safeAdmin);

        if (revokeCaller) {
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

        vm.stopBroadcast();

        console2.log("Safe handoff prepared for", safeAdmin);
        console2.log("Caller role revocation enabled:", revokeCaller);
    }
}
