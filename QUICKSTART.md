# Quickstart

这份 quickstart 的目标是让你在最短路径内完成 4 件事：

- 确认仓库能正常编译
- 跑通 `US1 / US2 / US3` 三条核心业务主线
- 在本地 Anvil 上验证部署脚本入口
- 导出 ABI 产物给前端、后端或索引器消费

## 前置依赖

- 已安装 Foundry：`forge`、`cast`、`anvil`
- 已安装 `jq`，用于 ABI 导出脚本读取 `contracts/out/` 中的构建产物
- 如果你要跑 fork 测试或部署到测试网 / 主网，需要准备对应 RPC URL 和私钥

如果仓库里已经有 `contracts/lib/`，可以跳过依赖安装。若缺少依赖，请在 `contracts/` 目录执行：

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts OpenZeppelin/openzeppelin-contracts-upgradeable
```

## 1. 编译合约

```bash
cd contracts
forge build
```

成功后，构建产物会出现在 `contracts/out/`。

## 2. 跑最小验证路径

先验证 3 条主流程对应的集成测试：

```bash
cd contracts
forge test --match-contract US1LaunchAndSubscribeIntegrationTest
forge test --match-contract US2RfqSettlementIntegrationTest
forge test --match-contract US3RedemptionAndClaimsIntegrationTest
```

如果你想一次确认完整生命周期，再补跑：

```bash
cd contracts
forge test --match-contract BondLifecycleE2ETest
```

如果你希望先做一次全量回归，也可以直接运行：

```bash
cd contracts
forge test
```

## 3. 在本地 Anvil 上验证部署脚本

先在一个终端启动本地链：

```bash
anvil
```

再在另一个终端执行本地部署：

```bash
cd contracts
export ANVIL_RPC_URL=http://127.0.0.1:8545
forge script script/DeployAnvil.s.sol:DeployAnvil --rpc-url "$ANVIL_RPC_URL" --broadcast
```

说明：

- `DeployAnvil.s.sol` 会部署本地 `Mock USDC`、`BondIssuance`、`RFQSettlement`、`BondFactory` 和 `ComplianceModule` 实现
- 这个脚本默认使用 Anvil 的测试私钥；如果你想覆盖它，可以设置 `ANVIL_PRIVATE_KEY`
- 本地部署会打印地址，但不会像测试网 / 主网那样写入 `deployments/31337.json`

## 4. 导出 ABI

```bash
cd contracts
forge build
forge script script/ExportAbi.s.sol:ExportAbi
```

执行后可以重点检查：

- `abi-export/abi/*.abi.json`
- `abi-export/metadata/metadata.json`
- `abi-export/metadata/event-interface.md`

补充说明：

- `abi-export/metadata/README.md` 明确约定 `contracts/out/` 才是构建真源
- `metadata.json` 默认会写入 `UNSET_COMMIT`，正式发布前需要补齐 commit 与实际地址信息

## 5. 需要时再跑 fork 测试

如果你要验证 HashKey testnet 相关域分隔和 Safe handoff 路径，可以设置测试网 RPC：

```bash
cd contracts
export HSK_TESTNET_RPC_URL=https://your-hsk-testnet-rpc
export HSK_TESTNET_FORK_BLOCK=123456
forge test --match-contract RFQSettlementDomainForkTest
forge test --match-contract DeploymentAndSafeHandoffForkTest
```

如果没有设置 `HSK_TESTNET_RPC_URL`，这两类 fork 测试会直接返回，不会真正建 fork。

## 6. 推进到测试网部署

测试网部署需要 4 个核心环境变量：

| 变量 | 说明 |
| --- | --- |
| `HSK_TESTNET_RPC_URL` | HashKey testnet RPC |
| `TESTNET_DEPLOYER_PRIVATE_KEY` | 部署者私钥 |
| `TESTNET_SAFE_ADMIN` | 接收治理权限的 Safe 地址 |
| `TESTNET_SETTLEMENT_TOKEN` | 测试网结算币地址 |

部署命令：

```bash
cd contracts
export HSK_TESTNET_RPC_URL=https://your-hsk-testnet-rpc
export TESTNET_DEPLOYER_PRIVATE_KEY=0x...
export TESTNET_SAFE_ADMIN=0x...
export TESTNET_SETTLEMENT_TOKEN=0x...
forge script script/DeployTestnet.s.sol:DeployTestnet --rpc-url "$HSK_TESTNET_RPC_URL" --broadcast
```

成功后会更新：

- `deployments/133.json`

## 7. 配置角色并准备 Safe 交接

在测试网或主网上部署完成后，继续设置运行期地址：

```bash
cd contracts
export BOND_FACTORY=0x...
export BOND_ISSUANCE=0x...
export RFQ_SETTLEMENT=0x...
```

然后配置角色与允许的结算币：

```bash
cd contracts
forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url "$HSK_TESTNET_RPC_URL" --broadcast
```

最后准备向 Safe 交接权限：

```bash
cd contracts
export REVOKE_CALLER_ROLES=true
forge script script/HandoffToSafe.s.sol:HandoffToSafe --rpc-url "$HSK_TESTNET_RPC_URL" --broadcast
```

如果你只想先授予 Safe 权限、暂时不撤销部署者权限，可以不设置 `REVOKE_CALLER_ROLES`，或显式设为 `false`。

## 8. 主网部署变量

主网变量名与测试网一致，只是前缀改为 `MAINNET_*`：

| 变量 | 说明 |
| --- | --- |
| `HSK_MAINNET_RPC_URL` | HashKey mainnet RPC |
| `MAINNET_DEPLOYER_PRIVATE_KEY` | 主网部署私钥 |
| `MAINNET_SAFE_ADMIN` | 主网 Safe 地址 |
| `MAINNET_SETTLEMENT_TOKEN` | 主网结算币地址 |

主网部署命令：

```bash
cd contracts
export HSK_MAINNET_RPC_URL=https://your-hsk-mainnet-rpc
export MAINNET_DEPLOYER_PRIVATE_KEY=0x...
export MAINNET_SAFE_ADMIN=0x...
export MAINNET_SETTLEMENT_TOKEN=0x...
forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url "$HSK_MAINNET_RPC_URL" --broadcast
```

成功后会更新：

- `deployments/177.json`

## 常见问题

- `forge build` 提示缺少依赖：先确认 `contracts/lib/` 是否完整，再执行上面的 `forge install`
- `ExportAbi` 失败：通常是本机没有安装 `jq`，或者 `contracts/out/` 尚未生成构建产物
- fork 测试没有真正执行：检查 `HSK_TESTNET_RPC_URL` 是否已设置
- 测试网脚本报环境变量缺失：检查链对应的 `*_RPC_URL`、`*_DEPLOYER_PRIVATE_KEY`、`*_SAFE_ADMIN` 和 `*_SETTLEMENT_TOKEN`

## 推荐下一步

如果你只是想快速确认协议主路径，做到这里就足够了。接下来最自然的顺序是：

1. 运行 `forge test` 做一次全量回归
2. 用 Anvil 部署验证本地脚本入口
3. 导出 ABI 到 `abi-export/`
4. 再推进到测试网部署、角色配置与 Safe handoff
