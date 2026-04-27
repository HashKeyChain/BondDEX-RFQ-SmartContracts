# ──────────────────────────────────────────────────────────────
# BondDEX-RFQ 部署 Makefile
#
# 角色地址与策略配置集中在 config/{env}.json；
# 部署者私钥通过 DEPLOYER_PRIVATE_KEY 环境变量传入，不存储在文件中。
# 一条命令完成：部署 → 注册合规模板 → 配置结算代币 → 配置手续费 → 权限移交。
#
# 用法:
#   make deploy-anvil                                              # 本地 Anvil
#   DEPLOYER_PRIVATE_KEY=0x... make deploy-testnet                 # 测试网
#   DEPLOYER_PRIVATE_KEY=0x... make deploy-mainnet                 # 主网
# ──────────────────────────────────────────────────────────────

CONTRACTS_DIR := contracts
SCRIPT_DIR    := script

# 从 config JSON 提取字段 — $(call cfg,env,field)
define cfg
$(shell jq -r '.$(2)' config/$(1).json)
endef

# ─── 一站式部署 ──────────────────────────────────────────────

.PHONY: deploy-anvil deploy-testnet deploy-mainnet

deploy-anvil:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/FullDeploy.s.sol:FullDeploy \
		--sig "anvil()" \
		--rpc-url $(call cfg,anvil,rpcUrl) \
		--broadcast

deploy-testnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/FullDeploy.s.sol:FullDeploy \
		--sig "testnet()" \
		--rpc-url $(call cfg,testnet,rpcUrl) \
		--broadcast

deploy-mainnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/FullDeploy.s.sol:FullDeploy \
		--sig "mainnet()" \
		--rpc-url $(call cfg,mainnet,rpcUrl) \
		--broadcast

# ─── 构建 & 测试 ─────────────────────────────────────────────

.PHONY: build test test-us1 test-us2 test-us3 test-e2e export-abi

build:
	cd $(CONTRACTS_DIR) && forge build

test:
	cd $(CONTRACTS_DIR) && forge test

test-us1:
	cd $(CONTRACTS_DIR) && forge test --match-contract US1LaunchAndSubscribeIntegrationTest

test-us2:
	cd $(CONTRACTS_DIR) && forge test --match-contract US2RfqSettlementIntegrationTest

test-us3:
	cd $(CONTRACTS_DIR) && forge test --match-contract US3RedemptionAndClaimsIntegrationTest

test-e2e:
	cd $(CONTRACTS_DIR) && forge test --match-contract BondLifecycleE2ETest

export-abi:
	cd $(CONTRACTS_DIR) && forge build && forge script $(SCRIPT_DIR)/ExportAbi.s.sol:ExportAbi

# ─── Anvil 全自动演示 ────────────────────────────────────────
# 演示使用固定时间线（2026-01-01 起），需要 Anvil 从更早的时间启动。
#
# 一键执行（自动启动 Anvil → 部署 → 演示 → 关闭 Anvil）：
#   make demo-anvil
#
# 纯模拟（不需要 Anvil，含 vm.warp）：
#   make demo-anvil-sim
#
# 时间线（UTC）：
#   2025-12-31 00:00  Anvil 启动时间
#   2026-01-01 00:00  认购窗口开启 → Phase 1-4
#   2026-01-09 00:12  起息日 + 12min → Step 7
#   +2 天              → Step 8-9
#   +30 天             → Step 10
#   +30 天             → Step 11
#   +30 天             → Step 12-13, 15
#   2027-01-09 00:01  到期日 + 1s → Step 16-17

# Anvil 启动时间戳：2025-12-31 00:00 UTC（认购前一天，确保时间线可向前推进）
DEMO_ANVIL_TS := 1767139200
DEMO_RPC      := $(call cfg,anvil,rpcUrl)
DEMO_SCRIPT   := $(SCRIPT_DIR)/AnvilDemo.s.sol:AnvilDemo
DEMO_PK       := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.PHONY: demo-anvil demo-anvil-sim

# 全自动演示：启动 Anvil → 部署 → 分步执行演示 → 关闭 Anvil
demo-anvil:
	@echo "=== BondDEX RFQ — Full Lifecycle Demo ==="
	@echo ""
	@echo ">>> Stopping existing Anvil (if any)..."
	@-pkill -f "anvil" 2>/dev/null || true
	@sleep 1
	@echo ">>> Starting Anvil (timestamp: 2025-12-31 00:00 UTC)..."
	@anvil --timestamp $(DEMO_ANVIL_TS) --silent &
	@sleep 2
	@echo ">>> Deploying contracts..."
	@DEPLOYER_PRIVATE_KEY=$(DEMO_PK) $(MAKE) deploy-anvil
	@echo ""
	@echo ">>> [Phase 1-4] Setting time to 2026-01-01 00:00 UTC (subscription opens)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_setNextBlockTimestamp 1767225600 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runSetup()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 7] Warping to 2026-01-09 00:12 UTC (issueDate + 12 min)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_setNextBlockTimestamp 1767917520 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runStep7()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 8-9] Warping +2 days"
	@cast rpc --rpc-url $(DEMO_RPC) evm_increaseTime 172800 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runStep8()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 10] Warping +30 days (~1 month)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_increaseTime 2592000 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runStep10()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 11] Warping +30 days (~2 months)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_increaseTime 2592000 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runStep11()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 12-13, 15] Warping +30 days (~3 months)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_increaseTime 2592000 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runStep12()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> [Step 16-17] Warping to 2027-01-09 00:00:01 UTC (maturity + 1)"
	@cast rpc --rpc-url $(DEMO_RPC) evm_setNextBlockTimestamp 1799452801 > /dev/null
	@cast rpc --rpc-url $(DEMO_RPC) evm_mine > /dev/null
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "runPostMaturity()" --rpc-url $(DEMO_RPC) --broadcast
	@echo ""
	@echo ">>> Stopping Anvil..."
	@-pkill -f "anvil --timestamp $(DEMO_ANVIL_TS)" 2>/dev/null || true

# 纯模拟（不需要运行 Anvil，含 vm.warp，全流程一次跑完）
# 需要先有 deployments/31337.json（先运行过 deploy-anvil）
demo-anvil-sim:
	cd $(CONTRACTS_DIR) && forge script $(DEMO_SCRIPT) \
		--sig "run()" --rpc-url $(DEMO_RPC)

# ─── 模块化操作（Operations） ─────────────────────────────────
# 通过 ENV 变量选择网络（默认 anvil），DEPLOYER_PRIVATE_KEY 传入私钥。
#
# 用法:
#   make ops-approve-issuance ARGS="..."                           # 默认 Anvil
#   ENV=testnet DEPLOYER_PRIVATE_KEY=0x... make ops-approve-issuance ARGS="..."  # 测试网
#   ENV=mainnet DEPLOYER_PRIVATE_KEY=0x... make ops-approve-issuance ARGS="..."  # 主网
#
# 查询类操作（ops-query-*）不需要私钥。

ENV ?= anvil
OPS_RPC := $(call cfg,$(ENV),rpcUrl)
OPS_SCRIPT := $(SCRIPT_DIR)/Operations.s.sol:Operations

.PHONY: ops-approve-issuance ops-create-bond ops-set-whitelist ops-set-role
.PHONY: ops-approve-subscription ops-revoke-subscription-approval ops-create-subscription ops-subscribe ops-close-subscription
.PHONY: ops-fill-order ops-cancel-order ops-increment-nonce
.PHONY: ops-deposit-redemption ops-claim ops-claim-for ops-set-delegate ops-rescue-tokens ops-release-excess-redemption
.PHONY: ops-mark-issuance-expired ops-mark-subscription-expired
.PHONY: ops-pause-factory ops-pause-issuance ops-pause-settlement ops-pause-compliance
.PHONY: ops-set-minimum-nonce
.PHONY: ops-set-fee-config ops-set-ai-tolerance ops-query-ai-tolerance ops-set-bond-token ops-mint-usdc ops-approve-token
.PHONY: ops-query-order ops-query-redemption ops-query-subscription ops-query-remaining-units
.PHONY: ops-query-subscription-approval
.PHONY: ops-query-compliance ops-query-fee-config ops-query-nonce ops-query-fee
.PHONY: ops-query-bond-token ops-query-balance ops-query-bond-balances

# 审批发行
# AUDIT-FIX(N3): metadataHash 必须等于 BondFactory.hashBondConfig(config)
#   ARGS 形如：<approvalId> <issuer> <expiresAt> <metadataHash>
#   metadataHash 可由 `cast call $$FACTORY 'hashBondConfig((<bondConfigAbi>))' "$$CFG"` 取得。
ops-approve-issuance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "approveIssuance(bytes32,address,uint256,bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 创建债券
# extendedData = $(cast abi-encode "f(uint256,uint8,uint8,uint8,bytes12)" <issueDate> <dayCount> <couponFreq> <category> <isin>)
ops-create-bond:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "createBond(bytes32,string,string,uint8,uint256,uint256,uint256,address,bytes)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置白名单
ops-set-whitelist:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setWhitelist(address,address,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置角色
ops-set-role:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setRole(address,address,uint8)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 审批认购
ops-approve-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "approveSubscription(bytes32,address,address,uint256,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 撤销认购审批
ops-revoke-subscription-approval:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "revokeSubscriptionApproval(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 创建订阅（需先审批）
ops-create-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "createSubscription(address,address,uint256,uint256,uint256,uint256,bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 订阅
ops-subscribe:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "subscribe(bytes32,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 关闭订阅
ops-close-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "closeSubscription(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 填充订单
ops-fill-order:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "fillOrder(address,address,address,address,uint256,uint256,uint8,uint256,uint256,uint256,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 取消订单
ops-cancel-order:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "cancelOrder(address,address,address,address,uint256,uint256,uint8,uint256,uint256,uint256,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 增加 nonce
ops-increment-nonce:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "incrementNonce()" \
		--rpc-url $(OPS_RPC) --broadcast

# 存款赎回
ops-deposit-redemption:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "depositRedemption(address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 赎回
ops-claim:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "claim(address)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 代为赎回
ops-claim-for:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "claimFor(address,address)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置赎回委托
ops-set-delegate:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setClaimDelegate(address)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 紧急代币救援
ops-rescue-tokens:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "rescueTokens(address,address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 释放超额赎回负债（债券到期后）
ops-release-excess-redemption:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "releaseExcessRedemption(address)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 标记过期的发行审批
ops-mark-issuance-expired:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "markIssuanceExpired(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 标记过期的认购审批
ops-mark-subscription-expired:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "markSubscriptionExpired(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置最小 nonce
ops-set-minimum-nonce:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setMinimumNonce(uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 暂停工厂
ops-pause-factory:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "pauseDomainFactory(uint8,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 暂停发行
ops-pause-issuance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "pauseDomainIssuance(uint8,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 暂停结算
ops-pause-settlement:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "pauseDomainSettlement(uint8,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 暂停合规模块
ops-pause-compliance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "pauseDomainCompliance(address,uint8,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置债券 token
ops-set-bond-token:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setBondTokenRegistration(address,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 设置应计利息容差
ops-set-ai-tolerance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setAiToleranceSeconds(uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 查询应计利息容差
ops-query-ai-tolerance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryAiTolerance()" \
		--rpc-url $(OPS_RPC)

# 设置手续费配置
ops-set-fee-config:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setFeeConfig(address,uint16,uint16)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 批准代币
ops-approve-token:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "approveToken(address,address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# Mock USDC 铸造（仅 Anvil）
ops-mint-usdc:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "mintMockUSDC(address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 查询订单
ops-query-order:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryOrderStatus(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询赎回
ops-query-redemption:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryRedemptionState(address)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询订阅
ops-query-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "querySubscription(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询合规
ops-query-compliance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryCompliance(address,address)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询手续费配置
ops-query-fee-config:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryFeeConfig()" \
		--rpc-url $(OPS_RPC)

# 查询 nonce
ops-query-nonce:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryNonce(address)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询债券 token
ops-query-bond-token:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryBondTokenRegistration(address)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询手续费
ops-query-fee:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryFee(address,address,address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询余额
ops-query-balance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryBalance(address,address)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询债券余额
ops-query-bond-balances:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryBondBalances(address,address[])" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询剩余单位
ops-query-remaining-units:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "queryRemainingUnits(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC)

# 查询认购审批
ops-query-subscription-approval:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "querySubscriptionApproval(bytes32)" $(ARGS) \
		--rpc-url $(OPS_RPC)
