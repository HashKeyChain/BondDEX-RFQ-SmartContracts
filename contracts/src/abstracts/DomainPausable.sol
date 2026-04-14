// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DomainAlreadySet, DomainPaused} from "../libraries/BondErrors.sol";
import {PauseDomain} from "../types/BondTypes.sol";

/// @title DomainPausable
/// @notice Lightweight pause switch that lets each lifecycle domain be stopped independently.
abstract contract DomainPausable {
    /// @notice Emitted when the paused state of one domain changes.
    event PauseDomainUpdated(
        PauseDomain indexed domain,
        bool paused,
        address indexed operator
    );

    /// @dev Pause state keyed by lifecycle domain.
    mapping(PauseDomain domain => bool paused) private _pausedDomains;

    /// @dev Reserved storage gap for proxy-safe upgrades in UUPS contracts that inherit
    /// DomainPausable. Non-upgradeable contracts (e.g., BondFactory) inherit this gap
    /// harmlessly — it only costs deployment gas and has no runtime impact.
    uint256[49] private __gap;

    /// @notice Returns whether the domain is currently paused.
    /// @param domain Lifecycle domain to inspect.
    /// @return paused True when the domain is paused.
    function isDomainPaused(
        PauseDomain domain
    ) public view virtual returns (bool) {
        return _pausedDomains[domain];
    }

    /// @dev Updates the pause flag for one lifecycle domain and emits the canonical event.
    /// NOTE: This function reverts (not silently no-ops) when the domain already holds the
    /// requested state. Callers in multi-sig or automated retry scenarios should query
    /// `isDomainPaused` before sending the transaction to avoid unexpected reverts.
    function _setDomainPaused(PauseDomain domain, bool paused) internal {
        if (_pausedDomains[domain] == paused) {
            revert DomainAlreadySet(domain, paused);
        }

        _pausedDomains[domain] = paused;
        emit PauseDomainUpdated(domain, paused, msg.sender);
    }

    /// @dev Reverts when the specified lifecycle domain is paused.
    function _requireDomainActive(PauseDomain domain) internal view {
        if (_pausedDomains[domain]) {
            revert DomainPaused(domain);
        }
    }
}
