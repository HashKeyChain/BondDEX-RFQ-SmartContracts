# BondDEX Event Interface Notes

## Version

- ABI/Event package version: `0.3.0`
- Change type: **MAJOR** — external audit hardening batch (N1–N18) + ABI cleanup. EIP-712 domain `version` field is unchanged at `"1"`; signatures created against `0.2.0` deployments remain valid only if the chain's RFQSettlement instance has not been upgraded.

> **破坏性变更（MAJOR）— v0.3.0：**
> - `BondFactory.createBond` 现在强制 `keccak256(abi.encode(BondConfig)) == approval.metadataHash`（AUDIT-FIX N3）。审批方与发行人必须使用 `BondFactory.hashBondConfig(BondConfig)` 取得规范哈希后再 approve / create。新增 `BondConfigHashMismatch(bytes32 expected, bytes32 provided)` error。
> - `BondToken.ConstructorParams` 新增 `uint8 settlementTokenDecimals` 字段（AUDIT-FIX N13）；构造期会与 `IERC20Metadata(settlementToken).decimals()` 严格比对。
> - `BondToken` 新增高精度计息 helper：`accruedInterestFor(uint256 bondAmount, uint256 timestamp) view → uint256` 与 `principalOf(uint256 bondAmount) view → uint256`，以及 `settlementTokenDecimals() view → uint8`（AUDIT-FIX N7 / N13）。**旧的 `accruedInterestPerUnit(uint256 timestamp)` 已在 v0.3.0 删除**——所有"per-unit"展示场景请用 `accruedInterestFor(10 ** decimals(), timestamp)` 替代（数学等价且精度更高）。
> - `RFQSettlement._validateOrder` 强制 `order.quoteToken == bondToken.settlementToken()`（AUDIT-FIX N1）。新增 `QuoteTokenMismatch(address quoteToken, address settlementToken)` error。
> - `RFQSettlement` 新增 `refreshDomainSeparator()`（AUDIT-FIX N15）+ `DomainSeparatorRefreshed` 事件。UUPS 升级后管理员必须立即调用以刷新 EIP-712 缓存。
> - `RFQSettlement.initialize` 现在用 `InvalidBasisPoints(value)` 而非 `InvalidFeeConfig(0, value)` 来拒绝越界 maxFeeBps（AUDIT-FIX N16）。
> - `BondIssuance` 新增 `forceRedeem(address bondToken, address holder, address recipient)`（AUDIT-FIX N5）+ `ForceRedemption` 事件。
> - `BondIssuance.releaseExcessRedemption` 与 `_claimFor` 的全员赎回自动释放分支现在**直接 `safeTransfer` 把超额转回 `bondToken.issuer()`**（AUDIT-FIX N6）。新增 `ExcessRedemptionRefunded` 事件。
> - `BondIssuance.setSettlementTokenPolicy` 签名由 4 参 → 3 参（删除冗余的 `enabledForSettlement`，N1 后已与 RFQ 准入解耦）：`(address token, bool enabledForIssuance, bool enabledForRedemption)`。`SettlementTokenPolicyUpdated` 事件同步减一字段。`getSettlementTokenPolicy` 返回值由 `(bool, bool, bool)` → `(bool, bool)`。
> - `BondIssuance.setSettlementTokenPolicy` 在 `_totalRedemptionLiability[token] > 0` 时禁止关闭 redemption 通道（AUDIT-FIX N11）。新增 `SettlementTokenHasRedemptionLiability(address, uint256)` error。
> - `BondIssuance._claimFor` 现在允许 dust 持仓（payout==0）销毁通过，不再 revert `ZeroAmount`（AUDIT-FIX N9）。
> - `BondIssuance.createSubscription` 新增校验：`terms.closesAt <= approval.expiresAt`（AUDIT-FIX N10）。新增 `SubscriptionWindowExceedsApprovalExpiry(uint256, uint256)` error。
> - **最小权限初始化（AUDIT-FIX N11 revisited）**：`BondFactory` 构造函数、`BondIssuance.initialize`、`RFQSettlement.initialize` 现在**只**给初始 admin grant `DEFAULT_ADMIN_ROLE`。后续次级角色（ISSUANCE_APPROVER / COMPLIANCE_ADMIN / SETTLEMENT_ADMIN / PAUSER / UPGRADER）必须通过标准 `AccessControl.grantRole` 显式授予。`BondFactory.setPlatformAdmin` 已纯化为 storage-only，不再触碰任何 AccessControl 角色。
> - `CouponFrequency` 枚举从 4 变体收窄为 2：`enum CouponFrequency { BULLET, ANNUAL }`（删除 `SEMI_ANNUAL`、`QUARTERLY`）。
>
> **下游需要做的事：**
> - 重新生成 wagmi typings 与 `abigen` Go bindings；
> - Subgraph mappings：
>   - `SettlementTokenPolicyUpdated`（BondIssuance）handler 减一参；
>   - 新增 `ExcessRedemptionRefunded` / `ForceRedemption` / `DomainSeparatorRefreshed` handler；
> - 前端 BondConfig 提交流程必须先调 `BondFactory.hashBondConfig(config)` 取 hash，再让审批方提交；
> - **链下计算迁移**：`accruedInterestPerUnit(ts)` 已被删除；调用方需改写为 `accruedInterestFor(10 ** decimals(), ts)`（语义等价、精度更优），或直接用 `accruedInterestFor(amount, ts)` 拿任意持仓的总应计利息；
> - RFQ 订单构造器：把 `quoteToken` 默认派生为 `bondToken.settlementToken()`，禁止人工填写。

## Contract Event Coverage

### BondFactory

- `IssuanceApproved`
- `IssuanceRevoked`
- `IssuanceApprovalExpired`
- `ComplianceImplementationRegistered`
- `PlatformAdminUpdated` — 现在仅伴随 `platformAdmin` storage 更新发出，不再表示 AccessControl 角色变化（v0.3.0 起）
- `BondCreated` — 核心债券标识事件（含 `issueDate`）
- `BondMetadata` — 与 `BondCreated` 同一交易内发出，承载扩展属性
- `PauseDomainUpdated`

#### IssuanceApproved

```solidity
event IssuanceApproved(
    bytes32 indexed approvalId,
    address indexed issuer,
    address approver,
    uint256 expiresAt,
    address complianceImplementation,
    bytes32 metadataHash       // = keccak256(abi.encode(BondConfig)) — AUDIT-FIX N3
);
```

#### BondCreated（注意：实际事件签名以下三个字段全部 indexed）

```solidity
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
    address settlementToken,
    uint256 issueDate
);
```

> 与 v0.2.0 文档中错误标注的 `bytes32 indexed approvalId` 字段不同——真实事件没有 `approvalId` 字段。`approvalId → bondToken` 的映射通过 `BondFactory.getBondAddresses(approvalId)` 查询。

#### BondMetadata

```solidity
event BondMetadata(
    address indexed bondToken,
    uint8 dayCountConvention,    // 0=ACT_365, 1=ACT_360
    uint8 couponFrequency,       // 0=BULLET, 1=ANNUAL（v0.3.0 起 SEMI_ANNUAL/QUARTERLY 已删除）
    uint8 bondCategory,          // 0=CORPORATE, 1=GOVERNMENT, 2=CONVERTIBLE, 3=ABS
    bytes12 isin                 // 国际证券识别码（留空为 bytes12(0)）
);
```

### ComplianceModule

- `WhitelistUpdated`
- `RoleUpdated`
- `BondTokenBound`
- `PolicyMetadataUpdated`
- `TransferOperatorUpdated`
- `PauseDomainUpdated`

#### TransferOperatorUpdated

```solidity
event TransferOperatorUpdated(
    address indexed bondToken,
    address indexed operator,
    bool authorized,
    address admin
);
```

### BondIssuance

- `SettlementTokenPolicyUpdated` — **签名变更**（v0.3.0 减一字段）
- `SubscriptionApproved`
- `SubscriptionApprovalRevoked`
- `SubscriptionApprovalExpired`
- `SubscriptionCreated`
- `Subscribed`
- `SubscriptionClosed`
- `RedemptionDeposited`
- `RedemptionClaimed`
- `TokensRescued`
- `ExcessRedemptionReleased` — 内部账户调减事件
- `ExcessRedemptionRefunded` — **新增 v0.3.0**，伴随 `ExcessRedemptionReleased` 同时发出，标志 settlement token 已实际 transfer 给 issuer（AUDIT-FIX N6）
- `ForceRedemption` — **新增 v0.3.0**（AUDIT-FIX N5）
- `ClaimDelegateSet`
- `PauseDomainUpdated`

#### SettlementTokenPolicyUpdated（签名变更，v0.3.0）

```solidity
// v0.3.0
event SettlementTokenPolicyUpdated(
    address indexed token,
    bool issuanceEnabled,
    bool redemptionEnabled,
    address operator
);

// v0.2.0（参考用，已弃用）
// event SettlementTokenPolicyUpdated(
//     address indexed token, bool issuanceEnabled, bool settlementEnabled, bool redemptionEnabled, address operator
// );
```

> v0.3.0 删除了僵尸字段 `settlementEnabled`——它在 v0.2.0 合约里没有任何 `require` 用处，与 RFQ 准入完全无关（RFQ 准入由 `RFQSettlement.SettlementTokenPolicyUpdated` 独立管理）。Subgraph handler 必须减一参。

#### ExcessRedemptionRefunded（新增 v0.3.0）

```solidity
event ExcessRedemptionRefunded(
    address indexed bondToken,
    address indexed settlementToken,
    address indexed issuer,
    uint256 excessAmount
);
```

> 自审计修复批次起，`releaseExcessRedemption` 与全员赎回触发的自动释放分支都会**原子地**把超额 settlement token transfer 给 `bondToken.issuer()`，并发出此事件。运维侧应监听 `ExcessRedemptionRefunded`（而非旧版本的 `ExcessRedemptionReleased`）做对账，因为后者只表示账面调减、不等于资金实际转出。

#### ForceRedemption（新增 v0.3.0）

```solidity
event ForceRedemption(
    address indexed bondToken,
    address indexed holder,
    address indexed recipient,
    uint256 bondAmount,
    uint256 payout,
    address operator
);
```

> 当合规专员通过 `forceRedeem(bondToken, holder, recipient)` 强制赎回受制裁/被永久移出白名单的持有人时发出。`recipient` 通常是监管托管账户或发行人钱包。运维侧应将此事件接入合规审计 trail。

### RFQSettlement

- `FeeConfigUpdated`
- `SettlementTokenPolicyUpdated` — RFQ 层独立的单币熔断开关（与 BondIssuance 同名事件无关）
- `BondTokenRegistrationUpdated`
- `OrderFilled` — 包含 `accruedInterest` 和 `feeRecipient`
- `OrderCancelled`
- `NonceIncremented`
- `AiToleranceUpdated`
- `TokensRescued`
- `DomainSeparatorRefreshed` — **新增 v0.3.0**（AUDIT-FIX N15）
- `PauseDomainUpdated`

#### OrderFilled（实际事件签名，按代码真值）

```solidity
event OrderFilled(
    bytes32 indexed orderHash,
    address indexed maker,
    address indexed taker,
    address bondToken,
    address quoteToken,         // AUDIT-FIX N1: 强制等于 bondToken.settlementToken()
    uint8 side,                 // 0=BUY, 1=SELL
    uint256 bondAmount,
    uint256 quoteAmount,        // 净额（不含应计利息）
    uint256 accruedInterest,    // 应计利息（settlementToken 最小单位，由 BondToken.accruedInterestFor 计算）
    uint256 feeAmount,          // 基于 dirtyAmount = quoteAmount + accruedInterest 计算
    address feeRecipient
);
```

> 与 v0.2.0 文档中错误的字段顺序不同——真实事件的 `side` 在中间、`feeAmount` 在 `accruedInterest` 之后、并包含 `feeRecipient` 字段。请以本文为准重新生成 typings。

#### AiToleranceUpdated

```solidity
event AiToleranceUpdated(uint256 newToleranceSeconds, address operator);
```

> 注意：v0.2.0 文档中误写为 `(uint256 oldToleranceSeconds, uint256 newToleranceSeconds)`——真实事件只有 `newToleranceSeconds + operator`。

#### DomainSeparatorRefreshed（新增 v0.3.0）

```solidity
event DomainSeparatorRefreshed(
    uint256 chainId,
    bytes32 domainSeparator,
    address indexed operator
);
```

> 当管理员调用 `refreshDomainSeparator()` 重新计算并覆盖 EIP-712 缓存后发出。前端在 UUPS 升级后应监听该事件，确保链下签名所用的 domain separator 与链上保持一致。

### BondToken

- 标准 ERC-20 `Transfer`
- 无自定义事件（合规与赎回事件由 ComplianceModule / BondIssuance 发出）

#### Transfer Restriction Codes

| Code | 常量 | 含义 |
|------|------|------|
| 0 | `SUCCESS` | 转账允许 |
| 1 | `BOND_TOKEN_NOT_BOUND` | ComplianceModule 未绑定 BondToken |
| 2 | `SENDER_NOT_WHITELISTED` | 发送方不在白名单中 |
| 3 | `RECEIVER_NOT_WHITELISTED` | 接收方不在白名单中 |
| 4 | `INVALID_SENDER_ROLE` | 发送方角色不符 |
| 5 | `INVALID_RECEIVER_ROLE` | 接收方角色不符 |
| 6 | `INVALID_DIRECTION` | 禁止的转账方向（投资者→投资者） |
| 7 | `TRANSFERS_PAUSED` | 转账已暂停 |
| 8 | `UNAUTHORIZED_OPERATOR` | 转账发起方不是授权的 operator（用户不能私下直接转账） |

> **链下预检**：前端使用 `detectTransferRestriction(from, to, amount, operator)` 四参数重载版本（传入 RFQSettlement 地址作为 operator）来准确判断交易是否可行。三参数版本会使用 `msg.sender` 作为 operator，链下静态调用时会返回 code 8。

## Read-only View Functions（v0.3.0 新增 / 关键变更）

这些不是事件，但下游索引/前端构造时需要。

### BondFactory

```solidity
/// AUDIT-FIX N3: 接收一份 BondConfig，返回审批方与发行人必须使用的规范哈希。
function hashBondConfig(BondConfig calldata config) external pure returns (bytes32);
```

### BondToken

```solidity
/// AUDIT-FIX N13: 返回构造时校验过的 settlement token decimals（值与 IERC20Metadata(settlementToken).decimals() 一致）。
function settlementTokenDecimals() external view returns (uint8);

/// AUDIT-FIX N13: bondAmount 对应的本金（结算代币最小单位）。
function principalOf(uint256 bondAmount) external view returns (uint256);

/// AUDIT-FIX N7: 高精度的应计利息总额，使用延迟除法的 mulDiv 公式。
/// v0.3.0 起这是 BondToken 唯一的应计利息接口；legacy `accruedInterestPerUnit` 已删除。
/// 想要"per-unit"展示值时调用：accruedInterestFor(10 ** decimals(), timestamp)
function accruedInterestFor(uint256 bondAmount, uint256 timestamp) external view returns (uint256);
```

### BondIssuance

```solidity
/// 签名变更：v0.2.0 是 (address, bool, bool, bool)，v0.3.0 删了 settlementEnabled。
function setSettlementTokenPolicy(address token, bool enabledForIssuance, bool enabledForRedemption) external;
function getSettlementTokenPolicy(address token) external view returns (bool issuanceEnabled, bool redemptionEnabled);

/// AUDIT-FIX N5：合规管理员强制赎回受制裁持有人。
function forceRedeem(address bondToken, address holder, address recipient) external;
```

### RFQSettlement

```solidity
/// AUDIT-FIX N15: UUPS 升级后由 admin 调用以刷新 EIP-712 缓存。
function refreshDomainSeparator() external;
```

## Consumer Notes

- **Frontend**：
  - 构造 `BondConfig` 后必须先调 `BondFactory.hashBondConfig(config)` 取得哈希，转交给审批方上链 `approveIssuance`。
  - 构造 RFQ Order 时把 `quoteToken` 默认派生为 `bondToken.settlementToken()`，禁止用户自由填写。
  - 监听 `ExcessRedemptionRefunded` / `ForceRedemption` / `DomainSeparatorRefreshed` 三个新事件以呈现完整生命周期。
- **Go backend**：重新跑 `abigen` 拉新签名；旧的 `SettlementTokenPolicyUpdated` 解码代码必须减一字段。
- **Subgraph**：
  - `SettlementTokenPolicyUpdated`（BondIssuance）handler 减一参；
  - 新增 `ExcessRedemptionRefunded` / `ForceRedemption` / `DomainSeparatorRefreshed` handler；
  - `OrderFilled` handler 字段顺序按本文校正（v0.2.0 文档曾有误）。

## Breaking-Change Policy

- Additive events / additive non-indexed fields → MINOR
- Removed or renamed events / changed indexed topics / field-order changes / function signature changes → MAJOR
- Release notes 必须列出 wagmi、`abigen`、Subgraph 各自需要做的同步动作。
