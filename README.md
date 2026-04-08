# BondDEX RFQ Smart Contracts

`BondDEX RFQ Smart Contracts` 是一个面向 HashKey Chain 的 `contracts-first` 债券协议仓库。它覆盖了合规债券的创建与发行审批、一级市场认购、二级市场 RFQ 询价成交，以及到期后的赎回资金注入与持有人兑付领取。

这个仓库的目标不只是放 Solidity 合约本身，还包括完整的交付链路：

- 在 `contracts/` 中完成合约、脚本与测试开发
- 在 `deployments/` 中沉淀链级部署清单
- 在 `abi-export/` 中导出 ABI、地址与事件接口说明，供前端、Go 后端和索引器消费

## 业务范围

当前仓库的核心能力可以按 3 条主流程理解：

- `US1 - Launch and Subscribe`：平台审批发行，发行人创建债券，配置合规模块，做市商或合格参与方完成一级认购
- `US2 - RFQ Settlement`：做市商或投资者签名 EIP-712 订单，对手方按单成交（禁止投资者对投资者），支持批量成交、订单取消、nonce 管理和手续费收取
- `US3 - Redemption and Claims`：债券到期后由发行人注入赎回资金，持有人直接领取或通过代理人代领

这 3 条主流程分别在 `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`、`contracts/test/integration/US2_RfqSettlement.t.sol` 和 `contracts/test/integration/US3_RedemptionAndClaims.t.sol` 中有对应的集成测试覆盖，并由 `contracts/test/integration/BondLifecycleE2E.t.sol` 串成完整生命周期。

## 核心模块

| 模块 | 作用 |
| --- | --- |
| `BondFactory` | 负责发行审批、合规实现注册，以及创建 `BondToken` 和每只债对应的 `ComplianceModule` 实例 |
| `BondToken` | 债券 ERC-20 资产本体，记录发行人、面值、票息、到期时间和结算币；转账限制委托给合规模块判断 |
| `ComplianceModule` | 负责白名单、角色矩阵、策略元数据与暂停域控制，限制债券转账方向和参与方身份 |
| `BondIssuance` | 负责一级市场认购、认购窗口管理、赎回资金注入、直接领取与代理领取 |
| `RFQSettlement` | 负责二级市场 RFQ 订单的签名校验、撮合成交、批量成交、取消、nonce floor 与手续费策略 |

## 协议特性

- 目标链为 HashKey Chain，内置测试网 `133` 与主网 `177` 的部署配置
- 关键控制平面采用 `AccessControl` + 角色治理，支持部署后向 Safe 交接权限
- `BondIssuance`、`RFQSettlement` 与每债券实例级的 `ComplianceModule` 使用代理部署模式
- `BondToken` 将合规限制外部化到 `ComplianceModule`，便于按债券实例独立配置白名单与角色
- 二级结算使用 EIP-712 typed data，对订单哈希、签名与 nonce 作严格校验
- ABI 与事件接口采用 additive-first 的发布约定，方便前端、`abigen` 与 Subgraph 同步升级

## 仓库结构

```text
.
├── README.md
├── QUICKSTART.md
├── abi-export/
│   ├── abi/                 # 导出的 ABI JSON
│   ├── addresses/           # 链级地址清单
│   └── metadata/            # 版本、事件接口、发布元数据
├── contracts/
│   ├── src/                 # 核心合约
│   ├── script/              # 部署、角色配置、Safe 交接、ABI 导出脚本
│   ├── test/                # unit / fuzz / invariant / integration / fork
│   ├── foundry.toml
│   └── remappings.txt
└── deployments/             # 各链部署记录与交接状态
```

## 开发与交付流程

推荐按下面的顺序理解和使用仓库：

1. 在 `contracts/` 中编译、运行单元测试和集成测试
2. 使用 `DeployAnvil.s.sol` 在本地链验证部署路径
3. 使用 `DeployTestnet.s.sol` 或 `DeployMainnet.s.sol` 写入 `deployments/<chainId>.json`
4. 使用 `ConfigureRoles.s.sol` 给 Safe 配置角色并设置允许的结算币
5. 使用 `HandoffToSafe.s.sol` 准备角色交接，必要时撤销部署者权限
6. 使用 `ExportAbi.s.sol` 将 ABI 与发布元数据导出到 `abi-export/`

## 测试分层

仓库已经按 Foundry 常见分层组织测试：

- `unit/`：聚焦单个模块行为，例如发行审批、订单填充、合规模块管理
- `fuzz/`：聚焦数学与边界输入，例如认购与结算计价逻辑
- `invariant/`：聚焦协议不变量，例如一级市场记账与 RFQ 结算状态一致性
- `integration/`：按用户故事验证 `US1`、`US2`、`US3` 与完整生命周期
- `fork/`：在 HashKey testnet fork 上验证域分隔、部署与 Safe handoff 等链相关行为

## ABI 与事件接口

`abi-export/metadata/README.md` 和 `abi-export/metadata/event-interface.md` 约定了 ABI 发布与事件变更策略：

- `contracts/out/` 是构建产物的规范真源
- `abi-export/abi/*.abi.json` 是下游消费的导出 ABI
- `abi-export/metadata/event-interface.md` 描述了 `BondFactory`、`ComplianceModule`、`BondIssuance`、`RFQSettlement`、`BondToken` 的事件面
- 新增事件或新增非 indexed 字段应视为 `MINOR` 变更
- 删除事件、修改 indexed topic 或调整字段顺序应视为 `MAJOR` 变更

## 文档依据

本 README 主要根据以下真值源整理而成：

- `abi-export/metadata/README.md`
- `abi-export/metadata/event-interface.md`
- `contracts/script/*.s.sol`
- `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`
- `contracts/test/integration/US2_RfqSettlement.t.sol`
- `contracts/test/integration/US3_RedemptionAndClaims.t.sol`
- `contracts/test/integration/BondLifecycleE2E.t.sol`

## 快速开始

本地启动、核心命令、最小验证路径与测试网/主网的环境变量说明见根目录 `QUICKSTART.md`。
