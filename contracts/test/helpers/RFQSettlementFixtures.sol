// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BondToken} from "../../src/BondToken.sol";
import {ComplianceModule} from "../../src/compliance/ComplianceModule.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";
import {
    Role,
    Order,
    OrderSide,
    FeeConfig,
    BondCategory,
    CouponFrequency,
    DayCount
} from "../../src/types/BondTypes.sol";
import {RFQSettlement} from "../../src/RFQSettlement.sol";

abstract contract RFQSettlementFixtures is Test {
    using ECDSA for bytes32;

    uint256 internal constant MAKER_PK = 0xA11CE;
    uint256 internal constant INVESTOR_PK = 0xB0B;
    uint256 internal constant OTHER_MAKER_PK = 0xCAFE;

    address internal admin = makeAddr("admin");
    address internal factory = makeAddr("factory");
    address internal issuer = makeAddr("issuer");
    address internal issuanceController = makeAddr("issuanceController");
    address internal feeRecipient = makeAddr("feeRecipient");

    address internal maker = vm.addr(MAKER_PK);
    address internal investor = vm.addr(INVESTOR_PK);
    address internal otherMaker = vm.addr(OTHER_MAKER_PK);

    MockERC20Decimals internal usdc;
    ComplianceModule internal complianceModule;
    BondToken internal bondToken;
    RFQSettlement internal settlement;

    function deployRfqFixtures() internal {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        ComplianceModule complianceImplementation = new ComplianceModule();
        complianceModule = ComplianceModule(
            address(
                new ERC1967Proxy(
                    address(complianceImplementation),
                    abi.encodeCall(
                        ComplianceModule.initialize,
                        (admin, factory, keccak256("policy"), 1)
                    )
                )
            )
        );

        RFQSettlement settlementImplementation = new RFQSettlement();
        settlement = RFQSettlement(
            address(
                new ERC1967Proxy(
                    address(settlementImplementation),
                    abi.encodeCall(RFQSettlement.initialize, (admin))
                )
            )
        );

        bondToken = new BondToken(
            BondToken.ConstructorParams({
                issuer: issuer,
                name: "HashKey Bond",
                symbol: "HKB",
                decimals: 18,
                faceValue: 1_000e6,
                couponRateBps: 500,
                maturityTimestamp: block.timestamp + 30 days,
                settlementToken: address(usdc),
                complianceModule: address(complianceModule),
                issuanceController: issuanceController,
                issueDate: block.timestamp,
                dayCountConvention: DayCount.ACT_365,
                couponFrequency: CouponFrequency.BULLET,
                bondCategory: BondCategory.CORPORATE,
                isin: bytes12(0)
            })
        );

        vm.prank(factory);
        complianceModule.bindBondToken(address(bondToken));

        vm.startPrank(admin);
        complianceModule.setWhitelist(maker, true);
        complianceModule.setWhitelist(investor, true);
        complianceModule.setWhitelist(otherMaker, true);
        complianceModule.setRole(maker, Role.MARKET_MAKER);
        complianceModule.setRole(investor, Role.INVESTOR);
        complianceModule.setRole(otherMaker, Role.MARKET_MAKER);
        settlement.setBondTokenRegistration(address(bondToken), true);
        settlement.setSettlementTokenPolicy(address(usdc), true);
        settlement.setFeeConfig(
            FeeConfig({
                feeRecipient: feeRecipient,
                currentFeeBps: 0,
                maxFeeBps: 1_000
            })
        );
        vm.stopPrank();

        vm.prank(issuanceController);
        bondToken.mint(maker, 1_000e18);
        vm.prank(issuanceController);
        bondToken.mint(otherMaker, 1_000e18);

        usdc.mint(investor, 10_000_000e6);
        usdc.mint(maker, 10_000_000e6);

        vm.prank(maker);
        bondToken.approve(address(settlement), type(uint256).max);
        vm.prank(maker);
        usdc.approve(address(settlement), type(uint256).max);
        vm.prank(otherMaker);
        bondToken.approve(address(settlement), type(uint256).max);
        vm.prank(otherMaker);
        usdc.approve(address(settlement), type(uint256).max);
        vm.prank(investor);
        usdc.approve(address(settlement), type(uint256).max);
        vm.prank(investor);
        bondToken.approve(address(settlement), type(uint256).max);
    }

    function makeBuyOrder(
        uint256 bondAmount,
        uint256 quoteAmount,
        uint256 nonce,
        uint256 salt
    ) internal view returns (Order memory) {
        return
            Order({
                maker: maker,
                taker: investor,
                bondToken: address(bondToken),
                quoteToken: address(usdc),
                bondAmount: bondAmount,
                quoteAmount: quoteAmount,
                side: OrderSide.BUY,
                expiry: block.timestamp + 1 days,
                nonce: nonce,
                salt: salt,
                maxFeeBps: 10_000,
                accruedInterest: 0
            });
    }

    function makeBuyOrderForMaker(
        address makerAddress,
        uint256 bondAmount,
        uint256 quoteAmount,
        uint256 nonce,
        uint256 salt
    ) internal view returns (Order memory) {
        return
            Order({
                maker: makerAddress,
                taker: investor,
                bondToken: address(bondToken),
                quoteToken: address(usdc),
                bondAmount: bondAmount,
                quoteAmount: quoteAmount,
                side: OrderSide.BUY,
                expiry: block.timestamp + 1 days,
                nonce: nonce,
                salt: salt,
                maxFeeBps: 10_000,
                accruedInterest: 0
            });
    }

    function makeSellOrder(
        uint256 bondAmount,
        uint256 quoteAmount,
        uint256 nonce,
        uint256 salt
    ) internal view returns (Order memory) {
        return
            Order({
                maker: maker,
                taker: investor,
                bondToken: address(bondToken),
                quoteToken: address(usdc),
                bondAmount: bondAmount,
                quoteAmount: quoteAmount,
                side: OrderSide.SELL,
                expiry: block.timestamp + 1 days,
                nonce: nonce,
                salt: salt,
                maxFeeBps: 10_000,
                accruedInterest: 0
            });
    }

    function signOrder(
        Order memory order,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
