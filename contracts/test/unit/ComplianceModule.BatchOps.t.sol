// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {Role} from "../../src/types/BondTypes.sol";

contract ComplianceModuleBatchOpsTest is Test {
    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal outsider = makeAddr("outsider");

    ComplianceModule internal module;

    function setUp() public {
        ComplianceModule impl = new ComplianceModule();
        module = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        ComplianceModule.initialize,
                        (admin, factory, keccak256("pol"), 1)
                    )
                )
            )
        );

        vm.prank(factory);
        module.bindBondToken(makeAddr("bondToken"));
    }

    // ── batchSetWhitelist ─────────────────────────────────────────

    function test_batchSetWhitelistUpdatesMultipleAccounts() public {
        address[] memory accounts = new address[](3);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        accounts[2] = makeAddr("c");

        bool[] memory flags = new bool[](3);
        flags[0] = true;
        flags[1] = true;
        flags[2] = false;

        vm.prank(admin);
        module.batchSetWhitelist(accounts, flags);

        assertTrue(module.isWhitelisted(accounts[0]));
        assertTrue(module.isWhitelisted(accounts[1]));
        assertFalse(module.isWhitelisted(accounts[2]));
    }

    function test_revertWhenBatchWhitelistLengthMismatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetWhitelist(accounts, flags);
    }

    function test_revertWhenBatchWhitelistEmpty() public {
        address[] memory accounts = new address[](0);
        bool[] memory flags = new bool[](0);

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetWhitelist(accounts, flags);
    }

    function test_revertWhenBatchWhitelistExceedsCap() public {
        address[] memory accounts = new address[](201);
        bool[] memory flags = new bool[](201);
        for (uint256 i = 0; i < 201; i++) {
            accounts[i] = address(uint160(i + 1));
            flags[i] = true;
        }

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetWhitelist(accounts, flags);
    }

    function test_revertWhenNonAdminCallsBatchWhitelist() public {
        address[] memory accounts = new address[](1);
        accounts[0] = makeAddr("a");
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(outsider);
        vm.expectRevert();
        module.batchSetWhitelist(accounts, flags);
    }

    // ── batchSetRole ──────────────────────────────────────────────

    function test_batchSetRoleUpdatesMultipleAccounts() public {
        address[] memory accounts = new address[](3);
        accounts[0] = makeAddr("mm1");
        accounts[1] = makeAddr("mm2");
        accounts[2] = makeAddr("inv1");

        Role[] memory roles = new Role[](3);
        roles[0] = Role.MARKET_MAKER;
        roles[1] = Role.MARKET_MAKER;
        roles[2] = Role.INVESTOR;

        vm.prank(admin);
        module.batchSetRole(accounts, roles);

        assertEq(uint8(module.roleOf(accounts[0])), uint8(Role.MARKET_MAKER));
        assertEq(uint8(module.roleOf(accounts[1])), uint8(Role.MARKET_MAKER));
        assertEq(uint8(module.roleOf(accounts[2])), uint8(Role.INVESTOR));
    }

    function test_revertWhenBatchRoleLengthMismatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        Role[] memory roles = new Role[](1);
        roles[0] = Role.MARKET_MAKER;

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetRole(accounts, roles);
    }

    function test_revertWhenBatchRoleEmpty() public {
        address[] memory accounts = new address[](0);
        Role[] memory roles = new Role[](0);

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetRole(accounts, roles);
    }

    function test_revertWhenBatchRoleExceedsCap() public {
        address[] memory accounts = new address[](201);
        Role[] memory roles = new Role[](201);
        for (uint256 i = 0; i < 201; i++) {
            accounts[i] = address(uint160(i + 1));
            roles[i] = Role.INVESTOR;
        }

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetRole(accounts, roles);
    }

    function test_revertWhenNonAdminCallsBatchRole() public {
        address[] memory accounts = new address[](1);
        accounts[0] = makeAddr("a");
        Role[] memory roles = new Role[](1);
        roles[0] = Role.MARKET_MAKER;

        vm.prank(outsider);
        vm.expectRevert();
        module.batchSetRole(accounts, roles);
    }

    function test_revertWhenBatchRoleContainsZeroAddress() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = address(0);
        Role[] memory roles = new Role[](2);
        roles[0] = Role.MARKET_MAKER;
        roles[1] = Role.INVESTOR;

        vm.prank(admin);
        vm.expectRevert();
        module.batchSetRole(accounts, roles);
    }
}
