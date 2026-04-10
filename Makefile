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
# 两阶段执行：到期前 → 推进时间 → 到期后
# Anvil auto-mine 模式下每个 broadcast 交易独占一个区块

.PHONY: demo-anvil demo-anvil-pre demo-anvil-post demo-anvil-sim

# 执行完整生命周期演示
demo-anvil: demo-anvil-pre
	@echo ""
	@echo ">>> Warping Anvil time past maturity (30 days + 1s)..."
	@cast rpc --rpc-url $(call cfg,anvil,rpcUrl) evm_increaseTime 2592001 > /dev/null
	@cast rpc --rpc-url $(call cfg,anvil,rpcUrl) evm_mine > /dev/null
	@echo ">>> Time warped. Running post-maturity phases..."
	@echo ""
	$(MAKE) demo-anvil-post

# 执行到期前阶段
demo-anvil-pre:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/AnvilDemo.s.sol:AnvilDemo \
		--sig "runPreMaturity()" \
		--rpc-url $(call cfg,anvil,rpcUrl) \
		--broadcast

# 执行到期后阶段
demo-anvil-post:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/AnvilDemo.s.sol:AnvilDemo \
		--sig "runPostMaturity()" \
		--rpc-url $(call cfg,anvil,rpcUrl) \
		--broadcast

# 执行纯模拟阶段
demo-anvil-sim:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/AnvilDemo.s.sol:AnvilDemo \
		--sig "run()" \
		--rpc-url $(call cfg,anvil,rpcUrl)

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
.PHONY: ops-create-subscription ops-subscribe ops-close-subscription ops-update-subscription
.PHONY: ops-fill-order ops-cancel-order ops-increment-nonce
.PHONY: ops-deposit-redemption ops-claim ops-claim-for ops-set-delegate
.PHONY: ops-pause-factory ops-pause-issuance ops-pause-settlement
.PHONY: ops-set-fee-config ops-set-bond-token ops-mint-usdc ops-approve-token
.PHONY: ops-query-order ops-query-redemption ops-query-subscription ops-query-remaining-units
.PHONY: ops-query-compliance ops-query-fee-config ops-query-nonce ops-query-fee
.PHONY: ops-query-bond-token ops-query-balance ops-query-bond-balances

# 审批发行
ops-approve-issuance:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "approveIssuance(bytes32,address,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 创建债券
ops-create-bond:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "createBond(bytes32,string,string,uint8,uint256,uint256,uint256,address)" $(ARGS) \
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

# 创建订阅
ops-create-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "createSubscription(address,address,uint256,uint256,uint256,uint256)" $(ARGS) \
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
		--sig "fillOrder(address,address,address,address,uint256,uint256,uint8,uint256,uint256,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

# 取消订单
ops-cancel-order:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "cancelOrder(address,address,address,address,uint256,uint256,uint8,uint256,uint256,uint256)" $(ARGS) \
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

# 设置债券 token
ops-set-bond-token:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "setBondTokenRegistration(address,bool)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast

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

# 更新订阅
ops-update-subscription:
	cd $(CONTRACTS_DIR) && forge script $(OPS_SCRIPT) \
		--sig "updateSubscription(bytes32,address,address,uint256,uint256,uint256,uint256)" $(ARGS) \
		--rpc-url $(OPS_RPC) --broadcast
