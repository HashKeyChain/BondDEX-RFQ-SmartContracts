# BondDEX RFQ Smart Contracts

[English](README.md)

`BondDEX RFQ Smart Contracts` 是一个面向 HashKey Chain 的 `contracts-first` 债券协议仓库。它覆盖了合规债券的创建与发行审批、一级市场认购、二级市场 RFQ 询价成交，以及到期后的赎回资金注入与持有人兑付领取。

这个仓库的目标不只是放 Solidity 合约本身，还包括完整的交付链路：

- 在 `contracts/` 中完成合约、脚本与测试开发
- 在 `deployments/` 中沉淀链级部署清单
- 在 `abi-export/` 中导出 ABI、地址与事件接口说明，供前端、Go 后端和索引器消费

## 业务范围

当前仓库的核心能力可以按 3 条主流程理解：

- `US1 - Launch and Subscribe`：平台审批发行，发行人创建债券（含 issueDate、dayCountConvention、couponFrequency、bondCategory、ISIN 等完整属性），配置合规模块，管理员审批认购窗口，做市商或合格参与方完成一级认购
- `US2 - RFQ Settlement`：做市商或投资者签名 EIP-712 订单（含 accruedInterest 字段），对手方按单成交，合约在链上验证应计利息合理性，支持批量成交、订单取消、nonce 管理和手续费收取（基于 dirty amount）。交易方向限制为做市商↔投资者和做市商↔做市商，禁止投资者↔投资者。手续费始终由做市商侧承担，做市商之间交易免手续费
- `US3 - Redemption and Claims`：债券到期后由发行人注入赎回资金（按年化利率 + 日期折算，平台链下流程强制要求全额存入），持有人直接领取或通过代理人代领（持有人须仍在白名单中）；超额赎回资金在全部赎回完成后由合约**自动转回发行人**，或由管理员调 `releaseExcessRedemption` 主动转回；对受制裁/被永久移出白名单的持有人，管理员可通过 `forceRedeem` 路径强制销毁其债券并把资金转入指定监管托管地址；`rescueTokens` 仅用于救援误转入合约的代币，不再承担退还赎回超额的职责

这 3 条主流程分别在 `contracts/test/integration/US1_LaunchAndSubscribe.t.sol`、`contracts/test/integration/US2_RfqSettlement.t.sol` 和 `contracts/test/integration/US3_RedemptionAndClaims.t.sol` 中有对应的集成测试覆盖，并由 `contracts/test/integration/BondLifecycleE2E.t.sol` 串成完整生命周期。

## 核心模块

| 模块 | 作用 |
| --- | --- |
| `BondFactory` | 负责发行审批、合规实现注册，以及创建 `BondToken` 和每只债对应的 `ComplianceModule` 实例；`createBond` 现接收含完整债券属性（issueDate、dayCountConvention、couponFrequency、bondCategory、isin）的 `BondConfig` 结构体 |
| `BondToken` | 债券 ERC-20 资产本体，记录发行人、面值、年化票息率、发行日、计息惯例、到期时间和结算币；构造器通过 `ConstructorParams` 结构体传参；转账限制委托给合规模块判断 |
| `ComplianceModule` | 负责白名单、角色矩阵、授权转账 operator、策略元数据与暂停域控制；限制债券转账方向（禁止投资者↔投资者）和参与方身份；强制所有用户间转账必须通过授权 operator（如 RFQSettlement）执行 |
| `BondIssuance` | 负责一级市场认购审批、认购窗口管理、赎回资金注入（赎回利息按年化利率 × 日期折算）、直接领取与代理领取（含持有人白名单校验）、超额赎回自动转回发行人（`releaseExcessRedemption` + 全员赎回触发的自动释放分支）、强制赎回受制裁持有人（`forceRedeem`）、误转资金救援（`rescueTokens`）与结算代币策略查询（`getSettlementTokenPolicy`） |
| `RFQSettlement` | 负责二级市场 RFQ 订单的 EIP-712 签名校验、应计利息链上验证（基于高精度 `BondToken.accruedInterestFor`，容差通过 `setAiToleranceSeconds` 配置）、强制 `order.quoteToken == bondToken.settlementToken()`、撮合成交、批量成交、取消、nonce floor、手续费策略（基于 dirty amount）、`quoteFee` 查询、UUPS 升级后 EIP-712 缓存刷新（`refreshDomainSeparator`） |
| `BondMath` | 基点计算与精度缩放工具库，供手续费计算和金额换算使用 |

## 手续费模型

RFQ 二级市场交易的手续费始终由做市商侧承担，投资者侧不受手续费影响，且**基于 dirty amount（quoteAmount + accruedInterest）计算**：

| 场景 | 资金流（以 30 bps 为例，含应计利息 500 USDC） |
| --- | --- |
| 做市商卖出债券 / 投资者买入 | 投资者付 10,500 USDC → 做市商收 10,468.5 → 平台收 31.5 |
| 做市商买入债券 / 投资者卖出 | 做市商付 10,531.5 USDC → 投资者收 10,500 → 平台收 31.5 |
| 做市商之间交易 | 做市商 B 付 10,500 USDC → 做市商 A 收 10,500 → 平台不收 |

`quoteFee(bondToken, partyA, partyB, dirtyAmount)` 提供链上手续费预估查询，做市商可在链下构造订单前调用（传入 dirty amount）。每笔订单通过 `maxFeeBps` 字段锁定 maker 签名时的最高费率预期，防止签名后费率被修改导致超预期扣费。

## 协议特性

- 目标链为 HashKey Chain，内置测试网 `133` 与主网 `177` 的部署配置
- 关键控制平面采用 `AccessControl` + 角色治理，支持部署后向 Safe 交接权限
- `BondIssuance`、`RFQSettlement` 与每债券实例级的 `ComplianceModule` 使用 UUPS 代理部署模式
- `BondToken` 将合规限制外部化到 `ComplianceModule`，便于按债券实例独立配置白名单、角色和授权 operator；构造器通过 `ConstructorParams` 结构体传参，支持完整债券属性
- `ComplianceModule` 的授权 operator 机制强制所有用户间债券转账必须通过平台合约（RFQSettlement）执行，防止私下转账绕过手续费和应计利息验证
- 二级结算使用 EIP-712 typed data，订单结构含 `accruedInterest` 字段，对订单哈希、签名与 nonce 作严格校验
- `BondToken` 支持完整债券属性：`issueDate`、`dayCountConvention`（ACT_365 / ACT_360）、`couponFrequency`（BULLET / ANNUAL）、`bondCategory`（CORPORATE / GOVERNMENT / CONVERTIBLE / ABS）、`isin`（bytes12）
- 赎回利息按年化利率 + 日期折算（ACT_365 / ACT_360 两种计息惯例）；`couponRateBps` 语义为年化利率
- RFQ 应计利息链上验证，容差通过 `setAiToleranceSeconds` 可调，防止恶意篡改同时容忍合理时间延迟
- 手续费路由根据参与方角色自动判断，做市商之间免手续费；手续费基于 dirty amount（含应计利息）计算
- `BondFactory.createBond` 拆分事件：`BondCreated`（含 issueDate）+ `BondMetadata`（计息惯例、付息频率、债券类别、ISIN）
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
│   ├── script/              # FullDeploy 部署、AnvilDemo 端到端演示、Operations 模块化操作、ABI 导出
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
6. 使用 `make demo-anvil` 在本地 Anvil 上按真实时间线运行完整生命周期演示（9 个参与者、按日推进应计利息、覆盖认购/RFQ 含 AI 和手续费/赎回/合规拒绝等场景）
7. 使用 `ENV=testnet make ops-*` 或 `ENV=mainnet make ops-*` 在测试网/主网执行模块化操作

一站式部署脚本 `FullDeploy.s.sol` 在单次广播中完成全部操作（部署、注册合规模板、配置结算代币策略与手续费、逐角色授权、选择性撤销 deployer 权限），Anvil / Testnet / Mainnet 走完全相同的部署流水线，部署结果写入 `deployments/{chainId}.json`。

`Operations.s.sol` 提供模块化操作脚本，每个函数对应一个链上操作（审批、合规、认购、RFQ、赎回、查询等），通过 `ENV` 环境变量切换 Anvil / 测试网 / 主网。

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

本地启动、核心命令、最小验证路径与测试网/主网的环境变量说明见根目录 `QUICKSTART.zh-CN.md`。
