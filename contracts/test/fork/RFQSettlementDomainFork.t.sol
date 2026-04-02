// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Order, OrderSide} from "../../src/types/BondTypes.sol";
import {RFQSettlement} from "../../src/RFQSettlement.sol";

contract RFQSettlementDomainForkTest is Test {
    using ECDSA for bytes32;

    uint256 internal constant MAKER_PK = 0xA11CE;

    function test_hashOrderUsesHashKeyTestnetDomain() public {
        string memory rpcUrl = vm.envOr("HSK_TESTNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        uint256 forkBlock = vm.envOr("HSK_TESTNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        assertEq(block.chainid, 133);

        RFQSettlement implementation = new RFQSettlement();
        RFQSettlement settlement = RFQSettlement(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(RFQSettlement.initialize, (address(this)))))
        );

        Order memory order = Order({
            maker: vm.addr(MAKER_PK),
            taker: address(0xB0B1),
            bondToken: address(0xB0D1),
            quoteToken: address(0xC0DE),
            bondAmount: 10e18,
            quoteAmount: 10_500e6,
            side: OrderSide.BUY,
            expiry: block.timestamp + 1 days,
            nonce: 0,
            salt: 1
        });

        bytes32 digest = settlement.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, digest);

        assertEq(digest.recover(abi.encodePacked(r, s, v)), order.maker);
    }
}
