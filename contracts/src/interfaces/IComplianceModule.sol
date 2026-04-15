// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PauseDomain, Role } from "../types/BondTypes.sol";

interface IComplianceModule {
    function setWhitelist(address account, bool allowed) external;
    function batchSetWhitelist(address[] calldata accounts, bool[] calldata allowed) external;
    function setRole(address account, Role role) external;
    function batchSetRole(address[] calldata accounts, Role[] calldata roles) external;
    function setPolicyMetadata(bytes32 policyId, uint256 policyVersion) external;
    function pauseDomain(PauseDomain domain, bool paused) external;
    function isWhitelisted(address account) external view returns (bool);
    function roleOf(address account) external view returns (Role);
    function isDomainPaused(PauseDomain domain) external view returns (bool);
    function checkTransfer(address from, address to, uint256 amount, address operator) external view returns (uint8);
    function setTransferOperator(address operator, bool authorized) external;
    function isTransferOperator(address operator) external view returns (bool);
    function policyId() external view returns (bytes32);
    function policyVersion() external view returns (uint256);
}
