# BondDEX RFQ Smart Contracts

`BondDEX RFQ Smart Contracts` 是一个面向 HashKey Chain 的 `contracts-first` 债券协议仓库。它覆盖了合规债券的创建与发行审批、一级市场认购、二级市场 RFQ 询价成交，以及到期后的赎回资金注入与持有人兑付领取。

这个仓库的目标不只是放 Solidity 合约本身，还包括完整的交付链路：

- 在 `contracts/` 中完成合约、脚本与测试开发
- 在 `deployments/` 中沉淀链级部署清单
- 在 `abi-export/` 中导出 ABI、地址与事件接口说明，供前端、Go 后端和索引器消费

## 业务范围

当前仓库的核心能力可以按 3 条主流程理解：

- `US1 - Launch and Subscribe`：平台审批发行，发行人创建债券，配置合规模块，做市商或合格参与方完成一级认购
- `US2 - RFQ Settlement`：做市商或投资者签名 EIP-712 订单，对手方按单成交，支持批量成交、订单取消、nonce 管理和手续费收取。交易方向限制为做市商↔投资者和做市商↔做市商，禁止投资者↔投资者。手续费始终由做市商侧承担，做市商之间交易免手续费
- `US3 - Redemption and Claims`：债券到期后由发行人注入赎回资金，持有人直接领取或通过代理人代领

这 3 条主流程分别在 `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`、`contracts/test/integration/US2_RfqSettlement.t.sol` 和 `contracts/test/integration/US3_RedemptionAndClaims.t.sol` 中有对应的集成测试覆盖，并由 `contracts/test/integration/BondLifecycleE2E.t.sol` 串成完整生命周期。

## 核心模块

| 模块 | 作用 |
| --- | --- |
| `BondFactory` | 负责发行审批、合规实现注册，以及创建 `BondToken` 和每只债对应的 `ComplianceModule` 实例 |
| `BondToken` | 债券 ERC-20 资产本体，记录发行人、面值、票息、到期时间和结算币；转账限制委托给合规模块判断 |
| `ComplianceModule` | 负责白名单、角色矩阵、策略元数据与暂停域控制，限制债券转账方向（禁止投资者↔投资者）和参与方身份 |
| `BondIssuance` | 负责一级市场认购、认购窗口管理、赎回资金注入、直接领取与代理领取 |
| `RFQSettlement` | 负责二级市场 RFQ 订单的签名校验、撮合成交、批量成交、取消、nonce floor、手续费策略与 `quoteFee` 查询 |

## 手续费模型

RFQ 二级市场交易的手续费始终由做市商侧承担，投资者侧不受手续费影响：

| 场景 | 资金流（以 30 bps 为例） |
| --- | --- |
| 做市商卖出债券 / 投资者买入 | 投资者付 10,000 USDC → 做市商收 9,970 → 平台收 30 |
| 做市商买入债券 / 投资者卖出 | 做市商付 10,030 USDC → 投资者收 10,000 → 平台收 30 |
| 做市商之间交易 | 做市商 B 付 10,000 USDC → 做市商 A 收 10,000 → 平台不收 |

`quoteFee(bondToken, partyA, partyB, quoteAmount)` 提供链上手续费预估查询，做市商可在链下构造订单前调用。

## 协议特性

- 目标链为 HashKey Chain，内置测试网 `133` 与主网 `177` 的部署配置
- 关键控制平面采用 `AccessControl` + 角色治理，支持部署后向 Safe 交接权限
- `BondIssuance`、`RFQSettlement` 与每债券实例级的 `ComplianceModule` 使用 UUPS 代理部署模式
- `BondToken` 将合规限制外部化到 `ComplianceModule`，便于按债券实例独立配置白名单与角色
- 二级结算使用 EIP-712 typed data，对订单哈希、签名与 nonce 作严格校验
- 手续费路由根据参与方角色自动判断，做市商之间免手续费
- ABI 与事件接口采用 additive-first 的发布约定，方便前端、`abigen` 与 Subgraph 同步升级

## 仓库结构

```text
.
├── README.md
├── QUICKSTART.md
├── Makefile
├── config/
│   ├── anvil.json      ← 本地 Anvil（Anvil 预置账户 + MockERC20，默认启用 revokeDeployer）
│   ├── testnet.json    ← 测试网（需填入每个角色地址、代币、手续费等）
│   └── mainnet.json    ← 主网（需填入每个角色地址、代币、手续费等）
├── abi-export/
│   ├── abi/                 # 导出的 ABI JSON
│   ├── addresses/           # 链级地址清单
│   └── metadata/            # 版本、事件接口、发布元数据
├── contracts/
│   ├── src/                 # 核心合约
│   │   ├── BondFactory.sol
│   │   ├── BondToken.sol
│   │   ├── BondIssuance.sol
│   │   ├── RFQSettlement.sol
│   │   ├── compliance/ComplianceModule.sol
│   │   ├── abstracts/       # DomainPausable, RoleManaged
│   │   ├── interfaces/      # IBondFactory, IBondToken, IBondIssuance, IComplianceModule, IRFQSettlement
│   │   ├── libraries/       # BondErrors, BondMath, SettlementOrderEIP712
│   │   └── types/BondTypes.sol
│   ├── script/              # 部署脚本（FullDeploy + 配置解析 / JSON 输出 / 类型定义）、ABI 导出
│   ├── test/                # unit / fuzz / invariant / integration / fork
│   ├── foundry.toml
│   └── remappings.txt
└── deployments/             # 各链部署记录与交接状态
```

## 开发与交付流程

推荐按下面的顺序理解和使用仓库：

1. 在 `contracts/` 中编译、运行单元测试和集成测试
2. 编辑 `config/{env}.json`，配置每个合约的角色地址、结算代币策略、手续费与移交策略
3. 使用 `make deploy-anvil` 在本地链验证一站式部署
4. 使用 `make deploy-testnet` 或 `make deploy-mainnet` 一站式完成部署 → 配置 → 角色授予 → 权限移交
5. 使用 `make export-abi` 将 ABI 与发布元数据导出到 `abi-export/`

一站式部署脚本 `FullDeploy.s.sol` 在单次广播中完成全部操作（部署、注册合规模板、配置结算代币策略与手续费、逐角色授权、选择性撤销 deployer 权限），Anvil / Testnet / Mainnet 走完全相同的部署流水线，部署结果写入 `deployments/{chainId}.json`。

## 测试分层

仓库已经按 Foundry 常见分层组织测试：

- `unit/`：聚焦单个模块行为，例如发行审批、订单填充、合规模块管理、手续费模型
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
