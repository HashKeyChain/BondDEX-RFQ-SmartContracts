// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { MockERC20Decimals } from "../mocks/MockERC20Decimals.sol";
import { MockSafe } from "../mocks/MockSafe.sol";

abstract contract DeployFixtures is Test {
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal maker = makeAddr("maker");
    address internal investor = makeAddr("investor");

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal usdt;
    MockSafe internal safe;

    function deployBaseFixtures() internal {
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        usdt = new MockERC20Decimals("Mock USDT", "mUSDT", 6);

        address[] memory owners = new address[](2);
        owners[0] = admin;
        owners[1] = operator;
        safe = new MockSafe(owners, 2);
    }
}
