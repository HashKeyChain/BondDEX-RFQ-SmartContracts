// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev 从 config/{env}.json 解析的完整部署配置。
struct DeployConfig {
    uint256 deployerPrivateKey;
    address deployer;
    // 新 ComplianceModule 代理的初始管理员
    address platformAdmin;
    // BondFactory 角色
    address factoryAdmin;
    address factoryIssuanceApprover;
    address factoryComplianceAdmin;
    address factoryPauser;
    // BondIssuance 角色
    address issuanceAdmin;
    address issuanceIssuanceApprover;
    address issuanceSettlementAdmin;
    address issuancePauser;
    address issuanceUpgrader;
    // RFQSettlement 角色
    address rfqAdmin;
    address rfqSettlementAdmin;
    address rfqPauser;
    address rfqUpgrader;
    // 手续费
    address feeRecipient;
    uint16 currentFeeBps;
    uint16 maxFeeBps;
    // 是否在部署后撤销 deployer 全部角色
    bool revokeDeployer;
}

/// @dev 单条结算代币策略。
struct TokenPolicy {
    address token;
    bool issuanceEnabled;
    bool settlementEnabled;
    bool redemptionEnabled;
    bool rfqSettlementEnabled;
}

/// @dev 部署产出的合约地址。
struct DeployResult {
    address bondFactory;
    address bondIssuance;
    address bondIssuanceImpl;
    address rfqSettlement;
    address rfqSettlementImpl;
    address complianceImpl;
}
