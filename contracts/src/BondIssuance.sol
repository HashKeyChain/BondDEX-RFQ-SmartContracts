// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { DomainPausable } from "./abstracts/DomainPausable.sol";
import { RoleManaged } from "./abstracts/RoleManaged.sol";
import {
    BondAlreadyMatured,
    BondNotMatured,
    ExpiredDeadline,
    InvalidParticipantRole,
    InvalidSubscriptionWindow,
    InsufficientRedemptionFunding,
    InsufficientRescuableBalance,
    MaxUnitsExceedsApproval,
    NoClaimableBalance,
    NotWhitelisted,
    SettlementTokenHasRedemptionLiability,
    SubscriptionApprovalNotActive,
    SubscriptionCapExceeded,
    SubscriptionNotActive,
    SubscriptionWindowClosed,
    SubscriptionWindowExceedsApprovalExpiry,
    SubscriptionWindowExceedsIssueDate,
    SubscriptionWindowAlreadyClosed,
    SubscriptionWindowMissingCloseTime,
    UnsupportedSettlementToken,
    UnauthorizedClaimCaller,
    ZeroAddress,
    ZeroAmount,
    ZeroId
} from "./libraries/BondErrors.sol";
import { IComplianceModule } from "./interfaces/IComplianceModule.sol";
import { IBondIssuance } from "./interfaces/IBondIssuance.sol";
import { IBondToken } from "./interfaces/IBondToken.sol";
import { ApprovalStatus, PauseDomain, Role, SubscriptionStatus, SubscriptionTerms } from "./types/BondTypes.sol";

contract BondIssuance is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    DomainPausable,
    RoleManaged,
    IBondIssuance
{
    using SafeERC20 for IERC20;

    /// @dev `settlementEnabled` was removed in the post-N1 cleanup: it was a zombie field with no
    ///      `require` site in the codebase. Token-level RFQ settlement gating lives entirely in
    ///      `RFQSettlement.setSettlementTokenPolicy`. BondIssuance only cares about the two
    ///      flow-specific gates below.
    struct SettlementTokenPolicy {
        bool issuanceEnabled;
        bool redemptionEnabled;
    }

    struct SubscriptionOffer {
        address issuer;
        address bondToken;
        address settlementToken;
        uint256 unitPrice;
        uint256 maxUnits;
        uint256 soldUnits;
        uint256 opensAt;
        uint256 closesAt;
        SubscriptionStatus status;
    }

    struct SubscriptionApprovalRecord {
        address issuer;
        address bondToken;
        uint256 maxUnits;
        uint256 expiresAt;
        ApprovalStatus status;
    }

    struct RedemptionState {
        uint256 fundedAmount;
        uint256 claimedAmount;
        uint256 lastFundingAt;
    }

    event SettlementTokenPolicyUpdated(
        address indexed token, bool issuanceEnabled, bool redemptionEnabled, address operator
    );
    event SubscriptionCreated(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed issuer,
        address settlementToken,
        uint256 unitPrice,
        uint256 maxUnits,
        uint256 opensAt,
        uint256 closesAt
    );
    event SubscriptionApproved(
        bytes32 indexed approvalId,
        address indexed issuer,
        address indexed bondToken,
        address approver,
        uint256 maxUnits,
        uint256 expiresAt
    );
    event SubscriptionApprovalRevoked(bytes32 indexed approvalId, address indexed issuer, address approver);
    event SubscriptionApprovalExpired(bytes32 indexed approvalId, address indexed issuer, address operator);
    event Subscribed(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed subscriber,
        address settlementToken,
        uint256 units,
        uint256 cost
    );
    event RedemptionDeposited(
        address indexed bondToken,
        address indexed issuer,
        address indexed settlementToken,
        uint256 amount,
        uint256 cumulativeFundedAmount
    );
    event RedemptionClaimed(
        address indexed bondToken, address indexed holder, address indexed claimer, uint256 bondAmount, uint256 payout
    );
    event SubscriptionClosed(bytes32 indexed offerId, address indexed bondToken, address indexed issuer);
    event TokensRescued(address indexed token, address indexed to, uint256 amount, address indexed operator);
    event ExcessRedemptionReleased(address indexed bondToken, address indexed settlementToken, uint256 excessAmount);
    /// @dev AUDIT-FIX(N6): emitted whenever the auto-release path actually transfers excess to issuer.
    event ExcessRedemptionRefunded(
        address indexed bondToken, address indexed settlementToken, address indexed issuer, uint256 excessAmount
    );
    event ClaimDelegateSet(address indexed holder, address indexed delegate, address operator);
    /// @dev AUDIT-FIX(N5): emitted when an admin force-redeems a sanctioned/blacklisted holder.
    event ForceRedemption(
        address indexed bondToken,
        address indexed holder,
        address indexed recipient,
        uint256 bondAmount,
        uint256 payout,
        address operator
    );

    uint256 private _nextOfferId;
    mapping(address token => SettlementTokenPolicy policy) private _settlementTokenPolicies;
    mapping(bytes32 offerId => SubscriptionOffer offer) private _subscriptionOffers;
    mapping(bytes32 approvalId => SubscriptionApprovalRecord record) private _subscriptionApprovals;
    mapping(address holder => address delegate) private _claimDelegates;
    mapping(address bondToken => RedemptionState state) private _redemptionStates;
    mapping(address token => uint256 liability) private _totalRedemptionLiability;
    uint256[43] private __gap;

    constructor() { _disableInitializers(); }

    /// @dev AUDIT-FIX(N11) revisited: principle of least privilege at initialization. Only
    ///      DEFAULT_ADMIN_ROLE is granted to the initial admin; secondary governance roles
    ///      (ISSUANCE_APPROVER_ROLE / SETTLEMENT_ADMIN_ROLE / PAUSER_ROLE / UPGRADER_ROLE) must
    ///      be granted explicitly via standard AccessControl. The initial admin can immediately
    ///      self-grant any role they need because DEFAULT_ADMIN_ROLE is the OZ default
    ///      `getRoleAdmin` for every role.
    function initialize(address admin) external initializer {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(admin);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function approveSubscription(
        bytes32 approvalId,
        address issuer,
        address bondToken,
        uint256 maxUnits,
        uint256 expiresAt
    ) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        if (approvalId == bytes32(0)) revert ZeroId();
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(issuer);
        _ensureNonZero(bondToken);
        if (maxUnits == 0) revert ZeroAmount();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiredDeadline(expiresAt, block.timestamp);
        ApprovalStatus currentStatus = _subscriptionApprovals[approvalId].status;
        if (currentStatus != ApprovalStatus.NONE) revert SubscriptionApprovalNotActive(approvalId, currentStatus);
        _subscriptionApprovals[approvalId] = SubscriptionApprovalRecord({
            issuer: issuer,
            bondToken: bondToken,
            maxUnits: maxUnits,
            expiresAt: expiresAt,
            status: ApprovalStatus.ACTIVE
        });
        emit SubscriptionApproved(approvalId, issuer, bondToken, msg.sender, maxUnits, expiresAt);
    }

    function revokeSubscriptionApproval(bytes32 approvalId) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        SubscriptionApprovalRecord storage record = _subscriptionApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert SubscriptionApprovalNotActive(approvalId, record.status);
        record.status = ApprovalStatus.REVOKED;
        emit SubscriptionApprovalRevoked(approvalId, record.issuer, msg.sender);
    }

    function markSubscriptionExpired(bytes32 approvalId) external {
        SubscriptionApprovalRecord storage record = _subscriptionApprovals[approvalId];
        if (record.status != ApprovalStatus.ACTIVE) revert SubscriptionApprovalNotActive(approvalId, record.status);
        if (record.expiresAt == 0 || record.expiresAt > block.timestamp) {
            revert SubscriptionApprovalNotActive(approvalId, record.status);
        }
        record.status = ApprovalStatus.EXPIRED;
        emit SubscriptionApprovalExpired(approvalId, record.issuer, msg.sender);
    }

    function createSubscription(SubscriptionTerms calldata terms, bytes32 approvalId)
        external
        returns (bytes32 offerId)
    {
        _requireDomainActive(PauseDomain.SUBSCRIPTION);
        _requireIssuanceTokenEnabled(terms.settlementToken);
        SubscriptionApprovalRecord storage approval = _subscriptionApprovals[approvalId];
        if (approval.status != ApprovalStatus.ACTIVE) {
            revert SubscriptionApprovalNotActive(approvalId, approval.status);
        }
        if (approval.expiresAt != 0 && approval.expiresAt <= block.timestamp) {
            revert SubscriptionApprovalNotActive(approvalId, ApprovalStatus.EXPIRED);
        }
        // AUDIT-FIX(N10): subscription window must not extend past the approval expiry; otherwise an
        //                 issuer could open the window seconds before approval expiry and let it run for
        //                 the entire bond pre-issue period, bypassing the platform-imposed deadline.
        if (approval.expiresAt != 0 && terms.closesAt > approval.expiresAt) {
            revert SubscriptionWindowExceedsApprovalExpiry(terms.closesAt, approval.expiresAt);
        }
        if (approval.issuer != msg.sender) revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        if (approval.bondToken != terms.bondToken) revert SubscriptionApprovalNotActive(approvalId, approval.status);
        if (terms.maxUnits > approval.maxUnits) {
            revert MaxUnitsExceedsApproval(approvalId, terms.maxUnits, approval.maxUnits);
        }
        IBondToken bondToken = IBondToken(terms.bondToken);
        if (bondToken.settlementToken() != terms.settlementToken) {
            revert UnsupportedSettlementToken(terms.settlementToken);
        }
        _requireIssuer(bondToken, msg.sender);
        _requireValidWindow(terms.opensAt, terms.closesAt);
        if (terms.closesAt > bondToken.issueDate()) {
            revert SubscriptionWindowExceedsIssueDate(terms.closesAt, bondToken.issueDate());
        }
        if (block.timestamp >= bondToken.maturityTimestamp()) {
            revert BondAlreadyMatured(terms.bondToken, bondToken.maturityTimestamp(), block.timestamp);
        }
        if (terms.unitPrice == 0) revert ZeroAmount();
        approval.status = ApprovalStatus.CONSUMED;
        offerId = bytes32(++_nextOfferId);
        _subscriptionOffers[offerId] = SubscriptionOffer({
            issuer: msg.sender,
            bondToken: terms.bondToken,
            settlementToken: terms.settlementToken,
            unitPrice: terms.unitPrice,
            maxUnits: terms.maxUnits,
            soldUnits: 0,
            opensAt: terms.opensAt,
            closesAt: terms.closesAt,
            status: SubscriptionStatus.ACTIVE
        });
        emit SubscriptionCreated(
            offerId,
            terms.bondToken,
            msg.sender,
            terms.settlementToken,
            terms.unitPrice,
            terms.maxUnits,
            terms.opensAt,
            terms.closesAt
        );
    }

    function closeSubscription(bytes32 offerId) external {
        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) revert SubscriptionNotActive(offerId);
        if (offer.issuer != msg.sender) revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        offer.status = SubscriptionStatus.CLOSED;
        emit SubscriptionClosed(offerId, offer.bondToken, offer.issuer);
    }

    function subscribe(bytes32 offerId, uint256 units) external nonReentrant {
        if (units == 0) revert ZeroAmount();
        _requireDomainActive(PauseDomain.SUBSCRIPTION);
        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) revert SubscriptionNotActive(offerId);
        if (block.timestamp < offer.opensAt || block.timestamp > offer.closesAt) {
            revert SubscriptionWindowClosed(offerId, block.timestamp);
        }
        _requireIssuanceTokenEnabled(offer.settlementToken);
        IBondToken bondToken = IBondToken(offer.bondToken);
        if (block.timestamp >= bondToken.maturityTimestamp()) {
            revert BondAlreadyMatured(offer.bondToken, bondToken.maturityTimestamp(), block.timestamp);
        }
        _requireMaker(IComplianceModule(bondToken.complianceModule()), msg.sender);
        uint256 remainingUnits = offer.maxUnits - offer.soldUnits;
        if (units > remainingUnits) revert SubscriptionCapExceeded(offerId, units, remainingUnits);
        uint256 cost = _quoteSubscriptionCost(units, offer.unitPrice, IERC20Metadata(offer.bondToken).decimals());
        offer.soldUnits += units;
        if (offer.soldUnits == offer.maxUnits) offer.status = SubscriptionStatus.CLOSED;
        IERC20(offer.settlementToken).safeTransferFrom(msg.sender, bondToken.issuer(), cost);
        bondToken.mint(msg.sender, units);
        emit Subscribed(offerId, offer.bondToken, msg.sender, offer.settlementToken, units, cost);
    }

    function setSettlementTokenPolicy(address token, bool enabledForIssuance, bool enabledForRedemption)
        external
        onlyRole(SETTLEMENT_ADMIN_ROLE)
    {
        // AUDIT-FIX(N18): use the inherited helper for consistent zero-address validation.
        _ensureNonZero(token);
        // AUDIT-FIX(N11): forbid disabling redemption while there is still outstanding liability for
        //                 the token. Otherwise admin policy changes could trap issuer-deposited
        //                 redemption funds and prevent rightful holders from claiming.
        SettlementTokenPolicy memory previousPolicy = _settlementTokenPolicies[token];
        if (
            previousPolicy.redemptionEnabled && !enabledForRedemption
                && _totalRedemptionLiability[token] > 0
        ) {
            revert SettlementTokenHasRedemptionLiability(token, _totalRedemptionLiability[token]);
        }
        _settlementTokenPolicies[token] =
            SettlementTokenPolicy({ issuanceEnabled: enabledForIssuance, redemptionEnabled: enabledForRedemption });
        emit SettlementTokenPolicyUpdated(token, enabledForIssuance, enabledForRedemption, msg.sender);
    }

    function depositRedemption(address bondTokenAddress, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireDomainActive(PauseDomain.REDEMPTION_FUNDING);
        IBondToken bondToken = IBondToken(bondTokenAddress);
        _requireIssuerIdentity(bondToken, msg.sender);
        _requireRedemptionTokenEnabled(bondToken.settlementToken());
        address settlementToken = bondToken.settlementToken();
        uint256 balanceBefore = IERC20(settlementToken).balanceOf(address(this));
        IERC20(settlementToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(settlementToken).balanceOf(address(this)) - balanceBefore;
        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        state.fundedAmount += received;
        state.lastFundingAt = block.timestamp;
        _totalRedemptionLiability[settlementToken] += received;
        emit RedemptionDeposited(bondTokenAddress, msg.sender, settlementToken, received, state.fundedAmount);
    }

    function claim(address bondTokenAddress) external nonReentrant {
        _claimFor(bondTokenAddress, msg.sender, msg.sender);
    }

    function claimFor(address bondTokenAddress, address holder) external nonReentrant {
        _claimFor(bondTokenAddress, holder, msg.sender);
    }

    function setClaimDelegate(address delegate) external {
        _claimDelegates[msg.sender] = delegate;
        emit ClaimDelegateSet(msg.sender, delegate, msg.sender);
    }

    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    function getSubscription(bytes32 offerId)
        external
        view
        returns (
            address bondToken,
            address settlementToken,
            uint256 unitPrice,
            uint256 maxUnits,
            uint256 soldUnits,
            uint256 opensAt,
            uint256 closesAt,
            uint8 status
        )
    {
        SubscriptionOffer memory offer = _subscriptionOffers[offerId];
        SubscriptionStatus effectiveStatus = offer.status;
        if (effectiveStatus == SubscriptionStatus.ACTIVE && offer.closesAt != 0 && block.timestamp > offer.closesAt) {
            effectiveStatus = SubscriptionStatus.CLOSED;
        }
        return (
            offer.bondToken,
            offer.settlementToken,
            offer.unitPrice,
            offer.maxUnits,
            offer.soldUnits,
            offer.opensAt,
            offer.closesAt,
            uint8(effectiveStatus)
        );
    }

    function getClaimDelegate(address holder) external view returns (address) { return _claimDelegates[holder]; }

    function getRedemptionState(address bondToken)
        external
        view
        returns (uint256 fundedAmount, uint256 claimedAmount, uint256 lastFundingAt)
    {
        RedemptionState memory state = _redemptionStates[bondToken];
        return (state.fundedAmount, state.claimedAmount, state.lastFundingAt);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // AUDIT-FIX(N18): use RoleManaged._ensureNonZero for consistent zero-address checks.
        _ensureNonZero(token);
        _ensureNonZero(to);
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked = _totalRedemptionLiability[token];
        uint256 rescuable = balance > locked ? balance - locked : 0;
        if (amount > rescuable) revert InsufficientRescuableBalance(token, rescuable, amount);
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount, msg.sender);
    }

    /// @notice Release any redemption funds in excess of the outstanding obligation back to the issuer.
    /// @dev AUDIT-FIX(N6): perform an actual safeTransfer so excess capital reaches the issuer
    ///      atomically instead of being parked as protocol "rescuable" balance awaiting a multisig.
    /// @dev AUDIT-FIX(N7,N13): obligation now flows through bondToken.principalOf + accruedInterestFor.
    function releaseExcessRedemption(address bondTokenAddress) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        IBondToken bondToken = IBondToken(bondTokenAddress);
        if (block.timestamp <= bondToken.maturityTimestamp()) {
            revert BondNotMatured(bondTokenAddress, bondToken.maturityTimestamp(), block.timestamp);
        }
        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        uint256 deposited = state.fundedAmount - state.claimedAmount;
        if (deposited == 0) return;
        uint256 outstanding = IERC20(bondTokenAddress).totalSupply();
        uint256 actualObligation;
        if (outstanding > 0) {
            actualObligation = _quoteRedemptionPayout(bondToken, outstanding);
        }
        if (deposited > actualObligation) {
            uint256 excess = deposited - actualObligation;
            _refundExcessToIssuer(bondToken, state, excess);
        }
    }

    function getSubscriptionApproval(bytes32 approvalId)
        external
        view
        returns (address issuer, address bondToken, uint256 maxUnits, uint256 expiresAt, ApprovalStatus status)
    {
        SubscriptionApprovalRecord memory record = _subscriptionApprovals[approvalId];
        return (record.issuer, record.bondToken, record.maxUnits, record.expiresAt, record.status);
    }

    function isDomainPaused(PauseDomain domain) public view override(DomainPausable, IBondIssuance) returns (bool) {
        return super.isDomainPaused(domain);
    }

    function isSettlementTokenEnabled(address token) public view returns (bool) {
        SettlementTokenPolicy memory policy = _settlementTokenPolicies[token];
        return policy.issuanceEnabled || policy.redemptionEnabled;
    }

    function getSettlementTokenPolicy(address token)
        external
        view
        returns (bool issuanceEnabled, bool redemptionEnabled)
    {
        SettlementTokenPolicy memory policy = _settlementTokenPolicies[token];
        return (policy.issuanceEnabled, policy.redemptionEnabled);
    }

    function _quoteSubscriptionCost(uint256 units, uint256 unitPrice, uint8 bondDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(unitPrice, units, 10 ** uint256(bondDecimals), Math.Rounding.Ceil);
    }

    /// @dev AUDIT-FIX(N7,N13): defer the division to BondToken helpers so that principal/accrual are
    ///      computed in settlement smallest units uniformly. The legacy lossy `accruedInterestPerUnit`
    ///      was removed in v0.3.0; all callers now go through `principalOf` + `accruedInterestFor`.
    function _quoteRedemptionPayout(IBondToken bondToken, uint256 bondAmount) internal view returns (uint256) {
        return bondToken.principalOf(bondAmount) + bondToken.accruedInterestFor(bondAmount, bondToken.maturityTimestamp());
    }

    function _requireIssuanceTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].issuanceEnabled) revert UnsupportedSettlementToken(token);
    }

    function _requireRedemptionTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].redemptionEnabled) revert UnsupportedSettlementToken(token);
    }

    function _requireIssuer(IBondToken bondToken, address account) internal view {
        IComplianceModule complianceModule = IComplianceModule(bondToken.complianceModule());
        if (!complianceModule.isWhitelisted(account)) revert NotWhitelisted(account);
        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.ISSUER || bondToken.issuer() != account) {
            revert InvalidParticipantRole(account, Role.ISSUER, actualRole);
        }
    }

    function _requireMaker(IComplianceModule complianceModule, address account) internal view {
        if (!complianceModule.isWhitelisted(account)) revert NotWhitelisted(account);
        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.MARKET_MAKER) revert InvalidParticipantRole(account, Role.MARKET_MAKER, actualRole);
    }

    function _claimFor(address bondTokenAddress, address holder, address caller) internal {
        _requireDomainActive(PauseDomain.CLAIMS);
        if (caller != holder && caller != _claimDelegates[holder]) {
            revert UnauthorizedClaimCaller(caller, holder, _claimDelegates[holder]);
        }
        IBondToken bondToken = IBondToken(bondTokenAddress);
        if (block.timestamp <= bondToken.maturityTimestamp()) {
            revert BondNotMatured(bondTokenAddress, bondToken.maturityTimestamp(), block.timestamp);
        }
        if (!IComplianceModule(bondToken.complianceModule()).isWhitelisted(holder)) revert NotWhitelisted(holder);
        _requireRedemptionTokenEnabled(bondToken.settlementToken());
        uint256 bondAmount = IERC20(bondTokenAddress).balanceOf(holder);
        if (bondAmount < 1) revert NoClaimableBalance(holder, bondTokenAddress);
        uint256 payout = _quoteRedemptionPayout(bondToken, bondAmount);
        // AUDIT-FIX(N9): allow payout==0 (dust positions) to proceed so the bond tokens can be burned
        //                and totalSupply can ultimately reach 0; only the safeTransfer / funding check
        //                are skipped for the zero-payout path.
        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        if (payout > 0) {
            uint256 availableAmount = state.fundedAmount - state.claimedAmount;
            if (availableAmount < payout) {
                revert InsufficientRedemptionFunding(bondTokenAddress, availableAmount, payout);
            }
            state.claimedAmount += payout;
            _totalRedemptionLiability[bondToken.settlementToken()] -= payout;
        }
        bondToken.burn(holder, bondAmount);
        if (payout > 0) {
            IERC20(bondToken.settlementToken()).safeTransfer(holder, payout);
        }
        emit RedemptionClaimed(bondTokenAddress, holder, caller, bondAmount, payout);
        _autoReleaseExcessIfFullyRedeemed(bondToken, state);
    }

    /// @notice Force-redeem a sanctioned/blacklisted holder's full position to a designated recipient.
    /// @dev AUDIT-FIX(N5): admins can break the deadlock caused by post-issuance compliance actions
    ///      that would otherwise permanently freeze the holder's bonds and the corresponding
    ///      redemption funds. The whitelist check is intentionally bypassed; the recipient is meant
    ///      to be a regulatory custody wallet or the issuer themselves.
    function forceRedeem(address bondTokenAddress, address holder, address recipient)
        external
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireDomainActive(PauseDomain.CLAIMS);
        _ensureNonZero(bondTokenAddress);
        _ensureNonZero(holder);
        _ensureNonZero(recipient);
        IBondToken bondToken = IBondToken(bondTokenAddress);
        if (block.timestamp <= bondToken.maturityTimestamp()) {
            revert BondNotMatured(bondTokenAddress, bondToken.maturityTimestamp(), block.timestamp);
        }
        _requireRedemptionTokenEnabled(bondToken.settlementToken());
        uint256 bondAmount = IERC20(bondTokenAddress).balanceOf(holder);
        if (bondAmount < 1) revert NoClaimableBalance(holder, bondTokenAddress);
        uint256 payout = _quoteRedemptionPayout(bondToken, bondAmount);
        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        if (payout > 0) {
            uint256 availableAmount = state.fundedAmount - state.claimedAmount;
            if (availableAmount < payout) {
                revert InsufficientRedemptionFunding(bondTokenAddress, availableAmount, payout);
            }
            state.claimedAmount += payout;
            _totalRedemptionLiability[bondToken.settlementToken()] -= payout;
        }
        bondToken.burn(holder, bondAmount);
        if (payout > 0) {
            IERC20(bondToken.settlementToken()).safeTransfer(recipient, payout);
        }
        emit ForceRedemption(bondTokenAddress, holder, recipient, bondAmount, payout, msg.sender);
        _autoReleaseExcessIfFullyRedeemed(bondToken, state);
    }

    /// @dev AUDIT-FIX(N6): when the bond reaches totalSupply==0 after a claim/force-redeem, atomically
    ///      transfer any over-funded remainder back to the issuer. Centralised here so _claimFor and
    ///      forceRedeem stay in sync and cannot drift.
    function _autoReleaseExcessIfFullyRedeemed(IBondToken bondToken, RedemptionState storage state) internal {
        if (IERC20(address(bondToken)).totalSupply() != 0) return;
        uint256 excess = state.fundedAmount - state.claimedAmount;
        if (excess == 0) return;
        _refundExcessToIssuer(bondToken, state, excess);
    }

    /// @dev AUDIT-FIX(N6): perform the actual safeTransfer of excess funds back to the issuer and
    ///      keep accounting in lock-step with the asset move.
    function _refundExcessToIssuer(IBondToken bondToken, RedemptionState storage state, uint256 excess) internal {
        address settlement = bondToken.settlementToken();
        address issuerAddress = bondToken.issuer();
        _totalRedemptionLiability[settlement] -= excess;
        state.fundedAmount -= excess;
        emit ExcessRedemptionReleased(address(bondToken), settlement, excess);
        IERC20(settlement).safeTransfer(issuerAddress, excess);
        emit ExcessRedemptionRefunded(address(bondToken), settlement, issuerAddress, excess);
    }

    function _requireIssuerIdentity(IBondToken bondToken, address account) internal view {
        if (bondToken.issuer() != account) revert InvalidParticipantRole(account, Role.ISSUER, Role.NONE);
    }

    function _requireValidWindow(uint256 opensAt, uint256 closesAt) internal view {
        if (closesAt == 0) revert SubscriptionWindowMissingCloseTime();
        if (closesAt <= opensAt) revert InvalidSubscriptionWindow(opensAt, closesAt);
        if (closesAt <= block.timestamp) revert SubscriptionWindowAlreadyClosed(closesAt, block.timestamp);
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) { }
}
