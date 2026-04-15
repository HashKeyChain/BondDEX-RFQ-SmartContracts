// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { BondFactory } from "../../src/BondFactory.sol";
import { BondIssuance } from "../../src/BondIssuance.sol";
import { RFQSettlement } from "../../src/RFQSettlement.sol";
import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";

contract DeploymentAndSafeHandoffForkTest is Test {
    bytes32 internal constant ISSUANCE_APPROVER_ROLE = keccak256("ISSUANCE_APPROVER_ROLE");
    bytes32 internal constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 internal constant SETTLEMENT_ADMIN_ROLE = keccak256("SETTLEMENT_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    address internal safeAdmin = makeAddr("safeAdmin");

    function test_deploymentAndSafeHandoffOnFork() public {
        string memory rpcUrl = vm.envOr("HSK_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        uint256 forkBlock = vm.envOr("HSK_TESTNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        assertEq(block.chainid, 133);

        ComplianceModule complianceImplementation = new ComplianceModule();
        BondIssuance issuanceImplementation = new BondIssuance();
        BondIssuance issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(issuanceImplementation), abi.encodeCall(BondIssuance.initialize, (address(this)))
                )
            )
        );
        RFQSettlement settlementImplementation = new RFQSettlement();
        RFQSettlement settlement = RFQSettlement(
            address(
                new ERC1967Proxy(
                    address(settlementImplementation), abi.encodeCall(RFQSettlement.initialize, (address(this), 1_000))
                )
            )
        );
        BondFactory factory = new BondFactory(address(this), address(issuance));

        factory.grantRole(0x00, safeAdmin);
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

        factory.renounceRole(ISSUANCE_APPROVER_ROLE, address(this));
        factory.renounceRole(COMPLIANCE_ADMIN_ROLE, address(this));
        factory.renounceRole(PAUSER_ROLE, address(this));

        issuance.renounceRole(SETTLEMENT_ADMIN_ROLE, address(this));
        issuance.renounceRole(PAUSER_ROLE, address(this));
        issuance.renounceRole(UPGRADER_ROLE, address(this));

        settlement.renounceRole(SETTLEMENT_ADMIN_ROLE, address(this));
        settlement.renounceRole(PAUSER_ROLE, address(this));
        settlement.renounceRole(UPGRADER_ROLE, address(this));

        assertTrue(factory.hasRole(0x00, safeAdmin));
        assertTrue(factory.hasRole(ISSUANCE_APPROVER_ROLE, safeAdmin));
        assertTrue(issuance.hasRole(SETTLEMENT_ADMIN_ROLE, safeAdmin));
        assertTrue(issuance.hasRole(UPGRADER_ROLE, safeAdmin));
        assertTrue(settlement.hasRole(SETTLEMENT_ADMIN_ROLE, safeAdmin));
        assertTrue(settlement.hasRole(UPGRADER_ROLE, safeAdmin));

        assertFalse(factory.hasRole(ISSUANCE_APPROVER_ROLE, address(this)));
        assertFalse(issuance.hasRole(SETTLEMENT_ADMIN_ROLE, address(this)));
        assertFalse(settlement.hasRole(SETTLEMENT_ADMIN_ROLE, address(this)));

        assertEq(factory.issuanceController(), address(issuance));
        assertEq(address(complianceImplementation) != address(0), true);
    }
}
