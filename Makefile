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
