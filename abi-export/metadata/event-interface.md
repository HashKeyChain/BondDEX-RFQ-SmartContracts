# BondDEX Event Interface Notes

## Version

- ABI/Event package version: `0.2.0`
- Change type: MAJOR — EIP-712 domain version upgraded to `"2"`, new events added, Order struct extended

> **破坏性变更（MAJOR）：**
> - EIP-712 domain `version` 字段从 `"1"` 升级至 `"2"`，所有历史签名立即失效
> - `Order` 结构体新增 `accruedInterest` 字段，`OrderFilled` 事件对应更新
> - `BondCreated` 事件新增 `issueDate` 字段
> - 新增 `BondMetadata` 事件（BondFactory 发出）
> - 新增 `AiToleranceUpdated` 事件（RFQSettlement 发出）
>
> 下游需重新生成 wagmi typings、`abigen` bindings 及 Subgraph mappings。

## Contract Event Coverage

### BondFactory

- `IssuanceApproved`
- `IssuanceRevoked`
- `ComplianceImplementationRegistered`
- `PlatformAdminUpdated`
- `BondCreated` — 核心债券标识事件，新增 `issueDate` 字段
- `BondMetadata` — **新增**，与 `BondCreated` 同块发出，包含扩展属性：`dayCountConvention`、`couponFrequency`、`bondCategory`、`isin`
- `PauseDomainUpdated`

#### BondCreated（更新）

```solidity
event BondCreated(
    address indexed bondToken,
    address indexed issuer,
    bytes32 indexed approvalId,
    uint256 issueDate,           // 新增：发行日（Unix 时间戳）
    address complianceModule,
    address settlementToken,
    uint256 faceValue,
    uint256 couponRateBps,       // 年化利率（bps）
    uint256 maturityTimestamp
);
```

#### BondMetadata（新增）

```solidity
event BondMetadata(
    address indexed bondToken,
    uint8 dayCountConvention,    // 0=ACT_365, 1=ACT_360, 2=THIRTY_360
    uint8 couponFrequency,       // 0=BULLET, 1=ANNUAL, 2=SEMI_ANNUAL, 3=QUARTERLY
    uint8 bondCategory,          // 0=CORPORATE, 1=GOVERNMENT, 2=CONVERTIBLE, 3=ABS
    bytes12 isin                 // 国际证券识别码（留空为 bytes12(0)）
);
```

### ComplianceModule

- `WhitelistUpdated`
- `RoleUpdated`
- `BondTokenBound`
- `PolicyMetadataUpdated`
- `PauseDomainUpdated`

### BondIssuance

- `SettlementTokenPolicyUpdated`
- `SubscriptionApproved`
- `SubscriptionApprovalRevoked`
- `SubscriptionCreated`
- `Subscribed`
- `SubscriptionClosed`
- `RedemptionDeposited`
- `RedemptionClaimed`
- `TokensRescued`
- `ExcessRedemptionReleased` — **新增**，当全部赎回后自动释放或管理员调用 `releaseExcessRedemption` 时发出
- `ClaimDelegateSet`
- `PauseDomainUpdated`

### RFQSettlement

- `FeeConfigUpdated`
- `SettlementTokenPolicyUpdated`
- `BondTokenRegistrationUpdated`
- `OrderFilled` — 更新：`quoteAmount` 现为不含应计利息的净额；新增 `accruedInterest` 字段；`fee` 基于 dirty amount 计算
- `OrderCancelled`
- `NonceIncremented`
- `AiToleranceUpdated` — **新增**，当 `setAiToleranceSeconds` 被调用时发出
- `PauseDomainUpdated`

#### OrderFilled（更新）

```solidity
event OrderFilled(
    bytes32 indexed orderHash,
    address indexed maker,
    address indexed taker,
    address bondToken,
    address quoteToken,
    uint256 bondAmount,
    uint256 quoteAmount,        // 净额（不含应计利息）
    uint256 accruedInterest,    // 新增：应计利息（报价代币最小单位）
    uint8 side,
    uint256 fee                 // 基于 dirtyAmount = quoteAmount + accruedInterest 计算
);
```

#### AiToleranceUpdated（新增）

```solidity
event AiToleranceUpdated(
    uint256 oldToleranceSeconds,
    uint256 newToleranceSeconds
);
```

### BondToken

- Standard ERC-20 `Transfer`

## Consumer Notes

- Frontend consumers use these events for live lifecycle refresh and transaction
  confirmation UX. **Must update EIP-712 domain version to `"2"` in all signing flows.**
- Go backend consumers use them for order, subscription, and redemption
  projection tables. **Re-run `abigen` after ABI regeneration to pick up new event fields.**
- Subgraph consumers use them as the canonical history surface for lifecycle
  reconstruction. **Add `BondMetadata` handler and update `OrderFilled` mapping for `accruedInterest`.**

## Breaking-Change Policy

- Additive events or additive non-indexed fields are MINOR changes.
- Removed or renamed events, changed indexed topics, or field-order changes are
  MAJOR changes.
- Release notes must call out any downstream regeneration steps for wagmi,
  `abigen`, or Subgraph mappings.
