# Quickstart

BondDEX RFQ 是面向 HashKey Chain 的合规债券协议，覆盖发行审批、一级认购、二级 RFQ 成交与到期赎回。详见 `README.md`。

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
        "settlementEnabled": false,
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
| `.bondIssuancePolicy` | BondIssuance 三维策略：认购(issuance) / 结算(settlement) / 赎回(redemption) |
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
make test-us2   # RFQ 二级成交、批量成交、手续费
make test-us3   # 赎回注资 + 持有人兑付
make test-e2e   # 完整生命周期 E2E
make test        # 全量回归（98 用例）
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

部署完成后，可运行完整生命周期演示（铸造 → 创建债券 → 合规配置 → 一级认购 → 二级 RFQ 交易 → 到期赎回）：

```bash
make demo-anvil
```

该命令自动分两阶段执行：到期前全部业务 → 推进 Anvil 时间到到期日 → 赎回与领取。每个 broadcast 交易独占一个区块。

演示覆盖 9 个参与者（admin / issuer / makerA / makerB / makerC / investorA / investorB / investorC / delegate），包括：超额认购报错、未授权认购报错、RFQ 买卖含手续费、做市商间免手续费、取消订单、过期订单、投资者间交易限制、代理领取、多余资金救援等场景。

如需纯模拟（不发送交易，含 `vm.warp`）：

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
        "settlementEnabled": false,
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
| `make demo-anvil` | Anvil 端到端演示（两阶段：到期前 + 时间推进 + 到期后） |
| `make demo-anvil-sim` | 纯模拟演示（不 broadcast，含 vm.warp） |
| `make export-abi` | 导出 ABI |
| `ENV=testnet make ops-query-*` | 测试网查询（不需要私钥） |
| `ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-*` | 测试网写入操作 |
