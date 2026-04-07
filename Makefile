# ──────────────────────────────────────────────────────────────
# BondDEX-RFQ 部署 Makefile
#
# 所有配置（含私钥）集中在 config/{env}.json，零环境变量。
# ⚠️  请勿将含真实私钥的 config/*.json 提交到 Git。
#
# 用法:
#   make deploy-anvil
#   make deploy-testnet
#   make configure-testnet
#   make handoff-testnet
# ──────────────────────────────────────────────────────────────

CONTRACTS_DIR := contracts
SCRIPT_DIR    := script

# 从 config JSON 提取字段 — $(call cfg,env,field)
define cfg
$(shell jq -r '.$(2)' config/$(1).json)
endef

# ─── 部署 ────────────────────────────────────────────────────

.PHONY: deploy-anvil deploy-testnet deploy-mainnet

deploy-anvil:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/Deploy.s.sol:Deploy \
		--sig "anvil()" \
		--rpc-url $(call cfg,anvil,rpcUrl) \
		--broadcast

deploy-testnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/Deploy.s.sol:Deploy \
		--sig "testnet()" \
		--rpc-url $(call cfg,testnet,rpcUrl) \
		--broadcast

deploy-mainnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/Deploy.s.sol:Deploy \
		--sig "mainnet()" \
		--rpc-url $(call cfg,mainnet,rpcUrl) \
		--broadcast

# ─── 部署后配置 ──────────────────────────────────────────────

.PHONY: configure-testnet configure-mainnet handoff-testnet handoff-mainnet

configure-testnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/PostDeploy.s.sol:PostDeploy \
		--sig "configureRoles()" \
		--rpc-url $(call cfg,testnet,rpcUrl) \
		--broadcast

configure-mainnet:
	cd $(CONTRACTS_DIR) && forge script $(SCRIPT_DIR)/PostDeploy.s.sol:PostDeploy \
		--sig "configureRoles()" \
		--rpc-url $(call cfg,mainnet,rpcUrl) \
		--broadcast

handoff-testnet:
	cd $(CONTRACTS_DIR) && REVOKE_CALLER_ROLES=true forge script $(SCRIPT_DIR)/PostDeploy.s.sol:PostDeploy \
		--sig "configureAndHandoff()" \
		--rpc-url $(call cfg,testnet,rpcUrl) \
		--broadcast

handoff-mainnet:
	cd $(CONTRACTS_DIR) && REVOKE_CALLER_ROLES=true forge script $(SCRIPT_DIR)/PostDeploy.s.sol:PostDeploy \
		--sig "configureAndHandoff()" \
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
