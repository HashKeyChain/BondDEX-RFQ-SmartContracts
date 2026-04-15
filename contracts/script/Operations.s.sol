// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/console2.sol";

import { BondFactory } from "../src/BondFactory.sol";
import { BondIssuance } from "../src/BondIssuance.sol";
import { ComplianceModule } from "../src/compliance/ComplianceModule.sol";
import { RFQSettlement } from "../src/RFQSettlement.sol";
import { MockERC20Decimals } from "../test/mocks/MockERC20Decimals.sol";
import {
    ApprovalStatus,
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

import { BaseConfig } from "./BaseConfig.s.sol";

/// @title Operations
/// @notice 模块化操作脚本——每个函数对应一个链上操作，可独立调用。
/// @dev 适用于 Anvil / 测试网 / 主网。通过 deployments/{chainId}.json 自动读取合约地址。
///   调用者私钥通过 DEPLOYER_PRIVATE_KEY 环境变量传入（broadcast 身份）。
///
///   用法示例：
///   # Anvil
///   cd contracts && forge script script/Operations.s.sol:Operations \
///     --sig "approveIssuance(bytes32,address,uint256)" \
///     0x$(cast keccak "bond-001") 0x3C44...issuer 1735689600 \
///     --rpc-url http://127.0.0.1:8545 --broadcast
///
///   # 测试网
///   DEPLOYER_PRIVATE_KEY=0x... forge script script/Operations.s.sol:Operations \
///     --sig "queryRedemptionState(address)" 0xBondTokenAddr \
///     --rpc-url https://testnet.hsk.xyz
contract Operations is BaseConfig {
    // ─── 地址加载 ────────────────────────────────────────────────

    /// @dev 从 deployments/{chainId}.json 读取核心合约地址
    function _deployment()
        internal
        view
        returns (address factoryAddr, address issuanceAddr, address settlementAddr, address complianceImplAddr)
    {
        string memory path = string.concat(DEPLOYMENTS_ROOT, "/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        factoryAddr = vm.parseJsonAddress(json, ".contracts.bondFactory");
        issuanceAddr = vm.parseJsonAddress(json, ".contracts.bondIssuance");
        settlementAddr = vm.parseJsonAddress(json, ".contracts.rfqSettlement");
        complianceImplAddr = vm.parseJsonAddress(json, ".contracts.complianceImplementation");
    }

    /// @dev 获取 broadcast 私钥：优先 DEPLOYER_PRIVATE_KEY 环境变量
    function _senderPk() internal view returns (uint256) {
        return vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    /// @dev 获取 maker 签名时允许的最大手续费 bps，默认 100 (1%)。
    ///      通过 MAX_FEE_BPS 环境变量覆盖。
    function _orderMaxFeeBps() internal view returns (uint16) {
        try vm.envUint("MAX_FEE_BPS") returns (uint256 val) {
            require(val <= 10_000, "MAX_FEE_BPS exceeds 10000");
            return uint16(val);
        } catch {
            return 100;
        }
    }

    // ================================================================
    //  债券创建
    // ================================================================

    /// @notice 审批发行（ISSUANCE_APPROVER_ROLE 调用）
    /// @param approvalId 唯一审批 ID
    /// @param issuerAddr 发行人地址
    /// @param expiresAt 审批有效期 Unix 时间戳（0=永不过期）
    function approveIssuance(bytes32 approvalId, address issuerAddr, uint256 expiresAt) external {
        (address factoryAddr,,, address compImpl) = _deployment();
        BondFactory factory = BondFactory(factoryAddr);

        vm.startBroadcast(_senderPk());
        factory.approveIssuance(approvalId, issuerAddr, compImpl, expiresAt, keccak256("metadata"));
        vm.stopBroadcast();

        console2.log("Issuance approved:");
        console2.logBytes32(approvalId);
    }

    /// @notice 创建债券（发行人调用）
    /// @param approvalId 审批 ID（必须已审批且未消费）
    /// @param name_ 债券名称
    /// @param symbol_ 债券符号
    /// @param decimals_ 精度（0=整数 bond, 18=标准）
    /// @param faceValue_ 面值（结算代币最小单位）
    /// @param couponRateBps_ 年化票息率 bps（500=5%/年）
    /// @param maturityTimestamp_ 到期时间（Unix 时间戳）
    /// @param settlementToken_ 结算代币地址
    /// @param extendedData abi.encode(uint256 issueDate, uint8 dayCount, uint8 couponFreq, uint8 bondCategory, bytes12 isin)
    ///   - issueDate: 起息日（Unix 时间戳）
    ///   - dayCount: 计息惯例（0=ACT_365, 1=ACT_360）
    ///   - couponFreq: 付息频率（0=BULLET, 1=ANNUAL, 2=SEMI_ANNUAL, 3=QUARTERLY）
    ///   - bondCategory: 债券类别（0=CORPORATE, 1=GOVERNMENT, 2=CONVERTIBLE, 3=ABS）
    ///   - isin: ISIN 代码（12 字节，留空填 bytes12(0)）
    function createBond(
        bytes32 approvalId,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        uint256 faceValue_,
        uint256 couponRateBps_,
        uint256 maturityTimestamp_,
        address settlementToken_,
        bytes calldata extendedData
    ) external {
        uint256 pk = _senderPk();
        BondConfig memory config = _buildBondConfig(
            pk, name_, symbol_, decimals_, faceValue_, couponRateBps_, maturityTimestamp_, settlementToken_
        );
        _applyExtended(config, extendedData);
        _executeBondCreation(config, approvalId, pk);
    }

    function _applyExtended(BondConfig memory config, bytes calldata data) internal pure {
        (uint256 d, uint8 dc, uint8 f, uint8 c, bytes12 i) = abi.decode(data, (uint256, uint8, uint8, uint8, bytes12));
        config.issueDate = d;
        config.dayCountConvention = DayCount(dc);
        config.couponFrequency = CouponFrequency(f);
        config.bondCategory = BondCategory(c);
        config.isin = i;
    }

    function _buildBondConfig(
        uint256 pk,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        uint256 faceValue_,
        uint256 couponRateBps_,
        uint256 maturityTimestamp_,
        address settlementToken_
    ) internal view returns (BondConfig memory config) {
        (,,, address compImpl) = _deployment();
        config.issuer = vm.addr(pk);
        config.name = name_;
        config.symbol = symbol_;
        config.decimals = decimals_;
        config.faceValue = faceValue_;
        config.couponRateBps = couponRateBps_;
        config.maturityTimestamp = maturityTimestamp_;
        config.settlementToken = settlementToken_;
        config.settlementTokenDecimals = 6;
        config.complianceImplementation = compImpl;
        config.policyId = keccak256("policy");
        config.policyVersion = 1;
    }

    function _executeBondCreation(BondConfig memory config, bytes32 approvalId, uint256 pk) internal {
        (address factoryAddr,,,) = _deployment();

        vm.startBroadcast(pk);
        (address bt, address cm) = BondFactory(factoryAddr).createBond(config, approvalId);
        vm.stopBroadcast();

        console2.log("Bond created:");
        console2.log("  BondToken:       ", bt);
        console2.log("  ComplianceModule:", cm);
    }

    // ================================================================
    //  合规配置
    // ================================================================

    /// @notice 设置单个地址白名单
    function setWhitelist(address complianceModuleAddr, address account, bool allowed) external {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);
        vm.startBroadcast(_senderPk());
        cm.setWhitelist(account, allowed);
        vm.stopBroadcast();
        console2.log("Whitelist set:", account, allowed);
    }

    /// @notice 批量设置白名单
    function batchSetWhitelist(address complianceModuleAddr, address[] calldata accounts, bool[] calldata allowed)
        external
    {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);
        vm.startBroadcast(_senderPk());
        cm.batchSetWhitelist(accounts, allowed);
        vm.stopBroadcast();
        console2.log("Batch whitelist set:", accounts.length, "accounts");
    }

    /// @notice 设置单个地址角色（0=NONE, 1=ISSUER, 2=MARKET_MAKER, 3=INVESTOR）
    function setRole(address complianceModuleAddr, address account, uint8 role) external {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);
        vm.startBroadcast(_senderPk());
        cm.setRole(account, Role(role));
        vm.stopBroadcast();
        console2.log("Role set:", account, role);
    }

    /// @notice 批量设置角色
    function batchSetRole(address complianceModuleAddr, address[] calldata accounts, uint8[] calldata roles) external {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);

        Role[] memory roleEnums = new Role[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            roleEnums[i] = Role(roles[i]);
        }

        vm.startBroadcast(_senderPk());
        cm.batchSetRole(accounts, roleEnums);
        vm.stopBroadcast();
        console2.log("Batch role set:", accounts.length, "accounts");
    }

    /// @notice 注册/撤销授权转账 operator（COMPLIANCE_ADMIN_ROLE 调用）
    function setTransferOperator(address complianceModuleAddr, address operatorAddr, bool authorized) external {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);
        vm.startBroadcast(_senderPk());
        cm.setTransferOperator(operatorAddr, authorized);
        vm.stopBroadcast();
        console2.log("Transfer operator", operatorAddr, authorized ? "authorized" : "revoked");
    }

    // ================================================================
    //  一级认购
    // ================================================================

    /// @notice 审批认购窗口（ISSUANCE_APPROVER_ROLE 调用）
    /// @param approvalId 唯一审批 ID
    /// @param issuerAddr 发行人地址
    /// @param bondTokenAddr 债券代币地址
    /// @param maxUnits 最大发行量上限
    /// @param expiresAt 审批有效期 Unix 时间戳（0=永不过期）
    function approveSubscription(
        bytes32 approvalId,
        address issuerAddr,
        address bondTokenAddr,
        uint256 maxUnits,
        uint256 expiresAt
    ) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.approveSubscription(approvalId, issuerAddr, bondTokenAddr, maxUnits, expiresAt);
        vm.stopBroadcast();

        console2.log("Subscription approved:");
        console2.logBytes32(approvalId);
    }

    /// @notice 撤销认购审批（ISSUANCE_APPROVER_ROLE 调用）
    function revokeSubscriptionApproval(bytes32 approvalId) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.revokeSubscriptionApproval(approvalId);
        vm.stopBroadcast();

        console2.log("Subscription approval revoked:");
        console2.logBytes32(approvalId);
    }

    /// @notice 创建认购窗口（发行人调用，需先审批）
    function createSubscription(
        address bondTokenAddr,
        address settlementTokenAddr,
        uint256 unitPrice,
        uint256 maxUnits,
        uint256 opensAt,
        uint256 closesAt,
        bytes32 approvalId
    ) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        SubscriptionTerms memory terms = SubscriptionTerms({
            bondToken: bondTokenAddr,
            settlementToken: settlementTokenAddr,
            unitPrice: unitPrice,
            maxUnits: maxUnits,
            opensAt: opensAt,
            closesAt: closesAt
        });

        vm.startBroadcast(_senderPk());
        bytes32 offerId = iss.createSubscription(terms, approvalId);
        vm.stopBroadcast();

        console2.log("Subscription created:");
        console2.logBytes32(offerId);
    }

    /// @notice 认购（做市商调用）
    function subscribe(bytes32 offerId, uint256 units) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.subscribe(offerId, units);
        vm.stopBroadcast();

        console2.log("Subscribed", units, "units to offer:");
        console2.logBytes32(offerId);
    }

    /// @notice 关闭认购窗口（发行人调用）
    function closeSubscription(bytes32 offerId) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.closeSubscription(offerId);
        vm.stopBroadcast();

        console2.log("Subscription closed:");
        console2.logBytes32(offerId);
    }

    // ================================================================
    //  二级市场 RFQ
    // ================================================================

    /// @notice 执行 RFQ 订单（taker 调用）
    /// @dev maker 签名需通过 MAKER_PRIVATE_KEY 环境变量传入
    /// @param makerAddr maker 地址
    /// @param takerAddr taker 地址（0x0=任何人）
    /// @param bondTokenAddr 债券地址
    /// @param quoteTokenAddr 报价代币地址
    /// @param bondAmount 债券数量
    /// @param quoteAmount 报价数量
    /// @param side 0=BUY, 1=SELL
    /// @param expiry 过期时间
    /// @param nonce maker nonce
    /// @param salt 随机盐
    /// @param accruedInterest 应计利息（结算代币最小单位）
    function fillOrder(
        address makerAddr,
        address takerAddr,
        address bondTokenAddr,
        address quoteTokenAddr,
        uint256 bondAmount,
        uint256 quoteAmount,
        uint8 side,
        uint256 expiry,
        uint256 nonce,
        uint256 salt,
        uint256 accruedInterest
    ) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        Order memory order = Order({
            maker: makerAddr,
            taker: takerAddr,
            bondToken: bondTokenAddr,
            quoteToken: quoteTokenAddr,
            bondAmount: bondAmount,
            quoteAmount: quoteAmount,
            side: OrderSide(side),
            expiry: expiry,
            nonce: nonce,
            salt: salt,
            maxFeeBps: _orderMaxFeeBps(),
            accruedInterest: accruedInterest
        });

        uint256 makerPk = vm.envUint("MAKER_PRIVATE_KEY");
        bytes32 digest = stl.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startBroadcast(_senderPk());
        stl.fillOrder(order, sig);
        vm.stopBroadcast();

        console2.log("Order filled:");
        console2.logBytes32(digest);
    }

    /// @notice 取消订单（maker 调用）
    function cancelOrder(
        address makerAddr,
        address takerAddr,
        address bondTokenAddr,
        address quoteTokenAddr,
        uint256 bondAmount,
        uint256 quoteAmount,
        uint8 side,
        uint256 expiry,
        uint256 nonce,
        uint256 salt,
        uint256 accruedInterest
    ) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        Order memory order = Order({
            maker: makerAddr,
            taker: takerAddr,
            bondToken: bondTokenAddr,
            quoteToken: quoteTokenAddr,
            bondAmount: bondAmount,
            quoteAmount: quoteAmount,
            side: OrderSide(side),
            expiry: expiry,
            nonce: nonce,
            salt: salt,
            maxFeeBps: _orderMaxFeeBps(),
            accruedInterest: accruedInterest
        });

        vm.startBroadcast(_senderPk());
        stl.cancelOrder(order);
        vm.stopBroadcast();

        bytes32 orderHash = stl.hashOrder(order);
        console2.log("Order cancelled:");
        console2.logBytes32(orderHash);
    }

    /// @notice 递增 nonce floor（maker 调用）
    function incrementNonce() external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        uint256 pk = _senderPk();
        address sender = vm.addr(pk);

        vm.startBroadcast(pk);
        stl.incrementNonce();
        vm.stopBroadcast();

        console2.log("Nonce incremented, new floor:", stl.currentNonce(sender));
    }

    /// @notice 设置最小 nonce（maker 调用）
    function setMinimumNonce(uint256 newMin) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        vm.startBroadcast(_senderPk());
        stl.setMinimumNonce(newMin);
        vm.stopBroadcast();

        console2.log("Minimum nonce set to:", newMin);
    }

    // ================================================================
    //  到期赎回
    // ================================================================

    /// @notice 发行人存入赎回资金
    function depositRedemption(address bondTokenAddr, uint256 amount) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.depositRedemption(bondTokenAddr, amount);
        vm.stopBroadcast();

        console2.log("Redemption deposited:", amount);
    }

    /// @notice 持有人领取赎回款
    function claim(address bondTokenAddr) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.claim(bondTokenAddr);
        vm.stopBroadcast();

        console2.log("Claim executed for bond:", bondTokenAddr);
    }

    /// @notice 代理领取赎回款（资金打给 holder）
    function claimFor(address bondTokenAddr, address holder) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.claimFor(bondTokenAddr, holder);
        vm.stopBroadcast();

        console2.log("ClaimFor executed for holder:", holder);
    }

    /// @notice 设置领取代理人
    function setClaimDelegate(address delegateAddr) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.setClaimDelegate(delegateAddr);
        vm.stopBroadcast();

        console2.log("Claim delegate set:", delegateAddr);
    }

    // ================================================================
    //  运维操作
    // ================================================================

    /// @notice 暂停/恢复 Factory 域（PAUSER_ROLE 调用）
    function pauseDomainFactory(uint8 domain, bool paused) external {
        (address factoryAddr,,,) = _deployment();
        BondFactory f = BondFactory(factoryAddr);

        vm.startBroadcast(_senderPk());
        f.pauseDomain(PauseDomain(domain), paused);
        vm.stopBroadcast();

        console2.log("Factory domain", domain, paused ? "paused" : "unpaused");
    }

    /// @notice 暂停/恢复 Issuance 域（PAUSER_ROLE 调用）
    function pauseDomainIssuance(uint8 domain, bool paused) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.pauseDomain(PauseDomain(domain), paused);
        vm.stopBroadcast();

        console2.log("Issuance domain", domain, paused ? "paused" : "unpaused");
    }

    /// @notice 暂停/恢复 Settlement 域（PAUSER_ROLE 调用）
    function pauseDomainSettlement(uint8 domain, bool paused) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        vm.startBroadcast(_senderPk());
        stl.pauseDomain(PauseDomain(domain), paused);
        vm.stopBroadcast();

        console2.log("Settlement domain", domain, paused ? "paused" : "unpaused");
    }

    /// @notice 暂停/恢复 ComplianceModule 域（PAUSER_ROLE 调用）
    function pauseDomainCompliance(address complianceModuleAddr, uint8 domain, bool paused) external {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);

        vm.startBroadcast(_senderPk());
        cm.pauseDomain(PauseDomain(domain), paused);
        vm.stopBroadcast();

        console2.log("Compliance domain", domain, paused ? "paused" : "unpaused");
    }

    /// @notice 注册/注销债券代币用于 RFQ 交易（SETTLEMENT_ADMIN_ROLE 调用）
    function setBondTokenRegistration(address bondTokenAddr, bool registered) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        vm.startBroadcast(_senderPk());
        stl.setBondTokenRegistration(bondTokenAddr, registered);
        vm.stopBroadcast();

        console2.log("Bond token", bondTokenAddr, registered ? "registered" : "unregistered");
    }

    /// @notice 更新 RFQ 手续费配置（SETTLEMENT_ADMIN_ROLE 调用）
    function setFeeConfig(address feeRecipient, uint16 currentFeeBps, uint16 maxFeeBps) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        vm.startBroadcast(_senderPk());
        stl.setFeeConfig(FeeConfig({ feeRecipient: feeRecipient, currentFeeBps: currentFeeBps, maxFeeBps: maxFeeBps }));
        vm.stopBroadcast();

        console2.log("Fee config updated:", currentFeeBps, "bps");
    }

    /// @notice 设置应计利息容差窗口（SETTLEMENT_ADMIN_ROLE 调用）
    function setAiToleranceSeconds(uint256 toleranceSeconds) external {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);
        vm.startBroadcast(_senderPk());
        stl.setAiToleranceSeconds(toleranceSeconds);
        vm.stopBroadcast();
        console2.log("AI tolerance set to:", toleranceSeconds, "seconds");
    }

    /// @notice 紧急代币救援（DEFAULT_ADMIN_ROLE 调用）
    function rescueTokens(address token, address to, uint256 amount) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.rescueTokens(token, to, amount);
        vm.stopBroadcast();

        console2.log("Tokens rescued:", amount);
    }

    /// @notice 释放超额赎回负债（DEFAULT_ADMIN_ROLE 调用，债券到期后）
    function releaseExcessRedemption(address bondTokenAddr) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.releaseExcessRedemption(bondTokenAddr);
        vm.stopBroadcast();

        console2.log("Excess redemption released for bond:", bondTokenAddr);
    }

    /// @notice ERC-20 approve（通用工具，适用于任何代币）
    function approveToken(address token, address spender, uint256 amount) external {
        vm.startBroadcast(_senderPk());
        IERC20(token).approve(spender, amount);
        vm.stopBroadcast();

        console2.log("Approved", spender, "to spend", amount);
    }

    /// @notice Mock USDC 铸造（仅 Anvil 环境，测试网/主网调用会 revert）
    function mintMockUSDC(address to, uint256 amount) external {
        require(block.chainid == 31337, "mintMockUSDC: Anvil only");

        string memory path = string.concat(DEPLOYMENTS_ROOT, "/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address tokenAddr = vm.parseJsonAddress(json, ".configuration.settlementTokens[0].token");

        vm.startBroadcast(_senderPk());
        MockERC20Decimals(tokenAddr).mint(to, amount);
        vm.stopBroadcast();

        console2.log("Minted", amount, "mock USDC to", to);
    }

    // ================================================================
    //  查询（只读，不需要 broadcast）
    // ================================================================

    /// @notice 查询订单状态
    function queryOrderStatus(bytes32 orderHash) external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        bool consumed = stl.isOrderConsumed(orderHash);
        bool cancelled = stl.isOrderCancelled(orderHash);

        console2.log("Order status:");
        console2.log("  consumed: ", consumed);
        console2.log("  cancelled:", cancelled);
    }

    /// @notice 查询赎回状态
    function queryRedemptionState(address bondTokenAddr) external view {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        (uint256 fundedAmount, uint256 claimedAmount, uint256 lastFundingAt) = iss.getRedemptionState(bondTokenAddr);

        console2.log("Redemption state:");
        console2.log("  funded:       ", fundedAmount);
        console2.log("  claimed:      ", claimedAmount);
        console2.log("  lastFundingAt:", lastFundingAt);
    }

    /// @notice 查询认购信息
    function querySubscription(bytes32 offerId) external view {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        (
            address bt,
            address st,
            uint256 unitPrice,
            uint256 maxUnits,
            uint256 soldUnits,
            uint256 opensAt,
            uint256 closesAt,
            uint8 status
        ) = iss.getSubscription(offerId);

        console2.log("Subscription info:");
        console2.log("  bondToken:      ", bt);
        console2.log("  settlementToken:", st);
        console2.log("  unitPrice:      ", unitPrice);
        console2.log("  maxUnits:       ", maxUnits);
        console2.log("  soldUnits:      ", soldUnits);
        console2.log("  opensAt:        ", opensAt);
        console2.log("  closesAt:       ", closesAt);
        console2.log("  status:         ", status);
    }

    /// @notice 查询白名单与角色
    function queryCompliance(address complianceModuleAddr, address account) external view {
        ComplianceModule cm = ComplianceModule(complianceModuleAddr);

        bool whitelisted = cm.isWhitelisted(account);
        Role role = cm.roleOf(account);

        console2.log("Compliance query for", account);
        console2.log("  whitelisted:", whitelisted);
        console2.log("  role:       ", uint8(role));
    }

    /// @notice 查询手续费配置
    function queryFeeConfig() external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        FeeConfig memory fc = stl.feeConfig();
        console2.log("Fee config:");
        console2.log("  feeRecipient: ", fc.feeRecipient);
        console2.log("  currentFeeBps:", fc.currentFeeBps);
        console2.log("  maxFeeBps:    ", fc.maxFeeBps);
    }

    /// @notice 查询应计利息容差
    function queryAiTolerance() external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);
        uint256 tolerance = stl.aiToleranceSeconds();
        console2.log("AI tolerance:", tolerance, "seconds");
    }

    /// @notice 查询 maker nonce
    function queryNonce(address makerAddr) external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        uint256 nonce = stl.currentNonce(makerAddr);
        console2.log("Current nonce for", makerAddr, ":", nonce);
    }

    /// @notice 查询债券代币是否已注册
    function queryBondTokenRegistration(address bondTokenAddr) external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        bool registered = stl.isBondTokenRegistered(bondTokenAddr);
        console2.log("Bond token", bondTokenAddr, "registered:", registered);
    }

    /// @notice 预估手续费（基于 dirty amount = quoteAmount + accruedInterest）
    function queryFee(address bondTokenAddr, address partyA, address partyB, uint256 dirtyAmount) external view {
        (,, address settlementAddr,) = _deployment();
        RFQSettlement stl = RFQSettlement(settlementAddr);

        uint256 fee = stl.quoteFee(bondTokenAddr, partyA, partyB, dirtyAmount);
        console2.log("Estimated fee:", fee);
    }

    /// @notice 查询 ERC20 余额
    function queryBalance(address token, address account) external view {
        uint256 balance = IERC20(token).balanceOf(account);
        console2.log("Balance of", account, ":", balance);
    }

    /// @notice 批量查询 bond + USDC 余额
    /// @dev 需传入 bondToken 地址，USDC 地址从 deployments JSON 获取
    function queryBondBalances(address bondTokenAddr, address[] calldata accounts) external view {
        string memory path = string.concat(DEPLOYMENTS_ROOT, "/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address usdcAddr = vm.parseJsonAddress(json, ".configuration.settlementTokens[0].token");

        console2.log("Bond & USDC balances:");
        for (uint256 i = 0; i < accounts.length; i++) {
            console2.log("  account:", accounts[i]);
            console2.log("    bond:", IERC20(bondTokenAddr).balanceOf(accounts[i]));
            console2.log("    USDC:", IERC20(usdcAddr).balanceOf(accounts[i]));
        }
    }

    /// @notice 查询认购剩余额度
    function queryRemainingUnits(bytes32 offerId) external view {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        (,,, uint256 maxUnits, uint256 soldUnits,,, uint8 status) = iss.getSubscription(offerId);

        uint256 remaining = maxUnits - soldUnits;
        console2.log("Subscription remaining:");
        console2.log("  maxUnits: ", maxUnits);
        console2.log("  soldUnits:", soldUnits);
        console2.log("  remaining:", remaining);
        console2.log("  status:   ", status);
    }

    /// @notice 标记已过期的发行审批（任何人可调用）
    function markIssuanceExpired(bytes32 approvalId) external {
        (address factoryAddr,,,) = _deployment();
        BondFactory f = BondFactory(factoryAddr);

        vm.startBroadcast(_senderPk());
        f.markIssuanceExpired(approvalId);
        vm.stopBroadcast();

        console2.log("Issuance approval marked expired:");
        console2.logBytes32(approvalId);
    }

    /// @notice 标记已过期的认购审批（任何人可调用）
    function markSubscriptionExpired(bytes32 approvalId) external {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        vm.startBroadcast(_senderPk());
        iss.markSubscriptionExpired(approvalId);
        vm.stopBroadcast();

        console2.log("Subscription approval marked expired:");
        console2.logBytes32(approvalId);
    }

    /// @notice 查询认购审批
    function querySubscriptionApproval(bytes32 approvalId) external view {
        (, address issuanceAddr,,) = _deployment();
        BondIssuance iss = BondIssuance(issuanceAddr);

        (address issuerAddr, address bondTokenAddr, uint256 maxUnits, uint256 expiresAt, ApprovalStatus status) =
            iss.getSubscriptionApproval(approvalId);

        console2.log("Subscription approval info:");
        console2.log("  issuer:   ", issuerAddr);
        console2.log("  bondToken:", bondTokenAddr);
        console2.log("  maxUnits: ", maxUnits);
        console2.log("  expiresAt:", expiresAt);
        console2.log("  status:   ", uint8(status));
    }
}
