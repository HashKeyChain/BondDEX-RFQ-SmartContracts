// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { BondToken } from "../../src/BondToken.sol";
import { IComplianceModule } from "../../src/interfaces/IComplianceModule.sol";
import { BondCategory, CouponFrequency, DayCount, PauseDomain, Role } from "../../src/types/BondTypes.sol";

contract StaticRestrictionComplianceMock is IComplianceModule {
    uint8 internal _restrictionCode;
    bytes32 internal _policyId;
    uint256 internal _policyVersion;

    function setRestrictionCode(uint8 restrictionCode) external {
        _restrictionCode = restrictionCode;
    }

    function setWhitelist(address, bool) external { }
    function batchSetWhitelist(address[] calldata, bool[] calldata) external { }
    function setRole(address, Role) external { }
    function batchSetRole(address[] calldata, Role[] calldata) external { }

    function setPolicyMetadata(bytes32 policyId_, uint256 policyVersion_) external {
        _policyId = policyId_;
        _policyVersion = policyVersion_;
    }
    function pauseDomain(PauseDomain, bool) external { }

    function isWhitelisted(address) external pure returns (bool) {
        return true;
    }

    function roleOf(address) external pure returns (Role) {
        return Role.MARKET_MAKER;
    }

    function isDomainPaused(PauseDomain) external pure returns (bool) {
        return false;
    }

    function checkTransfer(address, address, uint256, address) external view returns (uint8) {
        return _restrictionCode;
    }
    function setTransferOperator(address, bool) external { }

    function isTransferOperator(address) external pure returns (bool) {
        return true;
    }

    function policyId() external view returns (bytes32) {
        return _policyId;
    }

    function policyVersion() external view returns (uint256) {
        return _policyVersion;
    }
}

contract BondTokenMetadataAndMintBurnTest is Test {
    address internal issuer = makeAddr("issuer");
    address internal issuanceController = makeAddr("issuanceController");
    address internal stablecoin = makeAddr("stablecoin");
    address internal holder = makeAddr("holder");
    address internal receiver = makeAddr("receiver");

    StaticRestrictionComplianceMock internal complianceModule;
    BondToken internal bondToken;

    function setUp() public {
        complianceModule = new StaticRestrictionComplianceMock();
        bondToken = new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HashKey Bond",
                symbol: "HKB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: stablecoin,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
    }

    function test_revertWhenConstructedWithZeroFaceValue() public {
        vm.expectRevert();
        new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HKB",
                symbol: "HKB",
                decimals: 18,
                faceValue: 0,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: stablecoin,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
    }

    function test_revertWhenConstructedWithExcessiveCouponRate() public {
        vm.expectRevert();
        new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HKB",
                symbol: "HKB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 10_001,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: stablecoin,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
    }

    function test_revertWhenConstructedWithPastMaturity() public {
        vm.expectRevert();
        new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HKB",
                symbol: "HKB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp - 1,
                settlementToken: stablecoin,
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );
    }

    function test_metadataAndWiringAreImmutable() public view {
        assertEq(bondToken.name(), "HashKey Bond");
        assertEq(bondToken.symbol(), "HKB");
        assertEq(bondToken.decimals(), 18);
        assertEq(bondToken.issuer(), issuer);
        assertEq(bondToken.faceValue(), 1_000e6);
        assertEq(bondToken.couponRateBps(), 500);
        assertEq(bondToken.settlementToken(), stablecoin);
        assertEq(bondToken.complianceModule(), address(complianceModule));
        assertEq(bondToken.issuanceController(), issuanceController);
    }

    function test_onlyIssuanceControllerCanMintAndBurn() public {
        vm.prank(holder);
        vm.expectRevert();
        bondToken.mint(holder, 10e18);

        vm.prank(issuanceController);
        bondToken.mint(holder, 10e18);
        assertEq(bondToken.balanceOf(holder), 10e18);

        vm.prank(holder);
        vm.expectRevert();
        bondToken.burn(holder, 1e18);

        vm.prank(issuanceController);
        bondToken.burn(holder, 1e18);
        assertEq(bondToken.balanceOf(holder), 9e18);
    }

    function test_detectTransferRestrictionDelegatesToComplianceModule() public {
        complianceModule.setRestrictionCode(3);
        assertEq(bondToken.detectTransferRestriction(holder, receiver, 1e18), 3);
    }

    function test_transferRevertsWhenComplianceRejects() public {
        vm.prank(issuanceController);
        bondToken.mint(holder, 10e18);
        complianceModule.setRestrictionCode(1);

        vm.prank(holder);
        vm.expectRevert();
        if (bondToken.transfer(receiver, 1e18)) {
            revert("unreachable");
        }
    }
}
