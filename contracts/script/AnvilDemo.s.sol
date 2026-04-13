// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BondFactory} from "../src/BondFactory.sol";
import {BondIssuance} from "../src/BondIssuance.sol";
import {BondToken} from "../src/BondToken.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {MockERC20Decimals} from "../test/mocks/MockERC20Decimals.sol";
import {
    BondConfig,
    Order,
    OrderSide,
    PauseDomain,
    Role,
    SubscriptionTerms
} from "../src/types/BondTypes.sol";

/// @title AnvilDemo
/// @notice Anvil 环境全自动端到端演示脚本——覆盖完整债券生命周期。
/// @dev 前置条件：已在 Anvil 上执行 FullDeploy（make deploy-anvil），deployments/31337.json 存在。
///
///   一键执行（Makefile 自动拆分两阶段 + 时间推进）：
///     make demo-anvil
///
///   手动执行：
///     forge script script/AnvilDemo.s.sol:AnvilDemo --sig "runPreMaturity()" --rpc-url http://127.0.0.1:8545 --broadcast
///     cast rpc --rpc-url http://127.0.0.1:8545 evm_increaseTime '[2592001]'
///     cast rpc --rpc-url http://127.0.0.1:8545 evm_mine
///     forge script script/AnvilDemo.s.sol:AnvilDemo --sig "runPostMaturity()" --rpc-url http://127.0.0.1:8545 --broadcast
///
///   纯模拟（不 broadcast，包含 vm.warp）：
///     forge script script/AnvilDemo.s.sol:AnvilDemo --sig "run()" --rpc-url http://127.0.0.1:8545
contract AnvilDemo is Script {
    // ═══════════════════════════════════════════════════════════════
    //  Anvil 预设私钥 (#1 - #9)
    // ═══════════════════════════════════════════════════════════════

    uint256 internal constant ADMIN_PK =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ISSUER_PK =
        0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant MAKER_A_PK =
        0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant MAKER_B_PK =
        0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant MAKER_C_PK =
        0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 internal constant INVESTOR_A_PK =
        0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 internal constant INVESTOR_B_PK =
        0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 internal constant INVESTOR_C_PK =
        0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;
    uint256 internal constant DELEGATE_PK =
        0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;

    bytes32 internal constant APPROVAL_ID = keccak256("demo-bond-001");

    address internal admin;
    address internal issuer;
    address internal makerA;
    address internal makerB;
    address internal makerC;
    address internal investorA;
    address internal investorB;
    address internal investorC;
    address internal delegate;

    BondFactory internal factory;
    BondIssuance internal issuance;
    RFQSettlement internal settlement;
    MockERC20Decimals internal usdc;
    address internal complianceImpl;

    BondToken internal bondToken;
    ComplianceModule internal complianceModule;
    bytes32 internal offerId;

    uint256 internal _nextSalt = 1;

    // ═══════════════════════════════════════════════════════════════
    //  入口：纯模拟（含 vm.warp，不需要 --broadcast）
    // ═══════════════════════════════════════════════════════════════

    function run() external {
        _initAccounts();
        _loadDeployment();

        _phase1_mintUsdc();
        _phase2_createBond();
        _phase3_compliance();
        _phase4_subscription();
        _phase5_rfqTrading();
        _phase6_restrictions();

        vm.warp(bondToken.maturityTimestamp() + 1);
        console2.log("");
        console2.log(">>> Time warped to maturity +1 (simulation only)");

        _phase7_redemption();
        _phase8_extras();

        _logComplete();
    }

    // ═══════════════════════════════════════════════════════════════
    //  入口：broadcast — 到期前阶段
    // ═══════════════════════════════════════════════════════════════

    function runPreMaturity() external {
        _initAccounts();
        _loadDeployment();

        _phase1_mintUsdc();
        _phase2_createBond();
        _phase3_compliance();
        _phase4_subscription();
        _phase5_rfqTrading();
        _phase6_restrictions();

        console2.log("");
        console2.log("========================================");
        console2.log("  PRE-MATURITY PHASES COMPLETE");
        console2.log("  Maturity timestamp:", bondToken.maturityTimestamp());
        console2.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════
    //  入口：broadcast — 到期后阶段
    // ═══════════════════════════════════════════════════════════════

    function runPostMaturity() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();

        _phase7_redemption();
        _phase8_extras();

        _logComplete();
    }

    // ═══════════════════════════════════════════════════════════════
    //  初始化 & 加载
    // ═══════════════════════════════════════════════════════════════

    function _initAccounts() internal {
        admin = vm.addr(ADMIN_PK);
        issuer = vm.addr(ISSUER_PK);
        makerA = vm.addr(MAKER_A_PK);
        makerB = vm.addr(MAKER_B_PK);
        makerC = vm.addr(MAKER_C_PK);
        investorA = vm.addr(INVESTOR_A_PK);
        investorB = vm.addr(INVESTOR_B_PK);
        investorC = vm.addr(INVESTOR_C_PK);
        delegate = vm.addr(DELEGATE_PK);
    }

    function _loadDeployment() internal {
        string memory json = vm.readFile("../deployments/31337.json");
        factory = BondFactory(
            vm.parseJsonAddress(json, ".contracts.bondFactory")
        );
        issuance = BondIssuance(
            vm.parseJsonAddress(json, ".contracts.bondIssuance")
        );
        settlement = RFQSettlement(
            vm.parseJsonAddress(json, ".contracts.rfqSettlement")
        );
        complianceImpl = vm.parseJsonAddress(
            json,
            ".contracts.complianceImplementation"
        );
        usdc = MockERC20Decimals(
            vm.parseJsonAddress(
                json,
                ".configuration.settlementTokens[0].token"
            )
        );
        console2.log("--- Deployment loaded ---");
        console2.log("  Factory:    ", address(factory));
        console2.log("  Issuance:   ", address(issuance));
        console2.log("  Settlement: ", address(settlement));
        console2.log("  USDC:       ", address(usdc));
    }

    function _loadBondFromFactory() internal {
        (address bt, address cm) = factory.getBondAddresses(APPROVAL_ID);
        bondToken = BondToken(bt);
        complianceModule = ComplianceModule(cm);
        console2.log("--- Bond loaded from factory ---");
        console2.log("  BondToken:        ", bt);
        console2.log("  ComplianceModule: ", cm);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 1: 铸造 USDC
    // ═══════════════════════════════════════════════════════════════

    function _phase1_mintUsdc() internal {
        console2.log("");
        console2.log("=== Phase 1: Mint USDC ===");

        vm.startBroadcast(ADMIN_PK);
        usdc.mint(issuer, 2_000_000e6);
        usdc.mint(makerA, 1_000_000e6);
        usdc.mint(makerB, 1_000_000e6);
        usdc.mint(makerC, 1_000_000e6);
        usdc.mint(investorA, 1_000_000e6);
        usdc.mint(investorB, 1_000_000e6);
        usdc.mint(investorC, 1_000_000e6);
        usdc.mint(delegate, 1_000_000e6);
        vm.stopBroadcast();

        console2.log("  Minted USDC to all participants");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 2: 创建债券 (decimals=0)
    // ═══════════════════════════════════════════════════════════════

    function _phase2_createBond() internal {
        console2.log("");
        console2.log("=== Phase 2: Create Bond (decimals=0) ===");

        uint256 maturity = block.timestamp + 30 days;

        vm.startBroadcast(ADMIN_PK);
        factory.approveIssuance(
            APPROVAL_ID,
            issuer,
            complianceImpl,
            block.timestamp + 7 days,
            keccak256("demo-metadata")
        );
        vm.stopBroadcast();
        console2.log("  Issuance approved");

        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Demo Bond",
            symbol: "HKB-DEMO",
            decimals: 0,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: maturity,
            settlementToken: address(usdc),
            settlementTokenDecimals: 6,
            complianceImplementation: complianceImpl,
            policyId: keccak256("demo-policy"),
            policyVersion: 1
        });

        vm.startBroadcast(ISSUER_PK);
        (address bt, address cm) = factory.createBond(config, APPROVAL_ID);
        vm.stopBroadcast();

        bondToken = BondToken(bt);
        complianceModule = ComplianceModule(cm);

        console2.log("  BondToken:        ", bt);
        console2.log("  ComplianceModule: ", cm);
        console2.log("  Maturity:         ", maturity);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 3: 合规配置
    // ═══════════════════════════════════════════════════════════════

    function _phase3_compliance() internal {
        console2.log("");
        console2.log("=== Phase 3: Compliance Setup ===");

        vm.startBroadcast(ADMIN_PK);
        complianceModule.setWhitelist(issuer, true);
        complianceModule.setWhitelist(makerA, true);
        complianceModule.setWhitelist(makerB, true);
        complianceModule.setWhitelist(investorA, true);
        complianceModule.setWhitelist(investorB, true);
        complianceModule.setWhitelist(delegate, true);

        complianceModule.setRole(issuer, Role.ISSUER);
        complianceModule.setRole(makerA, Role.MARKET_MAKER);
        complianceModule.setRole(makerB, Role.MARKET_MAKER);
        complianceModule.setRole(makerC, Role.MARKET_MAKER);
        complianceModule.setRole(investorA, Role.INVESTOR);
        complianceModule.setRole(investorB, Role.INVESTOR);
        complianceModule.setRole(investorC, Role.INVESTOR);
        complianceModule.setRole(delegate, Role.MARKET_MAKER);

        settlement.setBondTokenRegistration(address(bondToken), true);
        vm.stopBroadcast();

        console2.log(
            "  Whitelisted: issuer, makerA, makerB, investorA, investorB, delegate"
        );
        console2.log("  NOT whitelisted: makerC, investorC");
        console2.log("  BondToken registered for RFQ settlement");

        _approveAll();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 4: 一级认购
    // ═══════════════════════════════════════════════════════════════

    function _phase4_subscription() internal {
        console2.log("");
        console2.log("=== Phase 4: Primary Subscription ===");

        offerId = _createOffer(1000, 1_000e6);

        _subscribe(MAKER_A_PK, offerId, 800);
        console2.log("  makerA subscribed 800 bonds");

        // 预期失败：用 vm.prank 模拟，不 broadcast
        _subscribeShouldFail(
            MAKER_B_PK,
            offerId,
            500,
            "SubscriptionCapExceeded"
        );

        uint256 remaining = _queryRemaining(offerId);
        console2.log("  Remaining units:", remaining);

        _subscribe(MAKER_B_PK, offerId, remaining);
        console2.log("  makerB subscribed", remaining, "bonds");

        _subscribeShouldFail(MAKER_C_PK, offerId, 10, "NotWhitelisted");

        _logBalances("After Subscription");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 5: RFQ 二级交易
    // ═══════════════════════════════════════════════════════════════

    function _phase5_rfqTrading() internal {
        console2.log("");
        console2.log("=== Phase 5: RFQ Secondary Trading ===");

        console2.log("");
        console2.log("  [7a] investorA buys 10 from makerA @ 2000 USDC");
        _rfqFill(MAKER_A_PK, INVESTOR_A_PK, 10, 20_000e6, OrderSide.BUY);

        console2.log("  [7b] investorA buys 10 from makerB @ 3000 USDC");
        _rfqFill(MAKER_B_PK, INVESTOR_A_PK, 10, 30_000e6, OrderSide.BUY);
        _logBalances("After Step 7");

        console2.log("");
        console2.log("  [8] investorB buys 190 from makerB @ 2000 USDC");
        _rfqFill(MAKER_B_PK, INVESTOR_B_PK, 190, 380_000e6, OrderSide.BUY);
        _logBalances("After Step 8");

        // 步骤 10a: 取消订单（实际 broadcast cancel）
        console2.log("");
        console2.log(
            "  [10a] investorA sells 10 to makerB @ 4000 USDC - CANCEL"
        );
        uint256 cancelSalt = _nextSalt++;
        _rfqCancel(
            MAKER_B_PK,
            investorA,
            10,
            40_000e6,
            OrderSide.SELL,
            cancelSalt
        );
        _rfqFillCancelledShouldFail(
            MAKER_B_PK,
            INVESTOR_A_PK,
            10,
            40_000e6,
            OrderSide.SELL,
            cancelSalt
        );

        console2.log("  [10b] investorA sells 10 to makerB @ 5000 USDC");
        _rfqFill(MAKER_B_PK, INVESTOR_A_PK, 10, 50_000e6, OrderSide.SELL);
        _logBalances("After Step 10");

        console2.log("");
        console2.log(
            "  [11a] investorA buys 90 from makerA @ 2000 USDC - EXPIRED"
        );
        _rfqFillExpired(
            MAKER_A_PK,
            INVESTOR_A_PK,
            90,
            180_000e6,
            OrderSide.BUY
        );

        console2.log("  [11b] investorA buys 90 from makerA @ 2000 USDC");
        _rfqFill(MAKER_A_PK, INVESTOR_A_PK, 90, 180_000e6, OrderSide.BUY);
        _logBalances("After Step 11");

        console2.log("");
        console2.log(
            "  [12] makerB buys 100 from makerA @ 2000 USDC (MM-MM, no fee)"
        );
        _rfqFill(MAKER_A_PK, MAKER_B_PK, 100, 200_000e6, OrderSide.BUY);
        _logBalances("After Step 12");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 6: 合规限制测试（全部用 vm.prank，不 broadcast）
    // ═══════════════════════════════════════════════════════════════

    function _phase6_restrictions() internal {
        console2.log("");
        console2.log("=== Phase 6: Compliance Restrictions ===");

        console2.log("  [9a] makerC tries to make order - NOT whitelisted");
        _rfqFillShouldFail(
            MAKER_C_PK,
            INVESTOR_A_PK,
            1,
            1_000e6,
            OrderSide.BUY,
            "NotWhitelisted"
        );

        console2.log("  [9b] investorC tries to take order - NOT whitelisted");
        _rfqFillShouldFail(
            MAKER_A_PK,
            INVESTOR_C_PK,
            1,
            1_000e6,
            OrderSide.BUY,
            "NotWhitelisted"
        );

        console2.log(
            "  [13] investorA tries to buy from investorB - RESTRICTED"
        );
        _rfqFillShouldFail(
            INVESTOR_B_PK,
            INVESTOR_A_PK,
            1,
            1_000e6,
            OrderSide.BUY,
            "InvestorToInvestorRestricted"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 7: 到期赎回
    // ═══════════════════════════════════════════════════════════════

    function _phase7_redemption() internal {
        console2.log("");
        console2.log("=== Phase 7: Redemption ===");

        _logBalances("Before Redemption");

        // issuer 存入赎回资金（多存 50,000 用于测试 rescue）
        uint256 depositAmount = 1_100_000e6;
        _depositRedemption(depositAmount);
        console2.log(
            "  Issuer deposited",
            depositAmount,
            "(includes 50,000 excess)"
        );

        // makerA 设置 delegate 代领
        _setClaimDelegate(MAKER_A_PK, delegate);
        console2.log("  makerA set delegate for claim");

        // makerB 想帮忙代 makerA 领，但没权限（vm.prank，不 broadcast）
        _claimForShouldFail(MAKER_B_PK, makerA, "UnauthorizedClaimCaller");

        // delegate 代 makerA 领
        _claimFor(DELEGATE_PK, makerA);
        console2.log("  delegate claimed for makerA");

        _claim(MAKER_B_PK);
        console2.log("  makerB claimed");

        _claim(INVESTOR_A_PK);
        console2.log("  investorA claimed");

        _claim(INVESTOR_B_PK);
        console2.log("  investorB claimed");

        _logBalances("After Redemption");

        // admin 将多余资金 rescue 回 issuer
        _rescueExcess(address(usdc), issuer, 50_000e6);
        console2.log("  Admin rescued 50,000 excess USDC to issuer");

        _logBalances("After Rescue");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 8: 附加功能测试
    // ═══════════════════════════════════════════════════════════════

    function _phase8_extras() internal {
        console2.log("");
        console2.log("=== Phase 8: Extra Tests ===");

        vm.startBroadcast(ADMIN_PK);
        settlement.pauseDomain(PauseDomain.SETTLEMENT, true);
        vm.stopBroadcast();
        console2.log("  Settlement PAUSED");

        vm.startBroadcast(ADMIN_PK);
        settlement.pauseDomain(PauseDomain.SETTLEMENT, false);
        vm.stopBroadcast();
        console2.log("  Settlement UNPAUSED");

        console2.log("  Phase 8 complete");
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：approve
    // ═══════════════════════════════════════════════════════════════

    function _approveAll() internal {
        uint256[7] memory pks = [
            MAKER_A_PK,
            MAKER_B_PK,
            MAKER_C_PK,
            INVESTOR_A_PK,
            INVESTOR_B_PK,
            INVESTOR_C_PK,
            DELEGATE_PK
        ];
        for (uint256 i = 0; i < pks.length; i++) {
            vm.startBroadcast(pks[i]);
            usdc.approve(address(issuance), type(uint256).max);
            usdc.approve(address(settlement), type(uint256).max);
            IERC20(address(bondToken)).approve(
                address(settlement),
                type(uint256).max
            );
            vm.stopBroadcast();
        }

        vm.startBroadcast(ISSUER_PK);
        usdc.approve(address(issuance), type(uint256).max);
        vm.stopBroadcast();

        console2.log("  All token approvals set");
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：认购（broadcast）
    // ═══════════════════════════════════════════════════════════════

    function _createOffer(
        uint256 maxUnits,
        uint256 unitPrice
    ) internal returns (bytes32 id) {
        bytes32 subApprovalId = keccak256(
            abi.encodePacked("demo-sub-", maxUnits, unitPrice)
        );

        vm.startBroadcast(ADMIN_PK);
        issuance.approveSubscription(
            subApprovalId,
            issuer,
            address(bondToken),
            maxUnits,
            block.timestamp + 7 days
        );
        vm.stopBroadcast();
        console2.log("  Subscription approved, maxUnits:", maxUnits);

        vm.startBroadcast(ISSUER_PK);
        id = issuance.createSubscription(
            SubscriptionTerms({
                bondToken: address(bondToken),
                settlementToken: address(usdc),
                unitPrice: unitPrice,
                maxUnits: maxUnits,
                opensAt: block.timestamp,
                closesAt: block.timestamp + 7 days
            }),
            subApprovalId
        );
        vm.stopBroadcast();
        console2.log("  Subscription created, maxUnits:", maxUnits);
    }

    function _subscribe(uint256 pk, bytes32 id, uint256 units) internal {
        vm.startBroadcast(pk);
        issuance.subscribe(id, units);
        vm.stopBroadcast();
    }

    /// @dev 预期失败 — 用 vm.prank 模拟，不 broadcast
    function _subscribeShouldFail(
        uint256 pk,
        bytes32 id,
        uint256 units,
        string memory reason
    ) internal {
        vm.prank(vm.addr(pk));
        try issuance.subscribe(id, units) {
            console2.log("  [ERROR] Should have reverted!");
        } catch {
            console2.log("  Subscribe reverted as expected:", reason);
        }
    }

    function _queryRemaining(bytes32 id) internal view returns (uint256) {
        (, , , uint256 maxUnits, uint256 soldUnits, , , ) = issuance
            .getSubscription(id);
        return maxUnits - soldUnits;
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：RFQ（broadcast 真实交易，prank 预期失败）
    // ═══════════════════════════════════════════════════════════════

    function _buildOrder(
        uint256 makerPk,
        address taker,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side,
        uint256 expiry,
        uint256 salt
    ) internal view returns (Order memory) {
        address maker = vm.addr(makerPk);
        return
            Order({
                maker: maker,
                taker: taker,
                bondToken: address(bondToken),
                quoteToken: address(usdc),
                bondAmount: bondAmt,
                quoteAmount: quoteAmt,
                side: side,
                expiry: expiry,
                nonce: settlement.currentNonce(maker),
                salt: salt,
                maxFeeBps: 10_000
            });
    }

    function _rfqFill(
        uint256 makerPk,
        uint256 takerPk,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side
    ) internal {
        address taker = vm.addr(takerPk);
        uint256 salt = _nextSalt++;
        Order memory order = _buildOrder(
            makerPk,
            taker,
            bondAmt,
            quoteAmt,
            side,
            block.timestamp + 1 days,
            salt
        );
        bytes memory sig = _signOrder(order, makerPk);

        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 takerBondBefore = bondToken.balanceOf(taker);

        vm.startBroadcast(takerPk);
        settlement.fillOrder(order, sig);
        vm.stopBroadcast();

        if (side == OrderSide.BUY) {
            console2.log(
                "    taker USDC spent:",
                takerUsdcBefore - usdc.balanceOf(taker)
            );
            console2.log(
                "    taker bonds received:",
                bondToken.balanceOf(taker) - takerBondBefore
            );
        } else {
            console2.log(
                "    taker bonds sold:",
                takerBondBefore - bondToken.balanceOf(taker)
            );
            console2.log(
                "    taker USDC received:",
                usdc.balanceOf(taker) - takerUsdcBefore
            );
        }
    }

    /// @dev 预期失败 — vm.prank，不 broadcast
    function _rfqFillShouldFail(
        uint256 makerPk,
        uint256 takerPk,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side,
        string memory reason
    ) internal {
        address taker = vm.addr(takerPk);
        uint256 salt = _nextSalt++;
        Order memory order = _buildOrder(
            makerPk,
            taker,
            bondAmt,
            quoteAmt,
            side,
            block.timestamp + 1 days,
            salt
        );
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill reverted as expected:", reason);
        }
    }

    function _rfqCancel(
        uint256 makerPk,
        address taker,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side,
        uint256 salt
    ) internal {
        Order memory order = _buildOrder(
            makerPk,
            taker,
            bondAmt,
            quoteAmt,
            side,
            block.timestamp + 1 days,
            salt
        );
        vm.startBroadcast(makerPk);
        settlement.cancelOrder(order);
        vm.stopBroadcast();

        bytes32 orderHash = settlement.hashOrder(order);
        console2.log("    Order cancelled, hash:");
        console2.logBytes32(orderHash);
    }

    /// @dev 预期失败 — vm.prank，不 broadcast
    function _rfqFillCancelledShouldFail(
        uint256 makerPk,
        uint256 takerPk,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side,
        uint256 salt
    ) internal {
        address taker = vm.addr(takerPk);
        Order memory order = _buildOrder(
            makerPk,
            taker,
            bondAmt,
            quoteAmt,
            side,
            block.timestamp + 1 days,
            salt
        );
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill cancelled order reverted as expected");
        }
    }

    /// @dev 预期失败 — vm.prank，不 broadcast
    function _rfqFillExpired(
        uint256 makerPk,
        uint256 takerPk,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side
    ) internal {
        address taker = vm.addr(takerPk);
        uint256 salt = _nextSalt++;
        Order memory order = _buildOrder(
            makerPk,
            taker,
            bondAmt,
            quoteAmt,
            side,
            block.timestamp - 1,
            salt
        );
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill reverted as expected: ExpiredDeadline");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：赎回（broadcast 真实交易，prank 预期失败）
    // ═══════════════════════════════════════════════════════════════

    function _depositRedemption(uint256 amount) internal {
        vm.startBroadcast(ISSUER_PK);
        issuance.depositRedemption(address(bondToken), amount);
        vm.stopBroadcast();
    }

    function _claim(uint256 pk) internal {
        vm.startBroadcast(pk);
        issuance.claim(address(bondToken));
        vm.stopBroadcast();
    }

    function _claimFor(uint256 delegatePk, address holder) internal {
        vm.startBroadcast(delegatePk);
        issuance.claimFor(address(bondToken), holder);
        vm.stopBroadcast();
    }

    /// @dev 预期失败 — vm.prank，不 broadcast
    function _claimForShouldFail(
        uint256 callerPk,
        address holder,
        string memory reason
    ) internal {
        vm.prank(vm.addr(callerPk));
        try issuance.claimFor(address(bondToken), holder) {
            console2.log("  [ERROR] Should have reverted!");
        } catch {
            console2.log("  claimFor reverted as expected:", reason);
        }
    }

    function _setClaimDelegate(
        uint256 holderPk,
        address delegateAddr
    ) internal {
        vm.startBroadcast(holderPk);
        issuance.setClaimDelegate(delegateAddr);
        vm.stopBroadcast();
    }

    function _rescueExcess(address token, address to, uint256 amount) internal {
        vm.startBroadcast(ADMIN_PK);
        issuance.rescueTokens(token, to, amount);
        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════════════════════
    //  工具函数
    // ═══════════════════════════════════════════════════════════════

    function _signOrder(
        Order memory order,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _logBalances(string memory label) internal view {
        console2.log("");
        console2.log("  ---", label, "---");
        _logBalance("makerA", makerA);
        _logBalance("makerB", makerB);
        _logBalance("investorA", investorA);
        _logBalance("investorB", investorB);
    }

    function _logBalance(string memory name, address account) internal view {
        console2.log(
            string.concat("    ", name, " | bond: "),
            bondToken.balanceOf(account),
            "| USDC:",
            usdc.balanceOf(account)
        );
    }

    function _logComplete() internal pure {
        console2.log("");
        console2.log("========================================");
        console2.log("  ALL PHASES COMPLETED SUCCESSFULLY");
        console2.log("========================================");
    }
}
