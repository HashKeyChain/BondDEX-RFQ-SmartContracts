# Quickstart

[English](QUICKSTART.md)

BondDEX RFQ 是面向 HashKey Chain 的合规债券协议，覆盖发行审批、一级认购、二级 RFQ 成交与到期赎回。详见 `README.zh-CN.md`。

这份 quickstart 的目标是让你在最短路径内完成 4 件事：

- 确认仓库能正常编译
- 跑通 `US1 / US2 / US3` 三条核心业务主线
- 在本地 Anvil 上验证一站式部署脚本
- 导出 ABI 产物给前端、后端或索引器消费

## 前置依赖

- 已安装 Foundry：`forge`、`cast`、`anvil`
- 已安装 `jq`（Makefile 用它从 `config/*.json` 提取 RPC URL）
- 已安装 `make`

如果仓库里已经有 `contracts/lib/`，可以跳过依赖安装。若缺少依赖，请在 `contracts/` 目录执行：

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts OpenZeppelin/openzeppelin-contracts-upgradeable
```

## 配置文件说明

角色地址与策略配置集中在 `config/` 目录；部署者私钥通过环境变量 `DEPLOYER_PRIVATE_KEY` 传入，**不存储在配置文件中**。每个角色、每条结算代币策略均可独立配置。

```
config/
├── anvil.json      ← 本地 Anvil（使用 Anvil 预置账户，token 零地址自动部署 MockERC20）
├── testnet.json    ← 测试网（部署前必须填入全部真实值）
└── mainnet.json    ← 主网（部署前必须填入全部真实值）
```

### 完整配置格式

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",

  "platformAdmin": "0x新建ComplianceModule的初始管理员（通常为Safe多签）",

  "roles": {
    "bondFactory": {
      "admin":            "0x工厂DEFAULT_ADMIN_ROLE持有者",
      "issuanceApprover": "0x发行审批ISSUANCE_APPROVER_ROLE持有者",
      "complianceAdmin":  "0x合规管理COMPLIANCE_ADMIN_ROLE持有者",
      "pauser":           "0x暂停操作PAUSER_ROLE持有者"
    },
    "bondIssuance": {
      "admin":            "0x一级市场DEFAULT_ADMIN_ROLE持有者",
      "issuanceApprover": "0x认购审批ISSUANCE_APPROVER_ROLE持有者",
      "settlementAdmin":  "0x结算管理SETTLEMENT_ADMIN_ROLE持有者",
      "pauser":           "0x暂停操作PAUSER_ROLE持有者",
      "upgrader":         "0xUUPS升级UPGRADER_ROLE持有者"
    },
    "rfqSettlement": {
      "admin":            "0x二级市场DEFAULT_ADMIN_ROLE持有者",
      "settlementAdmin":  "0x结算管理SETTLEMENT_ADMIN_ROLE持有者",
      "pauser":           "0x暂停操作PAUSER_ROLE持有者",
      "upgrader":         "0xUUPS升级UPGRADER_ROLE持有者"
    }
  },

  "settlementTokens": [
    {
      "token": "0x结算代币地址（如USDC）",
      "bondIssuancePolicy": {
        "issuanceEnabled": true,
        "redemptionEnabled": true
      },
      "rfqSettlementEnabled": true
    }
  ],

  "feeConfig": {
    "feeRecipient": "0x手续费接收地址",
    "currentFeeBps": 30,
    "maxFeeBps": 1000
  },

  "revokeDeployer": true
}
```

### 配置项参考

| 字段 | 说明 |
| --- | --- |
| `DEPLOYER_PRIVATE_KEY`（环境变量） | 部署者私钥，通过环境变量传入；testnet/mainnet 完成后可自动撤销全部角色 |
| `platformAdmin` | 新建 ComplianceModule 代理的初始管理员，获得该模块的 DEFAULT_ADMIN / COMPLIANCE_ADMIN / PAUSER / UPGRADER |
| **roles.bondFactory** | |
| `.admin` | BondFactory 的 DEFAULT_ADMIN_ROLE — 可管理所有角色授予/撤销 |
| `.issuanceApprover` | ISSUANCE_APPROVER_ROLE — 审批/撤销发行申请 |
| `.complianceAdmin` | COMPLIANCE_ADMIN_ROLE — 注册/禁用合规实现模板 |
| `.pauser` | PAUSER_ROLE — 暂停/恢复 Factory 域 |
| **roles.bondIssuance** | |
| `.admin` | BondIssuance 的 DEFAULT_ADMIN_ROLE — 管理所有角色 |
| `.issuanceApprover` | ISSUANCE_APPROVER_ROLE — 审批/撤销认购申请 |
| `.settlementAdmin` | SETTLEMENT_ADMIN_ROLE — 配置结算代币策略 |
| `.pauser` | PAUSER_ROLE — 暂停/恢复认购、赎回等域 |
| `.upgrader` | UPGRADER_ROLE — 执行 UUPS 代理升级 |
| **roles.rfqSettlement** | |
| `.admin` | RFQSettlement 的 DEFAULT_ADMIN_ROLE — 管理所有角色 |
| `.settlementAdmin` | SETTLEMENT_ADMIN_ROLE — 配置结算代币策略 + 手续费 |
| `.pauser` | PAUSER_ROLE — 暂停/恢复结算域 |
| `.upgrader` | UPGRADER_ROLE — 执行 UUPS 代理升级 |
| **settlementTokens[]** | 结算代币数组，支持多币种 |
| `.token` | ERC20 代币地址（填 `0x0` 时自动部署 MockERC20，仅限本地测试） |
| `.bondIssuancePolicy` | BondIssuance 二维策略：认购(`issuanceEnabled`) / 赎回(`redemptionEnabled`)。RFQ 二级流通由独立的 `rfqSettlementEnabled` 控制 |
| `.rfqSettlementEnabled` | RFQSettlement 该代币是否允许二级结算 |
| **feeConfig** | |
| `.feeRecipient` | RFQ 二级市场手续费接收地址 |
| `.currentFeeBps` | 当前手续费率（基点，30 = 0.30%） |
| `.maxFeeBps` | 手续费率上限（基点，1000 = 10%） |
| `revokeDeployer` | 是否在配置完成后撤销 deployer 的全部角色（选择性撤销：已移交给他人的角色才撤销，deployer 仍持有的角色保留并输出警告） |

> **安全说明**：部署者私钥已从 config 文件中移除，仅通过 `DEPLOYER_PRIVATE_KEY` 环境变量传入，避免意外提交到 Git。
>
> **统一部署流程**：Anvil / Testnet / Mainnet 走完全相同的部署流水线，本地 Anvil 默认使用 Anvil 账户 #1 作为角色地址并启用 `revokeDeployer`，以真实测试权限移交流程。

## 1. 编译合约

```bash
make build
```

## 2. 跑最小验证路径

```bash
make test-us1   # 发行审批 + 一级认购
make test-us2   # RFQ 二级成交、批量成交、手续费、应计利息验证
make test-us3   # 赎回注资 + 持有人兑付
make test-e2e   # 完整生命周期 E2E
make test        # 全量回归
```

## 3. 在本地 Anvil 上验证一站式部署

```bash
# 终端 1：启动本地链
anvil

# 终端 2：一站式部署（Anvil 默认私钥）
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 make deploy-anvil
```

**一条命令自动完成**（Anvil / Testnet / Mainnet 执行相同流水线）：

1. 部署 MockERC20（token 为零地址时，仅本地测试触发）
2. 校验配置（所有角色、代币、手续费地址必须非零）
3. 部署 ComplianceModule 实现 → BondIssuance 代理 → RFQSettlement 代理 → BondFactory
4. 注册 ComplianceModule 实现模板
5. 配置全部结算代币策略
6. 配置 RFQ 手续费
7. 设置 platformAdmin
8. 逐角色授权（每个合约的每个角色独立授予配置的地址）
9. 选择性撤销 deployer 角色（`revokeDeployer=true` 时，已移交给他人的角色自动 renounce）

部署完成后，完整清单写入 `deployments/{chainId}.json`。

### 3.1 端到端演示

一键执行完整生命周期演示（自动启动 Anvil → 部署 → 演示 → 关闭 Anvil）：

```bash
make demo-anvil
```

该命令自动以 2025-12-31 时间戳启动 Anvil，部署合约后按真实时间线多阶段执行：认购窗口（2026-01-01）→ 起息后 12 分钟 → +2 天 → 每月推进至 +3 月 → 到期日（2027-01-09），Makefile 通过 `cast rpc` 自动推进 Anvil 时间。每笔 RFQ 交易包含基于链上时间自动计算的应计利息。演示结束后自动关闭 Anvil。

演示覆盖 9 个参与者（admin / issuer / makerA / makerB / makerC / investorA / investorB / investorC / delegate），包括：超额认购报错、未授权认购报错、**私下直接转账被拒绝（授权 operator 机制）**、RFQ 买卖含应计利息和手续费、做市商间免手续费但有应计利息、取消订单、过期订单、投资者间交易限制、代理领取、**全员赎回完毕后超额资金自动转回发行人**等场景。

如需纯模拟（不需要 Anvil 运行，含 `vm.warp`，单次完成全流程；需要先有 `deployments/31337.json`）：

```bash
make demo-anvil-sim
```

### 3.2 模块化操作

部署后的日常操作（审批、合规、认购、RFQ、赎回、查询等）通过 `Operations.s.sol` 提供模块化命令。通过 `ENV` 变量选择网络：

```bash
# Anvil（默认）
make ops-query-fee-config

# 测试网
ENV=testnet make ops-query-fee-config
ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-set-whitelist ARGS="0xCM地址 0x账户 true"

# 主网
ENV=mainnet DEPLOYER_PRIVATE_KEY=0x... make ops-set-whitelist ARGS="0xCM地址 0x账户 true"
```

查询类操作（`ops-query-*`）不需要私钥。详见 `docs/部署后操作手册.md`。

应计利息容差配置（`setAiToleranceSeconds` / `aiToleranceSeconds`）可通过 `Operations.s.sol` 直接调用，详见 `docs/部署后操作手册.md`。

## 4. 导出 ABI

```bash
make export-abi
```

产物：`abi-export/abi/*.abi.json` + `abi-export/metadata/metadata.json`

## 5. 推进到测试网

### 5.1 编辑 `config/testnet.json`

填入所有真实地址（每个角色可以指向不同的 Safe 多签）：

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",
  "platformAdmin": "0xSafe地址A",
  "roles": {
    "bondFactory": {
      "admin":            "0xSafe地址A",
      "issuanceApprover": "0xSafe地址A",
      "complianceAdmin":  "0xSafe地址A",
      "pauser":           "0xSafe地址B（运维团队）"
    },
    "bondIssuance": {
      "admin":            "0xSafe地址A",
      "issuanceApprover": "0xSafe地址A",
      "settlementAdmin":  "0xSafe地址A",
      "pauser":           "0xSafe地址B",
      "upgrader":         "0xSafe地址C（技术团队）"
    },
    "rfqSettlement": {
      "admin":            "0xSafe地址A",
      "settlementAdmin":  "0xSafe地址A",
      "pauser":           "0xSafe地址B",
      "upgrader":         "0xSafe地址C"
    }
  },
  "settlementTokens": [
    {
      "token": "0x测试网USDC",
      "bondIssuancePolicy": {
        "issuanceEnabled": true,
        "redemptionEnabled": true
      },
      "rfqSettlementEnabled": true
    }
  ],
  "feeConfig": {
    "feeRecipient": "0x国库Safe",
    "currentFeeBps": 30,
    "maxFeeBps": 1000
  },
  "revokeDeployer": true
}
```

### 5.2 一站式部署

```bash
DEPLOYER_PRIVATE_KEY=0x你的私钥 make deploy-testnet
```

成功后自动更新 `deployments/133.json`（含完整合约地址、配置参数、角色矩阵、移交状态）。

## 6. 主网部署

编辑 `config/mainnet.json` → `DEPLOYER_PRIVATE_KEY=0x... make deploy-mainnet` → 输出 `deployments/177.json`。

## 部署输出文件说明

`deployments/{chainId}.json` 包含：

| 字段 | 说明 |
| --- | --- |
| `deployer` / `platformAdmin` | 关键账户地址 |
| `contracts` | 所有合约地址（代理 + 实现） |
| `configuration.settlementTokens[]` | 每条代币的完整策略 |
| `configuration.feeConfig` | 手续费率和接收地址 |
| `configuration.aiToleranceSeconds` | 应计利息验证容差（秒），从链上读取 |
| `roles.bondFactory` | BondFactory 每个角色的持有者 |
| `roles.bondIssuance` | BondIssuance 每个角色的持有者 |
| `roles.rfqSettlement` | RFQSettlement 每个角色的持有者 |
| `handoff` | deployer 角色撤销状态 |

## 命令速查

| 命令 | 说明 |
| --- | --- |
| `make build` | 编译合约 |
| `make test` | 全量测试 |
| `make test-us1` / `test-us2` / `test-us3` | 单条主线测试 |
| `make test-e2e` | E2E 生命周期测试 |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-anvil` | 本地 Anvil 一站式部署 |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-testnet` | 测试网一站式部署 + 权限移交 |
| `DEPLOYER_PRIVATE_KEY=0x... make deploy-mainnet` | 主网一站式部署 + 权限移交 |
| `make ops-release-excess-redemption ARGS="<bondToken>"` | 主动释放超额赎回资金（到期后），释放后**直接转回发行人**（v0.3.0 起） |
| `make demo-anvil` | Anvil 端到端演示（多阶段：按真实时间线推进认购→RFQ→赎回） |
| `make demo-anvil-sim` | 纯模拟演示（不 broadcast，含 vm.warp，单次完成） |
| `make export-abi` | 导出 ABI |
| `ENV=testnet make ops-query-*` | 测试网查询（不需要私钥） |
| `ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-*` | 测试网写入操作 |

## BondConfig 字段速查

`createBond` 使用的 `BondConfig` 结构体完整示例：

```solidity
BondConfig({
    issuer:                   0x发行人地址,
    name:                     "HashKey Bond 2026-Q1",
    symbol:                   "HKB-Q1",
    decimals:                 0,
    faceValue:                1_000e6,           // 1,000 USDC
    couponRateBps:            500,               // 年化 5%（基点）
    maturityTimestamp:        1767225600,         // 2026-01-01 到期
    issueDate:                1704067200,         // 2024-01-01 发行
    dayCountConvention:       DayCount.ACT_365,
    couponFrequency:          CouponFrequency.BULLET,
    bondCategory:             BondCategory.CORPORATE,
    isin:                     bytes12(0),         // 或填入 12 字节 ISIN
    settlementToken:          0xUSDC地址,
    settlementTokenDecimals:  6,
    complianceImplementation: 0x已注册合规模板地址,
    policyId:                 keccak256("policy-v1"),
    policyVersion:            1
})
```

**DayCountConvention 枚举值：**

| 枚举 | 值 | 说明 |
| --- | --- | --- |
| `ACT_365` | 0 | 实际天数 / 365 |
| `ACT_360` | 1 | 实际天数 / 360 |

**CouponFrequency 枚举值：**

| 枚举 | 值 | 说明 |
| --- | --- | --- |
| `BULLET` | 0 | 到期一次性付息（最常见） |
| `ANNUAL` | 1 | 每年付息 |

> 平台暂不支持 SEMI_ANNUAL / QUARTERLY 频率。

**BondCategory 枚举值：**

| 枚举 | 值 | 说明 |
| --- | --- | --- |
| `CORPORATE` | 0 | 公司债 |
| `GOVERNMENT` | 1 | 政府债 |
| `CONVERTIBLE` | 2 | 可转债 |
| `ABS` | 3 | 资产支持证券 |

## v0.3.0 新增 / 变更 API 速查

外部审计修复批次（N1–N18）落地为以下接口变化。**集成方升级到 v0.3.0 时必须重新跑** wagmi typegen / abigen / Subgraph mappings。

### BondFactory（新增）

```solidity
/// 计算 BondConfig 的规范哈希。审批方调 approveIssuance 前先调它取 hash，
/// 发行人调 createBond 时合约会比对，参数任何字段不一致都会 revert BondConfigHashMismatch。
function hashBondConfig(BondConfig calldata config) external pure returns (bytes32);
```

> **构造函数行为变更（最小权限初始化）**：四个核心合约（`BondFactory` / `BondIssuance` / `RFQSettlement` / `ComplianceModule`）的构造函数或 `initialize` **都只 grant `DEFAULT_ADMIN_ROLE`** 给传入的 admin；其他治理角色由部署脚本 / 管理员通过标准 OZ AccessControl `grantRole` 显式授予（`ComplianceModule` 还会额外发放 `BOND_FACTORY_ROLE` 给 factory，因为 `createBond` 需要在同一笔交易内同步调用 `bindBondToken`）。`setPlatformAdmin` 已纯化为只更新 `platformAdmin` storage（决定后续新部署的 ComplianceModule 的初始 admin），**不再触碰任何 AccessControl 角色**。每支新债券创建之后，platformAdmin 必须按 `docs/部署后操作手册.md §6.3.5` 的 SOP 显式发放 ComplianceModule 的 `COMPLIANCE_ADMIN_ROLE` / `PAUSER_ROLE` / `UPGRADER_ROLE`，否则后续合规运维调用会 revert。

### BondToken（新增）

```solidity
/// 高精度的应计利息总额（settlement token 最小单位）。延迟除法 mulDiv，避免精度截断。
function accruedInterestFor(uint256 bondAmount, uint256 timestamp) external view returns (uint256);

/// bondAmount 对应的本金（settlement token 最小单位）。
function principalOf(uint256 bondAmount) external view returns (uint256);

/// 构造期校验过的 settlement token decimals。
function settlementTokenDecimals() external view returns (uint8);
```

> **删除**：legacy `accruedInterestPerUnit(timestamp)` 已删除——所有"per-unit"展示场景请改为 `accruedInterestFor(10 ** decimals(), timestamp)`，数学等价且精度更好。
>
> **构造参数变更**：`BondToken.ConstructorParams` 新增 `uint8 settlementTokenDecimals` 字段；构造期会与 `IERC20Metadata(settlementToken).decimals()` 严格比对，不一致时 revert。

### BondIssuance（新增 + 变更）

```solidity
/// 强制赎回受制裁/被永久移出白名单的持有人，资金转入指定 recipient（监管托管/发行人）。
function forceRedeem(address bondToken, address holder, address recipient) external;  // DEFAULT_ADMIN_ROLE

/// 签名变更：v0.2.0 是 (address, bool, bool, bool)，v0.3.0 删除中间的 settlementEnabled。
function setSettlementTokenPolicy(address token, bool enabledForIssuance, bool enabledForRedemption) external;
function getSettlementTokenPolicy(address token) external view returns (bool, bool);
```

> **超额赎回行为变更（N6）**：`releaseExcessRedemption` 与全员赎回触发的自动释放分支现在**原子地把超额转回发行人**，不再"先释放、后由 admin rescue"。监听新事件 `ExcessRedemptionRefunded(bondToken, settlementToken, issuer, excessAmount)` 做财务对账。`rescueTokens` 现仅用于救援误转入的代币。
>
> **redemption 通道关停受限（N11）**：在 `_totalRedemptionLiability[token] > 0` 时禁止把该 token 的 `enabledForRedemption` 关闭，防止管理员策略变更把 issuer 已存入的赎回资金锁死。

### RFQSettlement（新增 + 行为）

```solidity
/// UUPS 升级后由 admin 调用以刷新 EIP-712 缓存。如果升级了 SettlementOrderEIP712.NAME / VERSION 必须立即调用。
function refreshDomainSeparator() external;  // DEFAULT_ADMIN_ROLE
```

> **链上强制（N1）**：`order.quoteToken` 必须等于 `bondToken.settlementToken()`，前端构造订单时应自动派生该字段、禁止用户填写。
>
> **应计利息验证（N7 + N8）**：链上验算改用 `BondToken.accruedInterestFor`（高精度）。当 `expectedAI == 0`（如交易在 issueDate 之前发生），strict require `order.accruedInterest == 0`，**不允许任何容差**。

### 新增事件

| 事件 | 来源 | 触发场景 |
| :-- | :-- | :-- |
| `ExcessRedemptionRefunded(bondToken, settlementToken, issuer, excessAmount)` | BondIssuance | 超额赎回款实际转回发行人后发出（与 `ExcessRedemptionReleased` 同一交易内） |
| `ForceRedemption(bondToken, holder, recipient, bondAmount, payout, operator)` | BondIssuance | admin 调用 `forceRedeem` 时发出 |
| `DomainSeparatorRefreshed(chainId, domainSeparator, operator)` | RFQSettlement | admin 调用 `refreshDomainSeparator` 时发出 |

完整 ABI 与版本说明见 `abi-export/metadata/event-interface.md`。
