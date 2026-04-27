// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { ComplianceModule } from "../../src/compliance/ComplianceModule.sol";
import { PauseDomain, Role } from "../../src/types/BondTypes.sol";

contract ComplianceModulePolicyAdminTest is Test {
    event WhitelistUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        bool allowed,
        address operator
    );

    event RoleUpdated(
        address indexed bondToken,
        address indexed account,
        address indexed complianceModule,
        Role role,
        address operator
    );

    event PolicyMetadataUpdated(
        address indexed bondToken, address indexed complianceModule, bytes32 policyId, uint256 policyVersion
    );

    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal bondTokenAddress = makeAddr("bondToken");
    address internal account = makeAddr("account");

    ComplianceModule internal implementation;
    ComplianceModule internal module;

    function setUp() public {
        implementation = new ComplianceModule();
        module = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(ComplianceModule.initialize, (admin, factory, keccak256("policy"), 1))
                )
            )
        );

        vm.prank(factory);
        module.bindBondToken(bondTokenAddress);

        // AUDIT-FIX(N11) revisited: ComplianceModule.initialize now grants only DEFAULT_ADMIN_ROLE
        // to admin. Self-grant the operational secondary roles this test exercises.
        vm.startPrank(admin);
        module.grantRole(keccak256("COMPLIANCE_ADMIN_ROLE"), admin);
        module.grantRole(keccak256("PAUSER_ROLE"), admin);
        vm.stopPrank();
    }

    function test_adminCanManageWhitelistAndRole() public {
        vm.expectEmit(true, true, true, true);
        emit WhitelistUpdated(bondTokenAddress, account, address(module), true, admin);
        vm.prank(admin);
        module.setWhitelist(account, true);

        vm.expectEmit(true, true, true, true);
        emit RoleUpdated(bondTokenAddress, account, address(module), Role.MARKET_MAKER, admin);
        vm.prank(admin);
        module.setRole(account, Role.MARKET_MAKER);

        assertTrue(module.isWhitelisted(account));
        assertEq(uint8(module.roleOf(account)), uint8(Role.MARKET_MAKER));
    }

    function test_adminCanUpdatePolicyMetadataAndPause() public {
        vm.expectEmit(true, true, false, true);
        emit PolicyMetadataUpdated(bondTokenAddress, address(module), keccak256("updated-policy"), 2);
        vm.prank(admin);
        module.setPolicyMetadata(keccak256("updated-policy"), 2);

        vm.prank(admin);
        module.pauseDomain(PauseDomain.COMPLIANCE_ADMIN, true);

        assertEq(module.policyId(), keccak256("updated-policy"));
        assertEq(module.policyVersion(), 2);
        assertTrue(module.isDomainPaused(PauseDomain.COMPLIANCE_ADMIN));
    }

    function test_revertWhenUnauthorizedAccountChangesPolicy() public {
        vm.prank(account);
        vm.expectRevert();
        module.setWhitelist(account, true);

        vm.prank(account);
        vm.expectRevert();
        module.pauseDomain(PauseDomain.COMPLIANCE_ADMIN, true);
    }

    function test_revertWhenSetWhitelistWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        module.setWhitelist(address(0), true);
    }

    function test_revertWhenSetRoleWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        module.setRole(address(0), Role.MARKET_MAKER);
    }

    function test_revertWhenComplianceAdminDomainPaused() public {
        vm.prank(admin);
        module.pauseDomain(PauseDomain.COMPLIANCE_ADMIN, true);

        vm.prank(admin);
        vm.expectRevert();
        module.setWhitelist(account, true);

        vm.prank(admin);
        vm.expectRevert();
        module.setRole(account, Role.MARKET_MAKER);
    }

    function test_checkTransferEnforcesWhitelistAndDirection() public {
        address maker = makeAddr("maker");
        address investor = makeAddr("investor");
        address operator = makeAddr("operator");

        vm.startPrank(admin);
        module.setWhitelist(maker, true);
        module.setWhitelist(investor, true);
        module.setRole(maker, Role.MARKET_MAKER);
        module.setRole(investor, Role.INVESTOR);
        module.setTransferOperator(operator, true);
        vm.stopPrank();

        assertEq(module.checkTransfer(maker, investor, 1e18, operator), 0);
        assertNotEq(module.checkTransfer(investor, investor, 1e18, operator), 0);
        assertEq(module.checkTransfer(maker, investor, 1e18, maker), 8);
    }
}
