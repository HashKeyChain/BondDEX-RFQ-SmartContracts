// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FeeConfig, Order, PauseDomain } from "../types/BondTypes.sol";

interface IRFQSettlement {
    function fillOrder(Order calldata order, bytes calldata signature) external;
    function batchFillOrders(Order[] calldata orders, bytes[] calldata signatures) external;
    function cancelOrder(Order calldata order) external;
    function batchCancelOrders(Order[] calldata orders) external;
    function incrementNonce() external;
    function setMinimumNonce(uint256 newMinNonce) external;
    function setFeeConfig(FeeConfig calldata config) external;
    function setSettlementTokenPolicy(address token, bool enabled) external;
    function setBondTokenRegistration(address bondToken, bool registered) external;
    function setAiToleranceSeconds(uint256 toleranceSeconds) external;
    function isBondTokenRegistered(address bondToken) external view returns (bool);
    function pauseDomain(PauseDomain domain, bool paused) external;
    function hashOrder(Order calldata order) external view returns (bytes32);
    function isOrderConsumed(bytes32 orderHash) external view returns (bool);
    function isOrderCancelled(bytes32 orderHash) external view returns (bool);
    function currentNonce(address maker) external view returns (uint256);
    function feeConfig() external view returns (FeeConfig memory);
    function maxBatchSize() external view returns (uint256);
    function isSettlementTokenEnabled(address token) external view returns (bool);
    function aiToleranceSeconds() external view returns (uint256);
    function isDomainPaused(PauseDomain domain) external view returns (bool);
    function quoteFee(address bondToken, address partyA, address partyB, uint256 dirtyAmount)
        external
        view
        returns (uint256 feeAmount);
    function rescueTokens(address token, address to, uint256 amount) external;
    /// @dev AUDIT-FIX(N15): admin trigger to recompute the cached EIP-712 domain separator after a UUPS upgrade.
    function refreshDomainSeparator() external;
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}
