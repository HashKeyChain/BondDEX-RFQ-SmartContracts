// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondFactory} from "../../src/BondFactory.sol";
import {BondIssuance} from "../../src/BondIssuance.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {ApprovalStatus, BondConfig} from "../../src/types/BondTypes.sol";
import {
    InvalidApprovalState,
    InvalidBondConfig
} from "../../src/libraries/BondErrors.sol";

contract BondFactoryApprovalGuardsTest is Test {
    address internal admin = makeAddr("admin");
    address internal issuer = makeAddr("issuer");
    address internal stablecoin = makeAddr("stablecoin");
    bytes32 internal approvalId = keccak256("approval");
    bytes32 internal metadataHash = keccak256("metadata");

    BondFactory internal factory;
    BondIssuance internal issuance;
    ComplianceModule internal complianceImplementation;

    function setUp() public {
        BondIssuance issuanceImpl = new BondIssuance();
        issuance = BondIssuance(
            address(
                new ERC1967Proxy(
                    address(issuanceImpl),
                    abi.encodeCall(BondIssuance.initialize, (admin))
                )
            )
        );
        complianceImplementation = new ComplianceModule();
        factory = new BondFactory(admin, address(issuance));

        vm.startPrank(admin);
        factory.registerComplianceImplementation(
            address(complianceImplementation),
            type(IComplianceModule).interfaceId
        );
        vm.stopPrank();
    }

    // ─── approveIssuance CONSUMED 保护 ────────────────────────────

    function test_revertWhenApproveIssuanceOverwritesConsumedApproval() public {
        vm.startPrank(admin);
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );
        vm.stopPrank();

        BondConfig memory config = _defaultConfig();
        vm.prank(issuer);
        factory.createBond(config, approvalId);

        (, , ApprovalStatus status, , ) = factory.getIssuanceApproval(
            approvalId
        );
        assertEq(uint8(status), uint8(ApprovalStatus.CONSUMED));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidApprovalState.selector,
                ApprovalStatus.CONSUMED
            )
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 2 days,
            metadataHash
        );
    }

    function test_revertWhenApproveIssuanceOverwritesRevokedApproval() public {
        vm.startPrank(admin);
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );
        factory.revokeIssuance(approvalId);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidApprovalState.selector,
                ApprovalStatus.REVOKED
            )
        );
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 2 days,
            metadataHash
        );
        vm.stopPrank();
    }

    // ─── revokeIssuance 状态校验 ─────────────────────────────────

    function test_revertWhenRevokeIssuanceOnConsumedApproval() public {
        vm.startPrank(admin);
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );
        vm.stopPrank();

        vm.prank(issuer);
        factory.createBond(_defaultConfig(), approvalId);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidApprovalState.selector,
                ApprovalStatus.CONSUMED
            )
        );
        factory.revokeIssuance(approvalId);
    }

    function test_revertWhenRevokeIssuanceOnAlreadyRevokedApproval() public {
        vm.startPrank(admin);
        factory.approveIssuance(
            approvalId,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );
        factory.revokeIssuance(approvalId);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidApprovalState.selector,
                ApprovalStatus.REVOKED
            )
        );
        factory.revokeIssuance(approvalId);
        vm.stopPrank();
    }

    function test_revertWhenRevokeIssuanceOnNonexistentApproval() public {
        bytes32 unknown = keccak256("unknown");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidApprovalState.selector,
                ApprovalStatus.NONE
            )
        );
        factory.revokeIssuance(unknown);
    }

    // ─── approveIssuance expiresAt 校验 ─────────────────────────

    function test_revertWhenApproveIssuanceWithPastExpiresAt() public {
        vm.warp(1000);
        vm.prank(admin);
        vm.expectRevert();
        factory.approveIssuance(
            keccak256("past-expires"),
            issuer,
            address(complianceImplementation),
            block.timestamp - 1,
            metadataHash
        );
    }

    // ─── markIssuanceExpired ─────────────────────────────────────

    function test_markIssuanceExpiredSucceeds() public {
        bytes32 aid = keccak256("expirable");
        vm.prank(admin);
        factory.approveIssuance(
            aid,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 hours,
            metadataHash
        );

        vm.warp(block.timestamp + 2 hours);

        factory.markIssuanceExpired(aid);

        (, , ApprovalStatus status, , ) = factory.getIssuanceApproval(aid);
        assertEq(uint8(status), uint8(ApprovalStatus.EXPIRED));
    }

    function test_revertWhenMarkExpiredOnNonexistentApproval() public {
        vm.expectRevert(
            abi.encodeWithSelector(InvalidApprovalState.selector, ApprovalStatus.NONE)
        );
        factory.markIssuanceExpired(keccak256("nonexistent"));
    }

    function test_revertWhenMarkExpiredOnNotYetExpiredApproval() public {
        bytes32 aid = keccak256("not-yet-expired");
        vm.prank(admin);
        factory.approveIssuance(
            aid, issuer, address(complianceImplementation), block.timestamp + 1 days, metadataHash
        );

        vm.expectRevert(
            abi.encodeWithSelector(InvalidApprovalState.selector, ApprovalStatus.ACTIVE)
        );
        factory.markIssuanceExpired(aid);
    }

    function test_revertWhenMarkExpiredOnNoExpiryApproval() public {
        bytes32 aid = keccak256("no-expiry");
        vm.prank(admin);
        factory.approveIssuance(
            aid, issuer, address(complianceImplementation), 0, metadataHash
        );

        vm.expectRevert(
            abi.encodeWithSelector(InvalidApprovalState.selector, ApprovalStatus.ACTIVE)
        );
        factory.markIssuanceExpired(aid);
    }

    function test_revertWhenMarkExpiredOnRevokedApproval() public {
        bytes32 aid = keccak256("revoked-mark");
        vm.startPrank(admin);
        factory.approveIssuance(
            aid, issuer, address(complianceImplementation), block.timestamp + 1 hours, metadataHash
        );
        factory.revokeIssuance(aid);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(InvalidApprovalState.selector, ApprovalStatus.REVOKED)
        );
        factory.markIssuanceExpired(aid);
    }

    // ─── createBond couponRateBps 校验 ─────────────────────────

    function test_revertWhenCreateBondWithExcessiveCouponRate() public {
        bytes32 aid = keccak256("excess-coupon");
        vm.prank(admin);
        factory.approveIssuance(
            aid, issuer, address(complianceImplementation), block.timestamp + 1 days, metadataHash
        );

        BondConfig memory config = _defaultConfig();
        config.couponRateBps = 10_001;
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidBondConfig.selector, "couponRateBps must be <= 10000")
        );
        factory.createBond(config, aid);
    }

    // ─── createBond 参数校验 ─────────────────────────────────────

    function test_revertWhenCreateBondWithZeroFaceValue() public {
        _approveAndExpectConfigRevert(
            0,
            block.timestamp + 30 days,
            18,
            "faceValue must be > 0"
        );
    }

    function test_revertWhenCreateBondWithPastMaturity() public {
        _approveAndExpectConfigRevert(
            1_000e6,
            block.timestamp - 1,
            18,
            "maturityTimestamp must be in the future"
        );
    }

    function test_revertWhenCreateBondWithExcessiveDecimals() public {
        _approveAndExpectConfigRevert(
            1_000e6,
            block.timestamp + 30 days,
            19,
            "decimals must be <= 18"
        );
    }

    // ─── helpers ─────────────────────────────────────────────────

    function _approveAndExpectConfigRevert(
        uint256 faceValue,
        uint256 maturityTimestamp,
        uint8 decimals_,
        string memory reason
    ) internal {
        bytes32 aid = keccak256(
            abi.encode(faceValue, maturityTimestamp, decimals_)
        );
        vm.prank(admin);
        factory.approveIssuance(
            aid,
            issuer,
            address(complianceImplementation),
            block.timestamp + 1 days,
            metadataHash
        );

        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HKB",
            symbol: "HKB",
            decimals: decimals_,
            faceValue: faceValue,
            couponRateBps: 500,
            maturityTimestamp: maturityTimestamp,
            settlementToken: stablecoin,
            settlementTokenDecimals: 6,
            complianceImplementation: address(complianceImplementation),
            policyId: keccak256("policy"),
            policyVersion: 1
        });

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidBondConfig.selector, reason)
        );
        factory.createBond(config, aid);
    }

    function _defaultConfig() internal view returns (BondConfig memory) {
        return
            BondConfig({
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
    }
}
