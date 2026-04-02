// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {BaseConfig} from "./BaseConfig.s.sol";

contract ConfigureRoles is BaseConfig {
    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE = keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev Grants Safe-facing roles and configures supported settlement-token policies.
    function run() external {
        uint256 chainId = block.chainid;
        uint256 deployerPrivateKey = vm.envUint(_deployerKeyEnvKey(chainId));
        address safeAdmin = vm.envAddress(_safeAdminEnvKey(chainId));
        address settlementToken = vm.envAddress(_settlementTokenEnvKey(chainId));

        BondFactory factory = BondFactory(vm.envAddress("BOND_FACTORY"));
        BondIssuance issuance = BondIssuance(vm.envAddress("BOND_ISSUANCE"));
        RFQSettlement settlement = RFQSettlement(vm.envAddress("RFQ_SETTLEMENT"));

        vm.startBroadcast(deployerPrivateKey);

        factory.grantRole(0x00, safeAdmin);
        factory.grantRole(ISSUANCE_APPROVER_ROLE, safeAdmin);
        factory.grantRole(COMPLIANCE_ADMIN_ROLE, safeAdmin);
        factory.grantRole(PAUSER_ROLE, safeAdmin);

        issuance.grantRole(0x00, safeAdmin);
        issuance.grantRole(SETTLEMENT_ADMIN_ROLE, safeAdmin);
        issuance.grantRole(PAUSER_ROLE, safeAdmin);
        issuance.grantRole(UPGRADER_ROLE, safeAdmin);
        issuance.setSettlementTokenPolicy(settlementToken, true, false, true);

        settlement.grantRole(0x00, safeAdmin);
        settlement.grantRole(SETTLEMENT_ADMIN_ROLE, safeAdmin);
        settlement.grantRole(PAUSER_ROLE, safeAdmin);
        settlement.grantRole(UPGRADER_ROLE, safeAdmin);
        settlement.setSettlementTokenPolicy(settlementToken, true);

        vm.stopBroadcast();

        console2.log("Configured Safe roles for", safeAdmin);
        console2.log("Enabled settlement token", settlementToken);
    }
}
