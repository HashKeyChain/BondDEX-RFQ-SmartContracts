// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DomainPausable} from "./abstracts/DomainPausable.sol";
import {RoleManaged} from "./abstracts/RoleManaged.sol";
import {
    BondNotMatured,
    InvalidParticipantRole,
    InsufficientRedemptionFunding,
    NoClaimableBalance,
    NotWhitelisted,
    SubscriptionCapExceeded,
    SubscriptionNotActive,
    SubscriptionWindowClosed,
    UnsupportedSettlementToken,
    UnauthorizedClaimCaller,
    ZeroAddress
} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondIssuance} from "./interfaces/IBondIssuance.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {PauseDomain, Role, SubscriptionStatus, SubscriptionTerms} from "./types/BondTypes.sol";

contract BondIssuance is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    DomainPausable,
    RoleManaged,
    IBondIssuance
{
    using SafeERC20 for IERC20;

    struct SettlementTokenPolicy {
        bool issuanceEnabled;
        bool settlementEnabled;
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

    struct RedemptionState {
        uint256 fundedAmount;
        uint256 claimedAmount;
        uint256 lastFundingAt;
    }

    event SettlementTokenPolicyUpdated(
        address indexed token,
        bool issuanceEnabled,
        bool settlementEnabled,
        bool redemptionEnabled,
        address operator
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
    event SubscriptionUpdated(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed issuer,
        address settlementToken,
        uint256 unitPrice,
        uint256 maxUnits,
        uint256 opensAt,
        uint256 closesAt
    );
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
        address indexed bondToken,
        address indexed holder,
        address indexed claimer,
        uint256 bondAmount,
        uint256 payout
    );
    event ClaimDelegateSet(address indexed holder, address indexed delegate, address operator);

    uint256 private _nextOfferId;
    uint256 private _reentrancyStatus;
    mapping(address token => SettlementTokenPolicy policy) private _settlementTokenPolicies;
    mapping(bytes32 offerId => SubscriptionOffer offer) private _subscriptionOffers;
    mapping(address holder => address delegate) private _claimDelegates;
    mapping(address bondToken => RedemptionState state) private _redemptionStates;
    uint256[43] private __gap;

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes admin, pauser, and upgrader roles for the issuance controller.
    function initialize(address admin) external initializer {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SETTLEMENT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _reentrancyStatus = 1;
    }

    /// @inheritdoc IBondIssuance
    function createSubscription(SubscriptionTerms calldata terms) external returns (bytes32 offerId) {
        _requireDomainActive(PauseDomain.SUBSCRIPTION);
        _requireIssuanceTokenEnabled(terms.settlementToken);

        IBondToken bondToken = IBondToken(terms.bondToken);
        if (bondToken.settlementToken() != terms.settlementToken) {
            revert UnsupportedSettlementToken(terms.settlementToken);
        }

        _requireIssuer(bondToken, msg.sender);

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

    /// @inheritdoc IBondIssuance
    function updateSubscription(bytes32 offerId, SubscriptionTerms calldata terms) external {
        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionNotActive(offerId);
        }

        if (offer.issuer != msg.sender) {
            revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        }

        offer.settlementToken = terms.settlementToken;
        offer.unitPrice = terms.unitPrice;
        offer.maxUnits = terms.maxUnits;
        offer.opensAt = terms.opensAt;
        offer.closesAt = terms.closesAt;

        emit SubscriptionUpdated(
            offerId,
            offer.bondToken,
            offer.issuer,
            offer.settlementToken,
            offer.unitPrice,
            offer.maxUnits,
            offer.opensAt,
            offer.closesAt
        );
    }

    /// @inheritdoc IBondIssuance
    function closeSubscription(bytes32 offerId) external {
        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.issuer != msg.sender) {
            revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        }

        offer.status = SubscriptionStatus.CLOSED;
    }

    /// @inheritdoc IBondIssuance
    function subscribe(bytes32 offerId, uint256 units) external nonReentrant {
        _requireDomainActive(PauseDomain.SUBSCRIPTION);

        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionNotActive(offerId);
        }

        if (block.timestamp < offer.opensAt || (offer.closesAt != 0 && block.timestamp > offer.closesAt)) {
            revert SubscriptionWindowClosed(offerId, block.timestamp);
        }

        _requireIssuanceTokenEnabled(offer.settlementToken);

        IBondToken bondToken = IBondToken(offer.bondToken);
        IComplianceModule complianceModule = IComplianceModule(bondToken.complianceModule());
        _requireMaker(complianceModule, msg.sender);

        uint256 remainingUnits = offer.maxUnits - offer.soldUnits;
        if (units > remainingUnits) {
            revert SubscriptionCapExceeded(offerId, units, remainingUnits);
        }

        uint8 bondDecimals = IERC20Metadata(offer.bondToken).decimals();
        uint256 cost = _quoteSubscriptionCost(units, offer.unitPrice, bondDecimals);

        offer.soldUnits += units;
        if (offer.soldUnits == offer.maxUnits) {
            offer.status = SubscriptionStatus.CLOSED;
        }

        IERC20(offer.settlementToken).safeTransferFrom(msg.sender, bondToken.issuer(), cost);
        bondToken.mint(msg.sender, units);

        emit Subscribed(offerId, offer.bondToken, msg.sender, offer.settlementToken, units, cost);
    }

    /// @inheritdoc IBondIssuance
    function setSettlementTokenPolicy(
        address token,
        bool enabledForIssuance,
        bool enabledForSettlement,
        bool enabledForRedemption
    ) external onlyRole(SETTLEMENT_ADMIN_ROLE) {
        if (token == address(0)) {
            revert ZeroAddress();
        }

        _settlementTokenPolicies[token] = SettlementTokenPolicy({
            issuanceEnabled: enabledForIssuance,
            settlementEnabled: enabledForSettlement,
            redemptionEnabled: enabledForRedemption
        });

        emit SettlementTokenPolicyUpdated(
            token, enabledForIssuance, enabledForSettlement, enabledForRedemption, msg.sender
        );
    }

    /// @inheritdoc IBondIssuance
    function depositRedemption(address bondTokenAddress, uint256 amount) external nonReentrant {
        _requireDomainActive(PauseDomain.REDEMPTION_FUNDING);

        IBondToken bondToken = IBondToken(bondTokenAddress);
        _requireIssuer(bondToken, msg.sender);
        _requireRedemptionTokenEnabled(bondToken.settlementToken());

        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        state.fundedAmount += amount;
        state.lastFundingAt = block.timestamp;

        IERC20(bondToken.settlementToken()).safeTransferFrom(msg.sender, address(this), amount);

        emit RedemptionDeposited(
            bondTokenAddress, msg.sender, bondToken.settlementToken(), amount, state.fundedAmount
        );
    }

    /// @inheritdoc IBondIssuance
    function claim(address bondTokenAddress) external nonReentrant {
        _claimFor(bondTokenAddress, msg.sender, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    function claimFor(address bondTokenAddress, address holder) external nonReentrant {
        _claimFor(bondTokenAddress, holder, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    function setClaimDelegate(address delegate) external {
        _claimDelegates[msg.sender] = delegate;
        emit ClaimDelegateSet(msg.sender, delegate, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    function pauseDomain(PauseDomain domain, bool paused) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IBondIssuance
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
        return (
            offer.bondToken,
            offer.settlementToken,
            offer.unitPrice,
            offer.maxUnits,
            offer.soldUnits,
            offer.opensAt,
            offer.closesAt,
            uint8(offer.status)
        );
    }

    /// @inheritdoc IBondIssuance
    function getClaimDelegate(address holder) external view returns (address) {
        return _claimDelegates[holder];
    }

    /// @inheritdoc IBondIssuance
    function getRedemptionState(address bondToken)
        external
        view
        returns (uint256 fundedAmount, uint256 claimedAmount, uint256 lastFundingAt)
    {
        RedemptionState memory state = _redemptionStates[bondToken];
        return (state.fundedAmount, state.claimedAmount, state.lastFundingAt);
    }

    /// @inheritdoc IBondIssuance
    function isDomainPaused(PauseDomain domain)
        public
        view
        override(DomainPausable, IBondIssuance)
        returns (bool)
    {
        return super.isDomainPaused(domain);
    }

    /// @inheritdoc IBondIssuance
    function isSettlementTokenEnabled(address token) public view returns (bool) {
        SettlementTokenPolicy memory policy = _settlementTokenPolicies[token];
        return policy.issuanceEnabled || policy.settlementEnabled || policy.redemptionEnabled;
    }

    /// @dev Shared quote-cost helper used by tests and the subscription flow.
    function _quoteSubscriptionCost(uint256 units, uint256 unitPrice, uint8 bondDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(unitPrice, units, 10 ** uint256(bondDecimals));
    }

    /// @dev Shared principal-plus-coupon payout helper for redemption claims.
    function _quoteRedemptionPayout(
        uint256 bondAmount,
        uint256 faceValue,
        uint256 couponRateBps,
        uint8 bondDecimals
    ) internal pure returns (uint256) {
        uint256 principal = Math.mulDiv(bondAmount, faceValue, 10 ** uint256(bondDecimals));
        uint256 interest = Math.mulDiv(principal, couponRateBps, 10_000);
        return principal + interest;
    }

    function _requireIssuanceTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].issuanceEnabled) {
            revert UnsupportedSettlementToken(token);
        }
    }

    function _requireRedemptionTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].redemptionEnabled) {
            revert UnsupportedSettlementToken(token);
        }
    }

    function _requireIssuer(IBondToken bondToken, address account) internal view {
        IComplianceModule complianceModule = IComplianceModule(bondToken.complianceModule());
        if (!complianceModule.isWhitelisted(account)) {
            revert NotWhitelisted(account);
        }

        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.ISSUER || bondToken.issuer() != account) {
            revert InvalidParticipantRole(account, Role.ISSUER, actualRole);
        }
    }

    function _requireMaker(IComplianceModule complianceModule, address account) internal view {
        if (!complianceModule.isWhitelisted(account)) {
            revert NotWhitelisted(account);
        }

        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.MARKET_MAKER) {
            revert InvalidParticipantRole(account, Role.MARKET_MAKER, actualRole);
        }
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

        _requireRedemptionTokenEnabled(bondToken.settlementToken());

        uint256 bondAmount = IERC20(bondTokenAddress).balanceOf(holder);
        if (bondAmount < 1) {
            revert NoClaimableBalance(holder, bondTokenAddress);
        }

        uint8 bondDecimals = IERC20Metadata(bondTokenAddress).decimals();
        uint256 payout =
            _quoteRedemptionPayout(bondAmount, bondToken.faceValue(), bondToken.couponRateBps(), bondDecimals);

        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        uint256 availableAmount = state.fundedAmount - state.claimedAmount;
        if (availableAmount < payout) {
            revert InsufficientRedemptionFunding(bondTokenAddress, availableAmount, payout);
        }

        state.claimedAmount += payout;
        bondToken.burn(holder, bondAmount);
        IERC20(bondToken.settlementToken()).safeTransfer(holder, payout);

        emit RedemptionClaimed(bondTokenAddress, holder, caller, bondAmount, payout);
    }

    /// @dev Restricts UUPS upgrades to the configured upgrader role.
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "REENTRANT_CALL");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }
}
