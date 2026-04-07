# Quickstart

这份 quickstart 的目标是让你在最短路径内完成 4 件事：

- 确认仓库能正常编译
- 跑通 `US1 / US2 / US3` 三条核心业务主线
- 在本地 Anvil 上验证部署脚本入口
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

所有配置集中在 `config/` 目录，**不需要设置任何环境变量**。

```
config/
├── anvil.json      ← 本地 Anvil（已含默认私钥，无需修改）
├── testnet.json    ← 测试网（部署前需填入真实值）
└── mainnet.json    ← 主网（部署前需填入真实值）
```

配置文件格式（以 `testnet.json` 为例）：

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",
  "deployerPrivateKey": "0x你的部署者私钥",
  "safeAdmin": "0x你的Safe多签地址",
  "settlementToken": "0x测试网USDC地址"
}
```

| 字段 | 说明 |
| --- | --- |
| `rpcUrl` | 该环境的 RPC 节点地址 |
| `deployerPrivateKey` | 部署者私钥 |
| `safeAdmin` | 接收治理权限的 Safe 多签地址 |
| `settlementToken` | 结算代币地址（如 USDC），Anvil 环境会自动铸造 Mock |

> **安全提醒**：请勿将含有真实私钥的 `config/*.json` 提交到 Git 仓库。

## 1. 编译合约

```bash
make build
```

成功后，构建产物会出现在 `contracts/out/`。

## 2. 跑最小验证路径

分别验证 3 条主流程：

```bash
make test-us1
make test-us2
make test-us3
```

完整生命周期 E2E 测试：

```bash
make test-e2e
```

全量回归：

```bash
make test
```

## 3. 在本地 Anvil 上验证部署脚本

先在一个终端启动本地链：

```bash
anvil
```

再在另一个终端执行本地部署：

```bash
make deploy-anvil
```

说明：

- 自动从 `config/anvil.json` 读取全部配置（含 Anvil 默认私钥）
- 自动部署 `Mock USDC`、`BondIssuance`、`RFQSettlement`、`BondFactory` 和 `ComplianceModule`
- 零环境变量，直接运行

## 4. 导出 ABI

```bash
make export-abi
```

产物位于 `abi-export/` 目录：

- `abi-export/abi/*.abi.json`
- `abi-export/metadata/metadata.json`

## 5. 需要时再跑 fork 测试

```bash
cd contracts
export HSK_TESTNET_RPC_URL=https://testnet.hsk.xyz
export HSK_TESTNET_FORK_BLOCK=123456
forge test --match-contract RFQSettlementDomainForkTest
forge test --match-contract DeploymentAndSafeHandoffForkTest
```

如果没有设置 `HSK_TESTNET_RPC_URL`，这两类 fork 测试会直接返回，不会真正建 fork。

## 6. 推进到测试网部署

### 6.1 编辑配置文件

在 `config/testnet.json` 中填入所有真实值：

```json
{
  "rpcUrl": "https://testnet.hsk.xyz",
  "deployerPrivateKey": "0x你的私钥",
  "safeAdmin": "0x你的Safe地址",
  "settlementToken": "0x测试网USDC地址"
}
```

### 6.2 部署

```bash
make deploy-testnet
```

成功后会自动更新 `deployments/133.json`。

### 6.3 配置角色

```bash
make configure-testnet
```

### 6.4 完整移交（可选）

如果要一步完成角色配置 + deployer 权限放弃：

```bash
make handoff-testnet
```

## 7. 主网部署

### 7.1 编辑配置文件

在 `config/mainnet.json` 中填入所有真实值：

```json
{
  "rpcUrl": "https://mainnet.hsk.xyz",
  "deployerPrivateKey": "0x你的私钥",
  "safeAdmin": "0x你的主网Safe地址",
  "settlementToken": "0x主网USDC地址"
}
```

### 7.2 部署 → 配置 → 移交

```bash
make deploy-mainnet
make configure-mainnet
make handoff-mainnet
```

成功后会自动更新 `deployments/177.json`。

## 命令速查表

| 命令 | 说明 |
| --- | --- |
| `make build` | 编译合约 |
| `make test` | 全量测试 |
| `make test-us1` / `test-us2` / `test-us3` | 单条主线测试 |
| `make test-e2e` | E2E 生命周期测试 |
| `make deploy-anvil` | 本地 Anvil 部署 |
| `make deploy-testnet` | 测试网部署 |
| `make deploy-mainnet` | 主网部署 |
| `make configure-testnet` / `configure-mainnet` | 授予 Safe 角色 + 配置结算代币 |
| `make handoff-testnet` / `handoff-mainnet` | 配置 + deployer 放弃全部权限 |
| `make export-abi` | 导出 ABI |

## 常见问题

- `forge build` 提示缺少依赖：先确认 `contracts/lib/` 是否完整，再执行上面的 `forge install`
- `ExportAbi` 失败：通常是本机没有安装 `jq`，或者 `contracts/out/` 尚未生成构建产物
- fork 测试没有真正执行：检查 `HSK_TESTNET_RPC_URL` 是否已设置
- 脚本报配置文件读取失败：检查 `config/*.json` 是否已填入真实地址和私钥
- PostDeploy 报文件找不到：确认已先执行 Deploy 并成功写入了 `deployments/{chainId}.json`
- Makefile 报 `jq: command not found`：请先安装 `jq`（macOS: `brew install jq`）

## 推荐下一步

1. `make build` + `make test` 做一次全量回归
2. `make deploy-anvil` 验证本地脚本
3. `make export-abi` 导出 ABI
4. 编辑 `config/testnet.json`，`make deploy-testnet` 推进到测试网
5. `make configure-testnet` 或 `make handoff-testnet` 完成 Safe 交接
