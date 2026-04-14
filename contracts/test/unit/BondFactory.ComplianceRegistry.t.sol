// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {BondFactory} from "../../src/BondFactory.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";

contract BondFactoryComplianceRegistryTest is Test {
    event ComplianceImplementationRegistered(
        address indexed implementation, address indexed registrar, bytes4 interfaceId, bool enabled
    );

    address internal admin = makeAddr("admin");
    address internal other = makeAddr("other");
    BondFactory internal factory;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, makeAddr("issuanceController"));
    }

    function test_registerComplianceImplementationStoresApproval() public {
        vm.expectEmit(true, true, false, true);
        emit ComplianceImplementationRegistered(
            address(complianceImplementation), admin, type(IComplianceModule).interfaceId, true
        );
        vm.prank(admin);
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);

        assertTrue(factory.isComplianceImplementationApproved(address(complianceImplementation)));
    }

    function test_disableComplianceImplementationClearsApproval() public {
        vm.startPrank(admin);
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);
        factory.disableComplianceImplementation(address(complianceImplementation));
        vm.stopPrank();

        assertFalse(factory.isComplianceImplementationApproved(address(complianceImplementation)));
    }

    function test_revertWhenNonAdminRegistersImplementation() public {
        vm.prank(other);
        vm.expectRevert();
        factory.registerComplianceImplementation(address(complianceImplementation), type(IComplianceModule).interfaceId);
    }
}
