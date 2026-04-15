// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Order } from "../../src/types/BondTypes.sol";
import { RFQSettlement } from "../../src/RFQSettlement.sol";
import { RFQSettlementFixtures } from "../helpers/RFQSettlementFixtures.sol";

contract RFQSettlementEIP712Test is RFQSettlementFixtures {
    using ECDSA for bytes32;

    function setUp() public {
        deployRfqFixtures();
    }

    function test_hashOrderChangesAcrossChainOrContract() public {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);

        RFQSettlement otherImplementation = new RFQSettlement();
        RFQSettlement otherSettlement = RFQSettlement(
            address(
                new ERC1967Proxy(address(otherImplementation), abi.encodeCall(RFQSettlement.initialize, (admin, 1_000)))
            )
        );

        assertNotEq(settlement.hashOrder(order), otherSettlement.hashOrder(order));
    }

    function test_hashOrderProducesMakerRecoverableDigest() public view {
        Order memory order = makeBuyOrder(10e18, 10_500e6, 0, 1);
        bytes32 digest = settlement.hashOrder(order);
        bytes memory signature = signOrder(order, MAKER_PK);

        assertEq(digest.recover(signature), maker);
    }

    function test_hashOrderChangesWhenNonceChanges() public view {
        Order memory first = makeBuyOrder(10e18, 10_500e6, 0, 1);
        Order memory second = makeBuyOrder(10e18, 10_500e6, 1, 1);

        assertNotEq(settlement.hashOrder(first), settlement.hashOrder(second));
    }
}
