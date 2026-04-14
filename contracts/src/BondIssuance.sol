// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {DomainPausable} from "./abstracts/DomainPausable.sol";
import {RoleManaged} from "./abstracts/RoleManaged.sol";
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
    SubscriptionApprovalNotActive,
    SubscriptionCapExceeded,
    SubscriptionNotActive,
    SubscriptionWindowClosed,
    SubscriptionWindowExceedsIssueDate,
    SubscriptionWindowMissingCloseTime,
    UnsupportedSettlementToken,
    UnauthorizedClaimCaller,
    ZeroAddress,
    ZeroAmount
} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondIssuance} from "./interfaces/IBondIssuance.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {
    ApprovalStatus,
    PauseDomain,
    Role,
    SubscriptionStatus,
    SubscriptionTerms
} from "./types/BondTypes.sol";

/// @title BondIssuance
/// @notice Primary-market and redemption controller for issued bond tokens.
/// @dev This contract manages subscription offers, settlement-token policy, redemption funding,
/// and direct or delegated claims after maturity. It is deployed behind a UUPS proxy.
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

    /// @dev Tracks which lifecycle phases are enabled for one settlement token.
    struct SettlementTokenPolicy {
        /// @dev True when the token may be used for subscriptions.
        bool issuanceEnabled;
        /// @dev True when the token may be used for secondary settlement.
        bool settlementEnabled;
        /// @dev True when the token may be used for redemption funding and payouts.
        bool redemptionEnabled;
    }

    /// @dev Stores the issuer-defined terms for one subscription window.
    struct SubscriptionOffer {
        /// @dev Issuer that owns the offer.
        address issuer;
        /// @dev Bond token offered in the subscription window.
        address bondToken;
        /// @dev Settlement token used to pay for subscribed bond units.
        address settlementToken;
        /// @dev Price per whole bond unit expressed in settlement-token smallest units.
        uint256 unitPrice;
        /// @dev Hard cap on total bond units sold through the offer.
        uint256 maxUnits;
        /// @dev Bond units already subscribed.
        uint256 soldUnits;
        /// @dev Opening timestamp for the offer.
        uint256 opensAt;
        /// @dev Closing timestamp for the offer; zero means no explicit end.
        uint256 closesAt;
        /// @dev Current status of the offer.
        SubscriptionStatus status;
    }

    /// @dev Stores governance-approved parameters for one subscription window.
    struct SubscriptionApprovalRecord {
        /// @dev Issuer address allowed to consume the approval.
        address issuer;
        /// @dev Bond token that the subscription must target.
        address bondToken;
        /// @dev Upper bound on bond units the issuer may offer.
        uint256 maxUnits;
        /// @dev Optional deadline after which the approval can no longer be used.
        uint256 expiresAt;
        /// @dev Current approval lifecycle status.
        ApprovalStatus status;
    }

    /// @dev Tracks cumulative redemption funding and payouts for one bond token.
    struct RedemptionState {
        /// @dev Total settlement tokens deposited by the issuer.
        uint256 fundedAmount;
        /// @dev Total settlement tokens already paid out to holders.
        uint256 claimedAmount;
        /// @dev Timestamp of the latest funding event.
        uint256 lastFundingAt;
    }

    /// @notice Emitted when governance updates lifecycle permissions for a settlement token.
    event SettlementTokenPolicyUpdated(
        address indexed token,
        bool issuanceEnabled,
        bool settlementEnabled,
        bool redemptionEnabled,
        address operator
    );

    /// @notice Emitted when an issuer opens a new subscription offer.
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

    /// @notice Emitted when governance approves one subscription window.
    event SubscriptionApproved(
        bytes32 indexed approvalId,
        address indexed issuer,
        address indexed bondToken,
        address approver,
        uint256 maxUnits,
        uint256 expiresAt
    );

    /// @notice Emitted when governance revokes an active subscription approval.
    event SubscriptionApprovalRevoked(
        bytes32 indexed approvalId,
        address indexed issuer,
        address approver
    );

    /// @notice Emitted when an active subscription approval is marked as expired.
    event SubscriptionApprovalExpired(
        bytes32 indexed approvalId,
        address indexed issuer,
        address operator
    );

    /// @notice Emitted when a market maker successfully subscribes for bond units.
    event Subscribed(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed subscriber,
        address settlementToken,
        uint256 units,
        uint256 cost
    );

    /// @notice Emitted when an issuer deposits redemption funds for a matured bond.
    event RedemptionDeposited(
        address indexed bondToken,
        address indexed issuer,
        address indexed settlementToken,
        uint256 amount,
        uint256 cumulativeFundedAmount
    );

    /// @notice Emitted when a holder claim burns bond units and releases payout.
    event RedemptionClaimed(
        address indexed bondToken,
        address indexed holder,
        address indexed claimer,
        uint256 bondAmount,
        uint256 payout
    );

    /// @notice Emitted when an issuer closes an active subscription offer.
    event SubscriptionClosed(
        bytes32 indexed offerId,
        address indexed bondToken,
        address indexed issuer
    );

    /// @notice Emitted when the admin rescues tokens accidentally sent to this contract.
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount,
        address indexed operator
    );

    /// @notice Emitted when excess redemption liability is released for a bond series.
    event ExcessRedemptionReleased(
        address indexed bondToken,
        address indexed settlementToken,
        uint256 excessAmount
    );

    /// @notice Emitted when a holder sets or clears a claim delegate.
    event ClaimDelegateSet(
        address indexed holder,
        address indexed delegate,
        address operator
    );

    /// @dev Monotonic counter used to derive subscription offer identifiers.
    uint256 private _nextOfferId;

    /// @dev Lifecycle permissions keyed by settlement-token address.
    mapping(address token => SettlementTokenPolicy policy)
        private _settlementTokenPolicies;

    /// @dev Subscription offers keyed by their offer identifier.
    mapping(bytes32 offerId => SubscriptionOffer offer)
        private _subscriptionOffers;

    /// @dev Subscription approval records keyed by approval identifier.
    mapping(bytes32 approvalId => SubscriptionApprovalRecord record)
        private _subscriptionApprovals;

    /// @dev Optional claim delegate keyed by holder address.
    mapping(address holder => address delegate) private _claimDelegates;

    /// @dev Redemption accounting keyed by bond-token address.
    mapping(address bondToken => RedemptionState state)
        private _redemptionStates;

    /// @dev Aggregated redemption liability keyed by settlement-token address.
    mapping(address token => uint256 liability)
        private _totalRedemptionLiability;

    /// @dev Reserved storage gap for future upgrades.
    uint256[43] private __gap;

    /// @dev Locks the implementation contract and forces use through a proxy.
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
        _grantRole(ISSUANCE_APPROVER_ROLE, admin);
        _grantRole(SETTLEMENT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Records one subscription approval that can later be consumed exactly once.
    function approveSubscription(
        bytes32 approvalId,
        address issuer,
        address bondToken,
        uint256 maxUnits,
        uint256 expiresAt
    ) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        if (issuer == address(0) || bondToken == address(0)) {
            revert ZeroAddress();
        }
        if (maxUnits == 0) revert ZeroAmount();
        if (expiresAt != 0 && expiresAt <= block.timestamp) {
            revert ExpiredDeadline(expiresAt, block.timestamp);
        }

        ApprovalStatus currentStatus = _subscriptionApprovals[approvalId]
            .status;
        if (currentStatus != ApprovalStatus.NONE) {
            revert SubscriptionApprovalNotActive(approvalId, currentStatus);
        }

        _subscriptionApprovals[approvalId] = SubscriptionApprovalRecord({
            issuer: issuer,
            bondToken: bondToken,
            maxUnits: maxUnits,
            expiresAt: expiresAt,
            status: ApprovalStatus.ACTIVE
        });

        emit SubscriptionApproved(
            approvalId,
            issuer,
            bondToken,
            msg.sender,
            maxUnits,
            expiresAt
        );
    }

    /// @inheritdoc IBondIssuance
    /// @dev Marks one subscription approval as revoked so the issuer cannot consume it.
    function revokeSubscriptionApproval(
        bytes32 approvalId
    ) external onlyRole(ISSUANCE_APPROVER_ROLE) {
        SubscriptionApprovalRecord storage record = _subscriptionApprovals[
            approvalId
        ];
        if (record.status != ApprovalStatus.ACTIVE) {
            revert SubscriptionApprovalNotActive(approvalId, record.status);
        }
        record.status = ApprovalStatus.REVOKED;
        emit SubscriptionApprovalRevoked(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Persists EXPIRED status for an active subscription approval whose deadline has passed.
    function markSubscriptionExpired(bytes32 approvalId) external {
        SubscriptionApprovalRecord storage record = _subscriptionApprovals[
            approvalId
        ];
        if (record.status != ApprovalStatus.ACTIVE) {
            revert SubscriptionApprovalNotActive(approvalId, record.status);
        }
        if (record.expiresAt == 0 || record.expiresAt >= block.timestamp) {
            revert SubscriptionApprovalNotActive(approvalId, record.status);
        }
        record.status = ApprovalStatus.EXPIRED;
        emit SubscriptionApprovalExpired(approvalId, record.issuer, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Consumes one subscription approval and creates an issuer-owned subscription window.
    function createSubscription(
        SubscriptionTerms calldata terms,
        bytes32 approvalId
    ) external returns (bytes32 offerId) {
        _requireDomainActive(PauseDomain.SUBSCRIPTION);
        _requireIssuanceTokenEnabled(terms.settlementToken);

        SubscriptionApprovalRecord storage approval = _subscriptionApprovals[
            approvalId
        ];
        if (approval.status != ApprovalStatus.ACTIVE) {
            revert SubscriptionApprovalNotActive(approvalId, approval.status);
        }
        if (approval.expiresAt != 0 && approval.expiresAt < block.timestamp) {
            revert SubscriptionApprovalNotActive(
                approvalId,
                ApprovalStatus.EXPIRED
            );
        }
        if (approval.issuer != msg.sender) {
            revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        }
        if (approval.bondToken != terms.bondToken) {
            revert SubscriptionApprovalNotActive(approvalId, approval.status);
        }
        if (terms.maxUnits > approval.maxUnits) {
            revert MaxUnitsExceedsApproval(
                approvalId,
                terms.maxUnits,
                approval.maxUnits
            );
        }

        IBondToken bondToken = IBondToken(terms.bondToken);
        if (bondToken.settlementToken() != terms.settlementToken) {
            revert UnsupportedSettlementToken(terms.settlementToken);
        }

        _requireIssuer(bondToken, msg.sender);
        _requireValidWindow(terms.opensAt, terms.closesAt);

        uint256 bondIssueDate = bondToken.issueDate();
        if (terms.closesAt > bondIssueDate) {
            revert SubscriptionWindowExceedsIssueDate(
                terms.closesAt,
                bondIssueDate
            );
        }

        if (block.timestamp >= bondToken.maturityTimestamp()) {
            revert BondAlreadyMatured(
                terms.bondToken,
                bondToken.maturityTimestamp(),
                block.timestamp
            );
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

    /// @inheritdoc IBondIssuance
    /// @dev Closes one subscription so no further bond units can be sold through it.
    function closeSubscription(bytes32 offerId) external {
        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionNotActive(offerId);
        }
        if (offer.issuer != msg.sender) {
            revert InvalidParticipantRole(msg.sender, Role.ISSUER, Role.NONE);
        }

        offer.status = SubscriptionStatus.CLOSED;
        emit SubscriptionClosed(offerId, offer.bondToken, offer.issuer);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Pulls settlement tokens from a market maker, forwards them to the issuer, and mints bonds.
    /// Primary-market subscriptions carry no accrued interest — the subscription price (unitPrice)
    /// is a flat amount per bond. Interest accrual begins at the bond's issueDate, which is
    /// typically set after the subscription window closes, ensuring all subscribers pay the same
    /// price regardless of when they subscribed within the window.
    function subscribe(bytes32 offerId, uint256 units) external nonReentrant {
        if (units == 0) revert ZeroAmount();
        _requireDomainActive(PauseDomain.SUBSCRIPTION);

        SubscriptionOffer storage offer = _subscriptionOffers[offerId];
        if (offer.status != SubscriptionStatus.ACTIVE) {
            revert SubscriptionNotActive(offerId);
        }

        if (
            block.timestamp < offer.opensAt || block.timestamp > offer.closesAt
        ) {
            revert SubscriptionWindowClosed(offerId, block.timestamp);
        }

        _requireIssuanceTokenEnabled(offer.settlementToken);

        IBondToken bondToken = IBondToken(offer.bondToken);
        if (block.timestamp >= bondToken.maturityTimestamp()) {
            revert BondAlreadyMatured(
                offer.bondToken,
                bondToken.maturityTimestamp(),
                block.timestamp
            );
        }
        IComplianceModule complianceModule = IComplianceModule(
            bondToken.complianceModule()
        );
        _requireMaker(complianceModule, msg.sender);

        uint256 remainingUnits = offer.maxUnits - offer.soldUnits;
        if (units > remainingUnits) {
            revert SubscriptionCapExceeded(offerId, units, remainingUnits);
        }

        uint8 bondDecimals = IERC20Metadata(offer.bondToken).decimals();
        uint256 cost = _quoteSubscriptionCost(
            units,
            offer.unitPrice,
            bondDecimals
        );

        // Update sold units before any external token interaction.
        offer.soldUnits += units;
        if (offer.soldUnits == offer.maxUnits) {
            offer.status = SubscriptionStatus.CLOSED;
        }

        // Funds move directly to the issuer while newly issued bonds go to the subscriber.
        IERC20(offer.settlementToken).safeTransferFrom(
            msg.sender,
            bondToken.issuer(),
            cost
        );
        bondToken.mint(msg.sender, units);

        emit Subscribed(
            offerId,
            offer.bondToken,
            msg.sender,
            offer.settlementToken,
            units,
            cost
        );
    }

    /// @inheritdoc IBondIssuance
    /// @dev Updates the allowed lifecycle usage flags for one settlement token.
    /// NOTE: This contract assumes all settlement tokens are standard ERC-20 with exact transfer
    /// amounts (no fee-on-transfer, no rebasing). Fee-on-transfer tokens will cause redemption
    /// accounting to diverge from actual balances, leading to claim failures.
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
            token,
            enabledForIssuance,
            enabledForSettlement,
            enabledForRedemption,
            msg.sender
        );
    }

    /// @inheritdoc IBondIssuance
    /// @dev Pulls redemption funds from the issuer and records cumulative funding.
    /// Unlike subscription flows, redemption funding only requires the caller to be the
    /// bond's designated issuer — no whitelist check — so that compliance admin actions
    /// cannot block redemption fund deposits and strand holder payouts.
    function depositRedemption(
        address bondTokenAddress,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireDomainActive(PauseDomain.REDEMPTION_FUNDING);

        IBondToken bondToken = IBondToken(bondTokenAddress);
        _requireIssuerIdentity(bondToken, msg.sender);
        _requireRedemptionTokenEnabled(bondToken.settlementToken());

        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        state.fundedAmount += amount;
        state.lastFundingAt = block.timestamp;
        _totalRedemptionLiability[bondToken.settlementToken()] += amount;

        IERC20(bondToken.settlementToken()).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        emit RedemptionDeposited(
            bondTokenAddress,
            msg.sender,
            bondToken.settlementToken(),
            amount,
            state.fundedAmount
        );
    }

    /// @inheritdoc IBondIssuance
    /// @dev Claims matured redemption for the caller and pays the caller directly.
    function claim(address bondTokenAddress) external nonReentrant {
        _claimFor(bondTokenAddress, msg.sender, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Claims matured redemption on behalf of one holder while always paying the holder.
    function claimFor(
        address bondTokenAddress,
        address holder
    ) external nonReentrant {
        _claimFor(bondTokenAddress, holder, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Sets or clears the delegate allowed to trigger claims for the caller.
    function setClaimDelegate(address delegate) external {
        _claimDelegates[msg.sender] = delegate;
        emit ClaimDelegateSet(msg.sender, delegate, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Toggles one issuance-controlled pause domain.
    function pauseDomain(
        PauseDomain domain,
        bool paused
    ) external onlyRole(PAUSER_ROLE) {
        _setDomainPaused(domain, paused);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Returns the stored subscription terms and current fill status for one offer.
    function getSubscription(
        bytes32 offerId
    )
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
    /// @dev Returns the configured delegate that may trigger claims for one holder.
    function getClaimDelegate(address holder) external view returns (address) {
        return _claimDelegates[holder];
    }

    /// @inheritdoc IBondIssuance
    /// @dev Returns cumulative redemption funding and payout state for one bond token.
    function getRedemptionState(
        address bondToken
    )
        external
        view
        returns (
            uint256 fundedAmount,
            uint256 claimedAmount,
            uint256 lastFundingAt
        )
    {
        RedemptionState memory state = _redemptionStates[bondToken];
        return (state.fundedAmount, state.claimedAmount, state.lastFundingAt);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Allows the admin to recover tokens accidentally sent to this contract.
    /// The function protects all outstanding redemption liabilities for the given token
    /// across every bond series, preventing admin from withdrawing funds owed to holders.
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) {
            revert ZeroAddress();
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 locked = _totalRedemptionLiability[token];
        uint256 rescuable = balance > locked ? balance - locked : 0;
        if (amount > rescuable) {
            revert InsufficientRescuableBalance(token, rescuable, amount);
        }

        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount, msg.sender);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Releases provably excess redemption liability for one bond series.
    /// Only callable after maturity. Computes actual obligation based on outstanding
    /// bond supply and reduces the liability accordingly, making the excess rescuable.
    function releaseExcessRedemption(
        address bondTokenAddress
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        IBondToken bondToken = IBondToken(bondTokenAddress);
        if (block.timestamp <= bondToken.maturityTimestamp()) {
            revert BondNotMatured(
                bondTokenAddress,
                bondToken.maturityTimestamp(),
                block.timestamp
            );
        }

        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        uint256 deposited = state.fundedAmount - state.claimedAmount;
        if (deposited == 0) return;

        uint256 outstanding = IERC20(bondTokenAddress).totalSupply();
        uint256 actualObligation;
        if (outstanding > 0) {
            uint8 bondDecimals = IERC20Metadata(bondTokenAddress).decimals();
            actualObligation = _quoteRedemptionPayout(
                bondToken,
                outstanding,
                bondDecimals
            );
        }

        if (deposited > actualObligation) {
            uint256 excess = deposited - actualObligation;
            _totalRedemptionLiability[bondToken.settlementToken()] -= excess;
            state.fundedAmount -= excess;
            emit ExcessRedemptionReleased(
                bondTokenAddress,
                bondToken.settlementToken(),
                excess
            );
        }
    }

    /// @inheritdoc IBondIssuance
    /// @dev Returns the stored subscription approval record.
    function getSubscriptionApproval(
        bytes32 approvalId
    )
        external
        view
        returns (
            address issuer,
            address bondToken,
            uint256 maxUnits,
            uint256 expiresAt,
            ApprovalStatus status
        )
    {
        SubscriptionApprovalRecord memory record = _subscriptionApprovals[
            approvalId
        ];
        return (
            record.issuer,
            record.bondToken,
            record.maxUnits,
            record.expiresAt,
            record.status
        );
    }

    /// @inheritdoc IBondIssuance
    /// @dev Exposes the inherited pause state for off-chain monitoring and interface compliance.
    function isDomainPaused(
        PauseDomain domain
    ) public view override(DomainPausable, IBondIssuance) returns (bool) {
        return super.isDomainPaused(domain);
    }

    /// @inheritdoc IBondIssuance
    /// @dev Returns true when the token is enabled for at least one lifecycle phase.
    function isSettlementTokenEnabled(
        address token
    ) public view returns (bool) {
        SettlementTokenPolicy memory policy = _settlementTokenPolicies[token];
        return
            policy.issuanceEnabled ||
            policy.settlementEnabled ||
            policy.redemptionEnabled;
    }

    /// @dev Shared quote-cost helper used by tests and the subscription flow.
    /// Rounds up to protect the protocol from systematic under-payment.
    function _quoteSubscriptionCost(
        uint256 units,
        uint256 unitPrice,
        uint8 bondDecimals
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(
                unitPrice,
                units,
                10 ** uint256(bondDecimals),
                Math.Rounding.Ceil
            );
    }

    /// @dev Computes principal plus full-term accrued interest using BondToken's AI view.
    function _quoteRedemptionPayout(
        IBondToken bondToken,
        uint256 bondAmount,
        uint8 bondDecimals
    ) internal view returns (uint256) {
        uint256 principal = Math.mulDiv(
            bondAmount,
            bondToken.faceValue(),
            10 ** uint256(bondDecimals)
        );
        uint256 aiPerUnit = bondToken.accruedInterestPerUnit(
            bondToken.maturityTimestamp()
        );
        uint256 interest = Math.mulDiv(
            aiPerUnit,
            bondAmount,
            10 ** uint256(bondDecimals)
        );
        return principal + interest;
    }

    /// @dev Reverts when a token is not enabled for subscription creation and fills.
    function _requireIssuanceTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].issuanceEnabled) {
            revert UnsupportedSettlementToken(token);
        }
    }

    /// @dev Reverts when a token is not enabled for redemption funding and payout.
    function _requireRedemptionTokenEnabled(address token) internal view {
        if (!_settlementTokenPolicies[token].redemptionEnabled) {
            revert UnsupportedSettlementToken(token);
        }
    }

    /// @dev Reverts unless the account is both whitelisted and registered as the bond issuer.
    function _requireIssuer(
        IBondToken bondToken,
        address account
    ) internal view {
        IComplianceModule complianceModule = IComplianceModule(
            bondToken.complianceModule()
        );
        if (!complianceModule.isWhitelisted(account)) {
            revert NotWhitelisted(account);
        }

        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.ISSUER || bondToken.issuer() != account) {
            revert InvalidParticipantRole(account, Role.ISSUER, actualRole);
        }
    }

    /// @dev Reverts unless the account is whitelisted and registered as a market maker.
    function _requireMaker(
        IComplianceModule complianceModule,
        address account
    ) internal view {
        if (!complianceModule.isWhitelisted(account)) {
            revert NotWhitelisted(account);
        }

        Role actualRole = complianceModule.roleOf(account);
        if (actualRole != Role.MARKET_MAKER) {
            revert InvalidParticipantRole(
                account,
                Role.MARKET_MAKER,
                actualRole
            );
        }
    }

    /// @dev Shared redemption path used by direct and delegated claims.
    function _claimFor(
        address bondTokenAddress,
        address holder,
        address caller
    ) internal {
        _requireDomainActive(PauseDomain.CLAIMS);

        if (caller != holder && caller != _claimDelegates[holder]) {
            revert UnauthorizedClaimCaller(
                caller,
                holder,
                _claimDelegates[holder]
            );
        }

        IBondToken bondToken = IBondToken(bondTokenAddress);
        if (block.timestamp <= bondToken.maturityTimestamp()) {
            revert BondNotMatured(
                bondTokenAddress,
                bondToken.maturityTimestamp(),
                block.timestamp
            );
        }

        _requireRedemptionTokenEnabled(bondToken.settlementToken());

        uint256 bondAmount = IERC20(bondTokenAddress).balanceOf(holder);
        if (bondAmount < 1) {
            revert NoClaimableBalance(holder, bondTokenAddress);
        }

        uint8 bondDecimals = IERC20Metadata(bondTokenAddress).decimals();
        uint256 payout = _quoteRedemptionPayout(
            bondToken,
            bondAmount,
            bondDecimals
        );
        if (payout == 0) revert ZeroAmount();

        RedemptionState storage state = _redemptionStates[bondTokenAddress];
        uint256 availableAmount = state.fundedAmount - state.claimedAmount;
        if (availableAmount < payout) {
            revert InsufficientRedemptionFunding(
                bondTokenAddress,
                availableAmount,
                payout
            );
        }

        // Burn first, then transfer payout so the holder cannot re-use the same bond balance.
        state.claimedAmount += payout;
        _totalRedemptionLiability[bondToken.settlementToken()] -= payout;
        bondToken.burn(holder, bondAmount);
        IERC20(bondToken.settlementToken()).safeTransfer(holder, payout);

        emit RedemptionClaimed(
            bondTokenAddress,
            holder,
            caller,
            bondAmount,
            payout
        );

        // After all bonds are burned, automatically release the excess redemption liability for this bond series.
        if (IERC20(bondTokenAddress).totalSupply() == 0) {
            uint256 excess = state.fundedAmount - state.claimedAmount;
            if (excess > 0) {
                _totalRedemptionLiability[
                    bondToken.settlementToken()
                ] -= excess;
                state.fundedAmount = state.claimedAmount;
                emit ExcessRedemptionReleased(
                    bondTokenAddress,
                    bondToken.settlementToken(),
                    excess
                );
            }
        }
    }

    /// @dev Reverts unless the caller is the bond's designated issuer.
    /// Unlike _requireIssuer, this helper does NOT check whitelist or compliance role,
    /// so that redemption funding cannot be blocked by compliance admin actions.
    function _requireIssuerIdentity(
        IBondToken bondToken,
        address account
    ) internal view {
        if (bondToken.issuer() != account) {
            revert InvalidParticipantRole(account, Role.ISSUER, Role.NONE);
        }
    }

    /// @dev Reverts when closesAt is zero or closesAt is not strictly after opensAt.
    function _requireValidWindow(
        uint256 opensAt,
        uint256 closesAt
    ) internal pure {
        if (closesAt == 0) {
            revert SubscriptionWindowMissingCloseTime();
        }
        if (closesAt <= opensAt) {
            revert InvalidSubscriptionWindow(opensAt, closesAt);
        }
    }

    /// @dev Restricts UUPS upgrades to the configured upgrader role.
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(UPGRADER_ROLE) {}
}
