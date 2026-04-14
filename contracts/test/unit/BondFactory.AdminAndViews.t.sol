// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondFactory} from "../../src/BondFactory.sol";
import {BondIssuance} from "../../src/BondIssuance.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {
    BondConfig,
    BondCategory,
    CouponFrequency,
    DayCount,
    PauseDomain
} from "../../src/types/BondTypes.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

contract BondFactoryAdminAndViewsTest is Test {
    event PlatformAdminUpdated(
        address indexed previousAdmin,
        address indexed newAdmin,
        address indexed operator
    );
    event PauseDomainUpdated(
        PauseDomain indexed domain,
        bool paused,
        address indexed operator
    );

    address internal admin = makeAddr("admin");
    address internal newAdmin = makeAddr("newAdmin");
    address internal issuer = makeAddr("issuer");
    address internal outsider = makeAddr("outsider");
    address internal stablecoin;
    bytes32 internal approvalId = keccak256("approval-adm");

    BondFactory internal factory;
    BondIssuance internal issuance;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        stablecoin = address(new MockERC20Decimals("USDC", "USDC", 6));

        BondIssuance impl = new BondIssuance();
        issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BondIssuance.initialize, (admin))
                )
            )
        );
        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));
    }

    // ── pauseDomain ───────────────────────────────────────────────

    function test_pauserCanPauseFactoryDomain() public {
        vm.prank(admin);
        factory.pauseDomain(PauseDomain.FACTORY, true);
        assertTrue(factory.isDomainPaused(PauseDomain.FACTORY));
    }

    function test_revertWhenNonPauserPausesFactory() public {
        vm.prank(outsider);
        vm.expectRevert();
        factory.pauseDomain(PauseDomain.FACTORY, true);
    }

    function test_revertWhenCreateBondWhileFactoryPaused() public {
        vm.startPrank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            keccak256("meta")
        );
        factory.pauseDomain(PauseDomain.FACTORY, true);
        vm.stopPrank();

        BondConfig memory config = _defaultConfig();
        vm.prank(issuer);
        vm.expectRevert();
        factory.createBond(config, approvalId);
    }

    // ── setPlatformAdmin ──────────────────────────────────────────

    function test_setPlatformAdminUpdatesState() public {
        vm.prank(admin);
        factory.setPlatformAdmin(newAdmin);
        assertEq(factory.platformAdmin(), newAdmin);
        assertTrue(factory.hasRole(0x00, newAdmin));
    }

    function test_revertWhenNonAdminSetsPlatformAdmin() public {
        vm.prank(outsider);
        vm.expectRevert();
        factory.setPlatformAdmin(newAdmin);
    }

    function test_revertWhenSetPlatformAdminToZero() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.setPlatformAdmin(address(0));
    }

    // ── getBondAddresses ──────────────────────────────────────────

    function test_getBondAddressesReturnsZeroBeforeCreation() public view {
        (address bt, address cm) = factory.getBondAddresses(
            keccak256("nonexistent")
        );
        assertEq(bt, address(0));
        assertEq(cm, address(0));
    }

    function test_getBondAddressesReturnsCorrectAfterCreation() public {
        vm.startPrank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            keccak256("meta")
        );
        vm.stopPrank();

        BondConfig memory config = _defaultConfig();
        vm.prank(issuer);
        (address bt, address cm) = factory.createBond(config, approvalId);

        (address storedBt, address storedCm) = factory.getBondAddresses(
            approvalId
        );
        assertEq(storedBt, bt);
        assertEq(storedCm, cm);
        assertTrue(bt != address(0));
        assertTrue(cm != address(0));
    }

    // ── settlementTokenDecimals mismatch ─────────────────────────

    function test_revertWhenSettlementTokenDecimalsMismatch() public {
        vm.startPrank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            keccak256("meta")
        );
        vm.stopPrank();

        BondConfig memory config = _defaultConfig();
        config.settlementTokenDecimals = 18;

        vm.prank(issuer);
        vm.expectRevert();
        factory.createBond(config, approvalId);
    }

    // ── helper ────────────────────────────────────────────────────

    function _defaultConfig() internal view returns (BondConfig memory) {
        return
            BondConfig({
                issuer: issuer,
                name: "Test Bond",
                symbol: "TB",
                decimals: 0,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 365 days,
                settlementToken: stablecoin,
                settlementTokenDecimals: 6,
                complianceImplementation: address(complianceImplementation),
                policyId: keccak256("policy"),
                policyVersion: 1,
                issueDate: block.timestamp + 1 days,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            });
    }
}
