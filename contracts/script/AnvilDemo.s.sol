// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { BondFactory } from "../src/BondFactory.sol";
import { BondIssuance } from "../src/BondIssuance.sol";
import { BondToken } from "../src/BondToken.sol";
import { ComplianceModule } from "../src/compliance/ComplianceModule.sol";
import { RFQSettlement } from "../src/RFQSettlement.sol";
import { MockERC20Decimals } from "../test/mocks/MockERC20Decimals.sol";
import {
    BondCategory,
    BondConfig,
    CouponFrequency,
    DayCount,
    FeeConfig,
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
///   时间线（UTC）：
///     2026-01-01 00:00  认购窗口开启
///     2026-01-08 00:00  认购窗口关闭
///     2026-01-09 00:00  起息日（issueDate）
///     2027-01-09 00:00  到期日（maturity = issueDate + 365 天）
///
///   一键执行（Makefile 自动多阶段 + 时间推进）：
///     make demo-anvil
///
///   纯模拟（不 broadcast，包含 vm.warp）：
///     forge script script/AnvilDemo.s.sol:AnvilDemo --sig "run()" --rpc-url http://127.0.0.1:8545
contract AnvilDemo is Script {
    // ═══════════════════════════════════════════════════════════════
    //  时间线常量（UTC）
    // ═══════════════════════════════════════════════════════════════

    uint256 internal constant SUB_OPENS = 1_767_225_600; // 2026-01-01 00:00
    uint256 internal constant SUB_CLOSES = 1_767_830_400; // 2026-01-08 00:00
    uint256 internal constant ISSUE_DATE = 1_767_916_800; // 2026-01-09 00:00
    uint256 internal constant MATURITY = 1_799_452_800; // 2027-01-09 00:00

    // ═══════════════════════════════════════════════════════════════
    //  Anvil 预设私钥 (#1 - #9)
    // ═══════════════════════════════════════════════════════════════

    uint256 internal constant ADMIN_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ISSUER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant MAKER_A_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant MAKER_B_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant MAKER_C_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 internal constant INVESTOR_A_PK = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
    uint256 internal constant INVESTOR_B_PK = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
    uint256 internal constant INVESTOR_C_PK = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;
    uint256 internal constant DELEGATE_PK = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;

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

        // 2026-01-01 00:00 UTC — 认购窗口开启
        vm.warp(SUB_OPENS);
        _phase1_mintUsdc();
        _phase2_createBond();
        _phase3_compliance();
        _phase4_subscription();

        // 2026-01-09 00:12 UTC — 起息日后 12 分钟，进入 RFQ
        vm.warp(ISSUE_DATE + 12 minutes);
        console2.log("");
        console2.log(">>> Time warped to issueDate + 12 min (2026-01-09 00:12 UTC)");
        _step7_firstTrades();

        // +2 天 ≈ 2026-01-11
        vm.warp(block.timestamp + 2 days);
        console2.log("");
        console2.log(">>> Time warped +2 days");
        _step8_investorBBuys();
        _step9_restrictions();

        // +30 天 ≈ 2026-02-10
        vm.warp(block.timestamp + 30 days);
        console2.log("");
        console2.log(">>> Time warped +30 days (~1 month)");
        _step10_cancelAndSell();

        // +30 天 ≈ 2026-03-12
        vm.warp(block.timestamp + 30 days);
        console2.log("");
        console2.log(">>> Time warped +30 days (~2 months)");
        _step11_expiryAndBuy();

        // +30 天 ≈ 2026-04-11
        vm.warp(block.timestamp + 30 days);
        console2.log("");
        console2.log(">>> Time warped +30 days (~3 months)");
        _step12_mmTrade();
        _step13_investorRestriction();
        _step15_deposit();

        // 2027-01-09 00:00:01 UTC — 到期日 + 1 秒
        vm.warp(MATURITY + 1);
        console2.log("");
        console2.log(">>> Time warped to maturity + 1 (2027-01-09 00:00:01 UTC)");
        _step16_redemption();
        _step17_extras();

        _logComplete();
    }

    // ═══════════════════════════════════════════════════════════════
    //  入口：broadcast — 分步执行（配合 Makefile 时间推进）
    // ═══════════════════════════════════════════════════════════════

    /// @dev Phase 1-4: 铸造 USDC、创建债券、合规配置、一级认购。
    ///      Makefile 先设置 Anvil 时间到 2026-01-01 00:00 UTC。
    function runSetup() external {
        _initAccounts();
        _loadDeployment();
        _phase1_mintUsdc();
        _phase2_createBond();
        _phase3_compliance();
        _phase4_subscription();
        console2.log("");
        console2.log("========================================");
        console2.log("  SETUP & SUBSCRIPTION COMPLETE");
        console2.log("========================================");
    }

    /// @dev Step 7: investorA 向 makerA/B 各买 10。
    ///      Makefile 先设置 Anvil 时间到 issueDate + 12 min。
    function runStep7() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step7_firstTrades();
    }

    /// @dev Step 8-9: investorB 买 190 + 合规限制测试。
    ///      Makefile 先推进 +2 天。
    function runStep8() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step8_investorBBuys();
        _step9_restrictions();
    }

    /// @dev Step 10: investorA 卖给 makerB（先取消再成交）。
    ///      Makefile 先推进 +30 天。
    function runStep10() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step10_cancelAndSell();
    }

    /// @dev Step 11: investorA 向 makerA 买 90（先过期再成交）。
    ///      Makefile 先推进 +30 天。
    function runStep11() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step11_expiryAndBuy();
    }

    /// @dev Step 12-13, 15: MM 间交易 + 投资者限制 + 存入赎回资金。
    ///      Makefile 先推进 +30 天。
    function runStep12() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step12_mmTrade();
        _step13_investorRestriction();
        _step15_deposit();
    }

    /// @dev Step 16-17: 到期赎回 + 附加功能测试。
    ///      Makefile 先设置 Anvil 时间到 maturity + 1。
    function runPostMaturity() external {
        _initAccounts();
        _loadDeployment();
        _loadBondFromFactory();
        _step16_redemption();
        _step17_extras();
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
        factory = BondFactory(vm.parseJsonAddress(json, ".contracts.bondFactory"));
        issuance = BondIssuance(vm.parseJsonAddress(json, ".contracts.bondIssuance"));
        settlement = RFQSettlement(vm.parseJsonAddress(json, ".contracts.rfqSettlement"));
        complianceImpl = vm.parseJsonAddress(json, ".contracts.complianceImplementation");
        usdc = MockERC20Decimals(vm.parseJsonAddress(json, ".configuration.settlementTokens[0].token"));
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

        console2.log("  issuer:    2,000,000 USDC");
        console2.log("  others:    1,000,000 USDC each");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 2: 创建债券 (decimals=0, ACT_365, 5% 年化)
    // ═══════════════════════════════════════════════════════════════

    function _phase2_createBond() internal {
        console2.log("");
        console2.log("=== Phase 2: Create Bond ===");
        console2.log("  decimals=0, ACT_365, coupon=5%/yr, BULLET");
        console2.log("  issueDate: 2026-01-09 (day after subscription closes)");
        console2.log("  maturity:  2027-01-09 (issueDate + 365 days)");

        BondConfig memory config = BondConfig({
            issuer: issuer,
            name: "HashKey Demo Bond 2026",
            symbol: "HKB-2026",
            decimals: 0,
            faceValue: 1_000e6,
            couponRateBps: 500,
            maturityTimestamp: MATURITY,
            settlementToken: address(usdc),
            settlementTokenDecimals: 6,
            complianceImplementation: complianceImpl,
            policyId: keccak256("demo-policy"),
            policyVersion: 1,
            issueDate: ISSUE_DATE,
            dayCountConvention: DayCount.ACT_365,
            couponFrequency: CouponFrequency.BULLET,
            bondCategory: BondCategory.CORPORATE,
            isin: bytes12(0)
        });
        // AUDIT-FIX(N3): bind metadataHash to canonical config hash so createBond accepts it.
        bytes32 metadataHash = factory.hashBondConfig(config);

        vm.startBroadcast(ADMIN_PK);
        factory.approveIssuance(APPROVAL_ID, issuer, complianceImpl, SUB_CLOSES, metadataHash);
        vm.stopBroadcast();
        console2.log("  Issuance approved");

        vm.startBroadcast(ISSUER_PK);
        (address bt, address cm) = factory.createBond(config, APPROVAL_ID);
        vm.stopBroadcast();

        bondToken = BondToken(bt);
        complianceModule = ComplianceModule(cm);

        console2.log("  BondToken:        ", bt);
        console2.log("  ComplianceModule: ", cm);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 3: 合规配置（makerC、investorC 不加白名单）
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

        complianceModule.setTransferOperator(address(settlement), true);
        settlement.setBondTokenRegistration(address(bondToken), true);
        vm.stopBroadcast();

        console2.log("  Whitelisted: issuer, makerA, makerB, investorA, investorB, delegate");
        console2.log("  NOT whitelisted: makerC, investorC");
        console2.log("  RFQSettlement registered as transfer operator");
        console2.log("  BondToken registered for RFQ settlement");

        _approveAll();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Phase 4: 一级认购 (1000 bonds @ 1000 USDC)
    // ═══════════════════════════════════════════════════════════════

    function _phase4_subscription() internal {
        console2.log("");
        console2.log("=== Phase 4: Primary Subscription ===");
        console2.log("  Window: 2026-01-01 ~ 2026-01-08, 1000 bonds @ 1000 USDC");

        offerId = _createOffer(1000, 1_000e6);

        _subscribe(MAKER_A_PK, offerId, 800);
        console2.log("  makerA subscribed 800 bonds");

        _subscribeShouldFail(MAKER_B_PK, offerId, 500, "SubscriptionCapExceeded");

        uint256 remaining = _queryRemaining(offerId);
        console2.log("  Remaining units:", remaining);

        _subscribe(MAKER_B_PK, offerId, remaining);
        console2.log("  makerB subscribed", remaining, "bonds");

        _subscribeShouldFail(MAKER_C_PK, offerId, 10, "NotWhitelisted");

        console2.log("  [4a] makerA tries direct transfer to makerB - UNAUTHORIZED_OPERATOR");
        _directTransferShouldFail(MAKER_A_PK, makerB, 10, "TransferRestricted(8)");

        _logBalances("After Subscription");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 7: investorA 向 makerA/B 各买 10（起息后 12 分钟）
    // ═══════════════════════════════════════════════════════════════

    function _step7_firstTrades() internal {
        console2.log("");
        console2.log("=== Step 7: First RFQ Trades (issueDate + 12 min) ===");

        console2.log("");
        console2.log("  [7x] makerA tries direct transfer to investorA - UNAUTHORIZED_OPERATOR");
        _directTransferShouldFail(MAKER_A_PK, investorA, 10, "TransferRestricted(8)");

        console2.log("");
        console2.log("  [7a] investorA buys 10 from makerA @ 2000 USDC each");
        _rfqFill(MAKER_A_PK, INVESTOR_A_PK, 10, 20_000e6, OrderSide.BUY);

        console2.log("");
        console2.log("  [7b] investorA buys 10 from makerB @ 3000 USDC each");
        _rfqFill(MAKER_B_PK, INVESTOR_A_PK, 10, 30_000e6, OrderSide.BUY);

        _logBalances("After Step 7");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 8: investorB 向 makerB 买 190（+2 天）
    // ═══════════════════════════════════════════════════════════════

    function _step8_investorBBuys() internal {
        console2.log("");
        console2.log("=== Step 8: investorB buys 190 from makerB @ 2000 USDC (+2 days) ===");
        _rfqFill(MAKER_B_PK, INVESTOR_B_PK, 190, 380_000e6, OrderSide.BUY);

        _logBalances("After Step 8");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 9: 合规限制测试（makerC / investorC 无资格）
    // ═══════════════════════════════════════════════════════════════

    function _step9_restrictions() internal {
        console2.log("");
        console2.log("=== Step 9: Compliance Restrictions ===");

        console2.log("  [9a] makerC tries to make order - NOT whitelisted");
        _rfqFillShouldFail(MAKER_C_PK, INVESTOR_A_PK, 1, 1_000e6, OrderSide.BUY, "NotWhitelisted");

        console2.log("  [9b] investorC tries to take order - NOT whitelisted");
        _rfqFillShouldFail(MAKER_A_PK, INVESTOR_C_PK, 1, 1_000e6, OrderSide.BUY, "NotWhitelisted");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 10: investorA 卖 10 给 makerB（先取消后成交，+1 月）
    // ═══════════════════════════════════════════════════════════════

    function _step10_cancelAndSell() internal {
        console2.log("");
        console2.log("=== Step 10: Cancel + Sell (+1 month) ===");

        console2.log("  [10a] investorA sells 10 to makerB @ 4000 USDC - CANCEL");
        uint256 cancelSalt = _nextSalt++;
        _rfqCancel(MAKER_B_PK, investorA, 10, 40_000e6, OrderSide.SELL, cancelSalt);
        _rfqFillCancelledShouldFail(MAKER_B_PK, INVESTOR_A_PK, 10, 40_000e6, OrderSide.SELL, cancelSalt);

        console2.log("  [10b] investorA sells 10 to makerB @ 5000 USDC each");
        _rfqFill(MAKER_B_PK, INVESTOR_A_PK, 10, 50_000e6, OrderSide.SELL);

        _logBalances("After Step 10");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 11: investorA 向 makerA 买 90（先过期后成交，+2 月）
    // ═══════════════════════════════════════════════════════════════

    function _step11_expiryAndBuy() internal {
        console2.log("");
        console2.log("=== Step 11: Expiry + Buy (+2 months) ===");

        console2.log("  [11a] investorA buys 90 from makerA @ 2000 USDC - EXPIRED");
        _rfqFillExpired(MAKER_A_PK, INVESTOR_A_PK, 90, 180_000e6, OrderSide.BUY);

        console2.log("  [11b] investorA buys 90 from makerA @ 2000 USDC each");
        _rfqFill(MAKER_A_PK, INVESTOR_A_PK, 90, 180_000e6, OrderSide.BUY);

        _logBalances("After Step 11");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 12: makerB 向 makerA 买 100（MM 间，无手续费，+3 月）
    // ═══════════════════════════════════════════════════════════════

    function _step12_mmTrade() internal {
        console2.log("");
        console2.log("=== Step 12: MM-to-MM trade (+3 months, no fee, with AI) ===");
        console2.log("  makerB buys 100 from makerA @ 2000 USDC each");
        _rfqFill(MAKER_A_PK, MAKER_B_PK, 100, 200_000e6, OrderSide.BUY);

        _logBalances("After Step 12");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 13: 投资者间交易限制
    // ═══════════════════════════════════════════════════════════════

    function _step13_investorRestriction() internal {
        console2.log("");
        console2.log("=== Step 13: Investor-to-Investor Restriction ===");
        console2.log("  investorB tries to make order - INVESTOR cannot be maker");
        _rfqFillShouldFail(INVESTOR_B_PK, INVESTOR_A_PK, 1, 1_000e6, OrderSide.BUY, "InvalidParticipantRole");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 15: issuer 存入赎回资金（多存 50K 测试 rescue）
    // ═══════════════════════════════════════════════════════════════

    function _step15_deposit() internal {
        console2.log("");
        console2.log("=== Step 15: Issuer Deposits Redemption Funds ===");

        uint256 depositAmount = 1_100_000e6;
        vm.startBroadcast(ISSUER_PK);
        issuance.depositRedemption(address(bondToken), depositAmount);
        vm.stopBroadcast();

        console2.log("  Deposited: 1,100,000 USDC");
        console2.log("  (1,050,000 required + 50,000 excess for rescue test)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 16: 到期赎回
    // ═══════════════════════════════════════════════════════════════

    function _step16_redemption() internal {
        console2.log("");
        console2.log("=== Step 16: Maturity Redemption ===");

        _logBalances("Before Redemption");

        // makerA 设置 delegate 代领
        _setClaimDelegate(MAKER_A_PK, delegate);
        console2.log("  makerA set delegate for claim");

        // makerB 想帮 makerA 领，但没权限
        _claimForShouldFail(MAKER_B_PK, makerA, "UnauthorizedClaimCaller");

        // delegate 代 makerA 领
        _claimFor(DELEGATE_PK, makerA);
        console2.log("  delegate claimed for makerA (600 bonds)");

        _claim(MAKER_B_PK);
        console2.log("  makerB claimed (110 bonds)");

        _claim(INVESTOR_A_PK);
        console2.log("  investorA claimed (100 bonds)");

        _claim(INVESTOR_B_PK);
        console2.log("  investorB claimed (190 bonds)");

        _logBalances("After Redemption");

        // AUDIT-FIX(N6): 超额赎回资金会在最后一个持仓 claim 触发的自动释放分支里直接转回发行人，
        //                不再需要 admin 手动 rescue。这里只是日志说明，不再执行 rescueTokens。
        console2.log("  Excess USDC auto-refunded to issuer (AUDIT-FIX N6)");

        _logBalances("After Auto-Refund");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Step 17: 附加功能测试
    // ═══════════════════════════════════════════════════════════════

    function _step17_extras() internal {
        console2.log("");
        console2.log("=== Step 17: Extra Tests ===");

        vm.startBroadcast(ADMIN_PK);
        settlement.pauseDomain(PauseDomain.SETTLEMENT, true);
        vm.stopBroadcast();
        console2.log("  Settlement PAUSED");

        vm.startBroadcast(ADMIN_PK);
        settlement.pauseDomain(PauseDomain.SETTLEMENT, false);
        vm.stopBroadcast();
        console2.log("  Settlement UNPAUSED");

        console2.log("  Phase complete");
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：approve
    // ═══════════════════════════════════════════════════════════════

    function _approveAll() internal {
        uint256[7] memory pks =
            [MAKER_A_PK, MAKER_B_PK, MAKER_C_PK, INVESTOR_A_PK, INVESTOR_B_PK, INVESTOR_C_PK, DELEGATE_PK];
        for (uint256 i = 0; i < pks.length; i++) {
            vm.startBroadcast(pks[i]);
            usdc.approve(address(issuance), type(uint256).max);
            usdc.approve(address(settlement), type(uint256).max);
            IERC20(address(bondToken)).approve(address(settlement), type(uint256).max);
            vm.stopBroadcast();
        }

        vm.startBroadcast(ISSUER_PK);
        usdc.approve(address(issuance), type(uint256).max);
        vm.stopBroadcast();

        console2.log("  All token approvals set");
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：认购
    // ═══════════════════════════════════════════════════════════════

    function _createOffer(uint256 maxUnits, uint256 unitPrice) internal returns (bytes32 id) {
        bytes32 subApprovalId = keccak256(abi.encodePacked("demo-sub-", maxUnits, unitPrice));

        vm.startBroadcast(ADMIN_PK);
        issuance.approveSubscription(subApprovalId, issuer, address(bondToken), maxUnits, SUB_CLOSES);
        vm.stopBroadcast();

        vm.startBroadcast(ISSUER_PK);
        id = issuance.createSubscription(
            SubscriptionTerms({
                bondToken: address(bondToken),
                settlementToken: address(usdc),
                unitPrice: unitPrice,
                maxUnits: maxUnits,
                opensAt: SUB_OPENS,
                closesAt: SUB_CLOSES
            }),
            subApprovalId
        );
        vm.stopBroadcast();
        console2.log("  Subscription created");
    }

    function _subscribe(uint256 pk, bytes32 id, uint256 units) internal {
        vm.startBroadcast(pk);
        issuance.subscribe(id, units);
        vm.stopBroadcast();
    }

    function _subscribeShouldFail(uint256 pk, bytes32 id, uint256 units, string memory reason) internal {
        vm.prank(vm.addr(pk));
        try issuance.subscribe(id, units) {
            console2.log("  [ERROR] Should have reverted!");
        } catch {
            console2.log("  Subscribe reverted as expected:", reason);
        }
    }

    function _queryRemaining(bytes32 id) internal view returns (uint256) {
        (,,, uint256 maxUnits, uint256 soldUnits,,,) = issuance.getSubscription(id);
        return maxUnits - soldUnits;
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：RFQ
    // ═══════════════════════════════════════════════════════════════

    /// @dev 计算当前时间的应计利息总额。
    /// @dev AUDIT-FIX(N7): 改用 BondToken.accruedInterestFor，避免老 perUnit 接口的早除精度损失，
    ///                     与 RFQSettlement._validateAccruedInterest 的链上 expectedAI 完全对齐。
    function _computeAI(uint256 bondAmt) internal view returns (uint256) {
        return bondToken.accruedInterestFor(bondAmt, block.timestamp);
    }

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
        return Order({
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
            maxFeeBps: 10_000,
            accruedInterest: _computeAI(bondAmt)
        });
    }

    function _rfqFill(uint256 makerPk, uint256 takerPk, uint256 bondAmt, uint256 quoteAmt, OrderSide side) internal {
        address taker = vm.addr(takerPk);
        uint256 salt = _nextSalt++;
        Order memory order = _buildOrder(makerPk, taker, bondAmt, quoteAmt, side, block.timestamp + 1 days, salt);
        bytes memory sig = _signOrder(order, makerPk);

        uint256[2] memory snap = [usdc.balanceOf(taker), usdc.balanceOf(vm.addr(makerPk))];

        vm.startBroadcast(takerPk);
        settlement.fillOrder(order, sig);
        vm.stopBroadcast();

        console2.log("    accruedInterest:", order.accruedInterest);
        _logTradeResult(taker, vm.addr(makerPk), snap, side);
    }

    function _logTradeResult(address taker, address maker, uint256[2] memory snapBefore, OrderSide side) internal view {
        uint256 takerNow = usdc.balanceOf(taker);
        uint256 makerNow = usdc.balanceOf(maker);
        if (side == OrderSide.BUY) {
            uint256 spent = snapBefore[0] - takerNow;
            uint256 received = makerNow - snapBefore[1];
            console2.log("    taker USDC spent:", spent);
            console2.log("    maker USDC received:", received);
            console2.log("    fee:", spent - received);
        } else {
            uint256 received = takerNow - snapBefore[0];
            uint256 spent = snapBefore[1] - makerNow;
            console2.log("    taker USDC received:", received);
            console2.log("    maker USDC spent:", spent);
            console2.log("    fee:", spent - received);
        }
    }

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
        Order memory order = _buildOrder(makerPk, taker, bondAmt, quoteAmt, side, block.timestamp + 1 days, salt);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill reverted as expected:", reason);
        }
    }

    function _rfqCancel(uint256 makerPk, address taker, uint256 bondAmt, uint256 quoteAmt, OrderSide side, uint256 salt)
        internal
    {
        Order memory order = _buildOrder(makerPk, taker, bondAmt, quoteAmt, side, block.timestamp + 1 days, salt);
        vm.startBroadcast(makerPk);
        settlement.cancelOrder(order);
        vm.stopBroadcast();

        bytes32 orderHash = settlement.hashOrder(order);
        console2.log("    Order cancelled, hash:");
        console2.logBytes32(orderHash);
    }

    function _rfqFillCancelledShouldFail(
        uint256 makerPk,
        uint256 takerPk,
        uint256 bondAmt,
        uint256 quoteAmt,
        OrderSide side,
        uint256 salt
    ) internal {
        address taker = vm.addr(takerPk);
        Order memory order = _buildOrder(makerPk, taker, bondAmt, quoteAmt, side, block.timestamp + 1 days, salt);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill cancelled order reverted as expected");
        }
    }

    function _rfqFillExpired(uint256 makerPk, uint256 takerPk, uint256 bondAmt, uint256 quoteAmt, OrderSide side)
        internal
    {
        address taker = vm.addr(takerPk);
        uint256 salt = _nextSalt++;
        Order memory order = _buildOrder(makerPk, taker, bondAmt, quoteAmt, side, block.timestamp - 1, salt);
        bytes memory sig = _signOrder(order, makerPk);

        vm.prank(taker);
        try settlement.fillOrder(order, sig) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Fill reverted as expected: ExpiredDeadline");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  原子操作：赎回
    // ═══════════════════════════════════════════════════════════════

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

    function _claimForShouldFail(uint256 callerPk, address holder, string memory reason) internal {
        vm.prank(vm.addr(callerPk));
        try issuance.claimFor(address(bondToken), holder) {
            console2.log("  [ERROR] Should have reverted!");
        } catch {
            console2.log("  claimFor reverted as expected:", reason);
        }
    }

    function _setClaimDelegate(uint256 holderPk, address delegateAddr) internal {
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

    function _signOrder(Order memory order, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _directTransferShouldFail(uint256 senderPk, address to, uint256 amount, string memory reason) internal {
        vm.prank(vm.addr(senderPk));
        try bondToken.transfer(to, amount) {
            console2.log("    [ERROR] Should have reverted!");
        } catch {
            console2.log("    Direct transfer reverted as expected:", reason);
        }
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
            string.concat("    ", name, " | bond: "), bondToken.balanceOf(account), "| USDC:", usdc.balanceOf(account)
        );
    }

    function _logComplete() internal view {
        console2.log("");
        console2.log("========================================");
        console2.log("  FINAL BALANCES (all participants)");
        console2.log("========================================");

        FeeConfig memory fc = settlement.feeConfig();

        console2.log("  --- Participants ---");
        _logBalance("issuer    ", issuer);
        _logBalance("makerA    ", makerA);
        _logBalance("makerB    ", makerB);
        _logBalance("makerC    ", makerC);
        _logBalance("investorA ", investorA);
        _logBalance("investorB ", investorB);
        _logBalance("investorC ", investorC);
        _logBalance("delegate  ", delegate);

        console2.log("  --- Platform ---");
        _logBalance("feeRecip  ", fc.feeRecipient);

        console2.log("  --- Contracts ---");
        console2.log("    Issuance   | USDC:", usdc.balanceOf(address(issuance)));
        console2.log("    Settlement | USDC:", usdc.balanceOf(address(settlement)));

        console2.log("");
        console2.log("========================================");
        console2.log("  ALL PHASES COMPLETED SUCCESSFULLY");
        console2.log("========================================");
    }
}
