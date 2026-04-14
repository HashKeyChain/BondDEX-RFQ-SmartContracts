// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {BondToken} from "../../src/BondToken.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {
    BondCategory,
    CouponFrequency,
    DayCount,
    PauseDomain,
    Role
} from "../../src/types/BondTypes.sol";

contract MinimalComplianceMock is IComplianceModule {
    function setWhitelist(address, bool) external {}
    function batchSetWhitelist(address[] calldata, bool[] calldata) external {}
    function setRole(address, Role) external {}
    function batchSetRole(address[] calldata, Role[] calldata) external {}
    function setPolicyMetadata(bytes32, uint256) external {}
    function pauseDomain(PauseDomain, bool) external {}
    function isWhitelisted(address) external pure returns (bool) {
        return true;
    }
    function roleOf(address) external pure returns (Role) {
        return Role.MARKET_MAKER;
    }
    function isDomainPaused(PauseDomain) external pure returns (bool) {
        return false;
    }
    function checkTransfer(
        address,
        address,
        uint256,
        address
    ) external pure returns (uint8) {
        return 0;
    }
    function setTransferOperator(address, bool) external {}
    function isTransferOperator(address) external pure returns (bool) {
        return true;
    }
    function policyId() external pure returns (bytes32) {
        return bytes32(0);
    }
    function policyVersion() external pure returns (uint256) {
        return 1;
    }
}

contract BondTokenAccruedInterestAndMessagesTest is Test {
    BondToken internal bondToken;
    uint256 internal constant ISSUE_DATE_OFFSET = 10 days;
    uint256 internal constant MATURITY_OFFSET = 375 days;

    function setUp() public {
        MinimalComplianceMock compliance = new MinimalComplianceMock();
        bondToken = new BondToken(
            BondToken.ConstructorParams({
                issuer: makeAddr("issuer"),
                name: "Test Bond",
                symbol: "TB",
                decimals: 0,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + MATURITY_OFFSET,
                settlementToken: makeAddr("usdc"),
                complianceModule: address(compliance),
                issuanceController: makeAddr("issuance"),
                issueDate: block.timestamp + ISSUE_DATE_OFFSET,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
    }

    // ── accruedInterestPerUnit ────────────────────────────────────

    function test_accruedInterestReturnsZeroBeforeIssueDate() public view {
        uint256 ai = bondToken.accruedInterestPerUnit(block.timestamp);
        assertEq(ai, 0);
    }

    function test_accruedInterestReturnsZeroAtIssueDate() public view {
        uint256 ai = bondToken.accruedInterestPerUnit(bondToken.issueDate());
        assertEq(ai, 0);
    }

    function test_accruedInterestIncreasesOverTime() public {
        uint256 issueDate = bondToken.issueDate();
        vm.warp(issueDate + 30 days);
        uint256 ai30 = bondToken.accruedInterestPerUnit(block.timestamp);

        vm.warp(issueDate + 60 days);
        uint256 ai60 = bondToken.accruedInterestPerUnit(block.timestamp);

        assertTrue(ai30 > 0);
        assertTrue(ai60 > ai30);
    }

    function test_accruedInterestCapsAtMaturity() public {
        uint256 maturity = bondToken.maturityTimestamp();
        uint256 aiAtMaturity = bondToken.accruedInterestPerUnit(maturity);
        uint256 aiBeyond = bondToken.accruedInterestPerUnit(
            maturity + 365 days
        );

        assertEq(aiAtMaturity, aiBeyond);
    }

    function test_accruedInterestFullTermEqualsAnnualCoupon() public view {
        uint256 maturity = bondToken.maturityTimestamp();
        uint256 ai = bondToken.accruedInterestPerUnit(maturity);
        uint256 elapsed = maturity - bondToken.issueDate();
        uint256 expected = (1_000e6 * 500 * elapsed) / (10_000 * 365 days);
        assertEq(ai, expected);
    }

    // ── messageForTransferRestriction ─────────────────────────────

    function test_messageForCode0ReturnsSuccess() public view {
        assertEq(
            keccak256(bytes(bondToken.messageForTransferRestriction(0))),
            keccak256("SUCCESS")
        );
    }

    function test_messageForCode8ReturnsUnauthorizedOperator() public view {
        assertEq(
            keccak256(bytes(bondToken.messageForTransferRestriction(8))),
            keccak256("UNAUTHORIZED_OPERATOR")
        );
    }

    function test_messageForUnknownCodeReturnsUnknown() public view {
        assertEq(
            keccak256(bytes(bondToken.messageForTransferRestriction(99))),
            keccak256("UNKNOWN_RESTRICTION")
        );
    }

    function test_allKnownRestrictionCodesHaveMessages() public view {
        string[9] memory expected = [
            "SUCCESS",
            "BOND_TOKEN_NOT_BOUND",
            "SENDER_NOT_WHITELISTED",
            "RECEIVER_NOT_WHITELISTED",
            "INVALID_SENDER_ROLE",
            "INVALID_RECEIVER_ROLE",
            "INVALID_DIRECTION",
            "TRANSFERS_PAUSED",
            "UNAUTHORIZED_OPERATOR"
        ];
        for (uint8 i = 0; i < 9; i++) {
            assertEq(
                keccak256(bytes(bondToken.messageForTransferRestriction(i))),
                keccak256(bytes(expected[i]))
            );
        }
    }
}
