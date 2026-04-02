// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DomainPausable} from "../../src/abstracts/DomainPausable.sol";
import {PauseDomain} from "../../src/types/BondTypes.sol";
import {DomainAlreadySet, DomainPaused} from "../../src/libraries/BondErrors.sol";

contract DomainPausableHarness is DomainPausable {
    function setPaused(PauseDomain domain, bool paused) external {
        _setDomainPaused(domain, paused);
    }

    function requireActive(PauseDomain domain) external view {
        _requireDomainActive(domain);
    }
}

contract DomainPausableTest is Test {
    function test_domainStartsUnpaused() public {
        DomainPausableHarness harness = new DomainPausableHarness();
        assertFalse(harness.isDomainPaused(PauseDomain.SETTLEMENT));
    }

    function test_setDomainPauseMarksDomainPaused() public {
        DomainPausableHarness harness = new DomainPausableHarness();
        harness.setPaused(PauseDomain.SETTLEMENT, true);

        assertTrue(harness.isDomainPaused(PauseDomain.SETTLEMENT));
    }

    function test_revertWhenSettingDomainToSameState() public {
        DomainPausableHarness harness = new DomainPausableHarness();
        harness.setPaused(PauseDomain.CLAIMS, true);

        vm.expectRevert(abi.encodeWithSelector(DomainAlreadySet.selector, PauseDomain.CLAIMS, true));
        harness.setPaused(PauseDomain.CLAIMS, true);
    }

    function test_revertWhenDomainIsPaused() public {
        DomainPausableHarness harness = new DomainPausableHarness();
        harness.setPaused(PauseDomain.REDEMPTION_FUNDING, true);

        vm.expectRevert(abi.encodeWithSelector(DomainPaused.selector, PauseDomain.REDEMPTION_FUNDING));
        harness.requireActive(PauseDomain.REDEMPTION_FUNDING);
    }
}
