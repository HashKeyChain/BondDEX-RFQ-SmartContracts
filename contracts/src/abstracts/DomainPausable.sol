// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DomainAlreadySet, DomainPaused} from "../libraries/BondErrors.sol";
import {PauseDomain} from "../types/BondTypes.sol";

abstract contract DomainPausable {
    event PauseDomainUpdated(PauseDomain indexed domain, bool paused, address indexed operator);

    mapping(PauseDomain domain => bool paused) private _pausedDomains;

    function isDomainPaused(PauseDomain domain) public view virtual returns (bool) {
        return _pausedDomains[domain];
    }

    function _setDomainPaused(PauseDomain domain, bool paused) internal {
        if (_pausedDomains[domain] == paused) {
            revert DomainAlreadySet(domain, paused);
        }

        _pausedDomains[domain] = paused;
        emit PauseDomainUpdated(domain, paused, msg.sender);
    }

    function _requireDomainActive(PauseDomain domain) internal view {
        if (_pausedDomains[domain]) {
            revert DomainPaused(domain);
        }
    }
}
