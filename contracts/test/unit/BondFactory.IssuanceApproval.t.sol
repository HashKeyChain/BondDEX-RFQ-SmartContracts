// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondFactory} from "../../src/BondFactory.sol";
import {BondIssuance} from "../../src/BondIssuance.sol";
import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {ApprovalStatus, BondConfig} from "../../src/types/BondTypes.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";

contract BondFactoryIssuanceApprovalTest is Test {
    event IssuanceApproved(
        bytes32 indexed approvalId,
        address indexed issuer,
        address approver,
        uint256 expiresAt,
        address complianceImplementation,
        bytes32 metadataHash
    );

    event IssuanceRevoked(
        bytes32 indexed approvalId,
        address indexed issuer,
        address revoker
    );

    event BondCreated(
        address indexed bondToken,
        address indexed issuer,
        address indexed complianceModule,
        string name,
        string symbol,
        uint8 decimals,
        uint256 faceValue,
        uint256 couponRateBps,
        uint256 maturityTimestamp,
        address settlementToken
    );

    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal stablecoin = makeAddr("stablecoin");
    bytes32 internal approvalId = keccak256("approval");
    bytes32 internal metadataHash = keccak256("metadata");

    BondFactory internal factory;
    BondIssuance internal issuance;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        BondIssuance issuanceImplementation = new BondIssuance();
        issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(issuanceImplementation),
                    abi.encodeCall(BondIssuance.initialize, (admin))
                )
            )
        );
        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));
    }

    function test_approveIssuanceStoresActiveApproval() public {
        vm.prank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );

        vm.expectEmit(true, true, false, true);
        emit IssuanceApproved(
            approvalId,
            issuer,
            admin,
            block.timestamp + 1 days,
            address(complianceImplementation),
            metadataHash
        );
        vm.prank(admin);
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );

        (
            address approvedIssuer,
            address implementation,
            ApprovalStatus status,
            uint256 expiresAt,
            bytes32 hash
        ) = factory.getIssuanceApproval(approvalId);

        assertEq(approvedIssuer, issuer);
        assertEq(implementation, address(complianceImplementation));
        assertEq(uint8(status), uint8(ApprovalStatus.ACTIVE));
        assertEq(expiresAt, block.timestamp + 1 days);
        assertEq(hash, metadataHash);
    }

    function test_revokeIssuanceMarksApprovalRevoked() public {
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
            metadataHash
        );
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit IssuanceRevoked(approvalId, issuer, admin);
        vm.prank(admin);
        factory.revokeIssuance(approvalId);

        (, , ApprovalStatus status, , ) = factory.getIssuanceApproval(
            approvalId
        );
        assertEq(uint8(status), uint8(ApprovalStatus.REVOKED));
    }

    function test_createBondConsumesApprovalAndStoresAddresses() public {
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
            metadataHash
        );
        vm.stopPrank();

        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Bond",
            symbol: "HKB",
            decimals: 18,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: block.timestamp + 30 days,
            settlementToken: stablecoin,
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1
        });

        vm.expectEmit(false, true, false, true);
        emit BondCreated(
            address(0),
            issuer,
            address(0),
            "HashKey Bond",
            "HKB",
            18,
            1_000e6,
            500,
            block.timestamp + 30 days,
            stablecoin
        );
        vm.prank(issuer);
        (address bondTokenAddress, address complianceAddress) = factory
            .createBond(config, approvalId);

        BondToken bondToken = BondToken(bondTokenAddress);
        ComplianceModule complianceModule = ComplianceModule(complianceAddress);

        assertEq(bondToken.issuer(), issuer);
        assertEq(bondToken.settlementToken(), stablecoin);
        assertEq(bondToken.complianceModule(), complianceAddress);
        assertEq(complianceModule.bondToken(), bondTokenAddress);

        (, , ApprovalStatus status, , ) = factory.getIssuanceApproval(
            approvalId
        );
        assertEq(uint8(status), uint8(ApprovalStatus.CONSUMED));
    }

    function test_revertWhenCreateBondUsesRevokedApproval() public {
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
            metadataHash
        );
        factory.revokeIssuance(approvalId);
        vm.stopPrank();

        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Bond",
            symbol: "HKB",
            decimals: 18,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: block.timestamp + 30 days,
            settlementToken: stablecoin,
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1
        });

        vm.prank(issuer);
        vm.expectRevert();
        factory.createBond(config, approvalId);
    }
}
