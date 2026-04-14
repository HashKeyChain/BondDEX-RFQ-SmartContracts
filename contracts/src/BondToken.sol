// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    InvalidBondConfig,
    InvalidIssueDate,
    UnauthorizedController,
    TransferRestricted,
    ZeroAddress
} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {BondCategory, CouponFrequency, DayCount} from "./types/BondTypes.sol";

/// @title BondToken
/// @notice ERC-20 bond instrument with immutable issuance terms and compliance-gated transfers.
/// @dev Minting and burning are restricted to the bound issuance controller. Transfer validation
/// is delegated to the per-bond compliance module so each bond series can enforce its own policy.
contract BondToken is ERC20, IBondToken {
    /// @notice Settlement token used for subscription, settlement, and redemption flows.
    address public immutable settlementToken;

    /// @notice Per-bond compliance module that evaluates transfer restrictions.
    address public immutable complianceModule;

    /// @notice Issuance controller allowed to mint and burn bond units.
    address public immutable issuanceController;

    /// @notice Issuer address embedded into the bond definition.
    address public immutable issuer;

    /// @notice Face value per whole bond unit denominated in settlement-token units.
    uint256 public immutable faceValue;

    /// @notice Annual coupon rate expressed in basis points.
    uint256 public immutable couponRateBps;

    /// @notice Unix timestamp after which redemption claims become available.
    uint256 public immutable maturityTimestamp;

    /// @notice Predetermined interest accrual start date, shared by all holders.
    /// Typically set after the subscription window closes. No interest accrues before this date;
    /// secondary-market buyers compensate sellers for accrued interest since this date.
    uint256 public immutable issueDate;

    /// @notice Day count convention used for accrued interest calculation.
    DayCount public immutable dayCountConvention;

    /// @notice Coupon payment frequency.
    CouponFrequency public immutable couponFrequency;

    /// @notice Bond category classification.
    BondCategory public immutable bondCategory;

    /// @notice International Securities Identification Number (ISO 6166).
    bytes12 public immutable isin;

    /// @dev Cached decimals value so each bond series can expose custom precision.
    uint8 private immutable _tokenDecimals;

    /// @param params_ Packed constructor parameters to avoid stack-too-deep.
    struct ConstructorParams {
        address issuer;
        string name;
        string symbol;
        uint8 decimals;
        uint256 faceValue;
        uint256 couponRateBps;
        uint256 maturityTimestamp;
        address settlementToken;
        address complianceModule;
        address issuanceController;
        uint256 issueDate;
        DayCount dayCountConvention;
        CouponFrequency couponFrequency;
        BondCategory bondCategory;
        bytes12 isin;
    }

    constructor(
        ConstructorParams memory params_
    ) ERC20(params_.name, params_.symbol) {
        if (
            params_.issuer == address(0) ||
            params_.settlementToken == address(0) ||
            params_.complianceModule == address(0) ||
            params_.issuanceController == address(0)
        ) {
            revert ZeroAddress();
        }

        if (params_.faceValue == 0) {
            revert InvalidBondConfig("faceValue must be > 0");
        }
        if (params_.couponRateBps > 10_000) {
            revert InvalidBondConfig("couponRateBps must be <= 10000");
        }
        if (params_.maturityTimestamp <= block.timestamp) {
            revert InvalidBondConfig("maturityTimestamp must be in the future");
        }
        if (params_.issueDate < block.timestamp) {
            revert InvalidBondConfig("issueDate must not be in the past");
        }
        if (params_.issueDate >= params_.maturityTimestamp) {
            revert InvalidIssueDate(
                params_.issueDate,
                params_.maturityTimestamp
            );
        }

        issuer = params_.issuer;
        settlementToken = params_.settlementToken;
        complianceModule = params_.complianceModule;
        issuanceController = params_.issuanceController;
        faceValue = params_.faceValue;
        couponRateBps = params_.couponRateBps;
        maturityTimestamp = params_.maturityTimestamp;
        issueDate = params_.issueDate;
        dayCountConvention = params_.dayCountConvention;
        couponFrequency = params_.couponFrequency;
        bondCategory = params_.bondCategory;
        isin = params_.isin;
        _tokenDecimals = params_.decimals;
    }

    /// @inheritdoc ERC20
    /// @dev Returns the immutable decimals configured for this bond series.
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @inheritdoc IBondToken
    /// @dev Computes accrued interest per whole bond unit using the configured day count convention.
    /// Returns 0 before issueDate (no interest accrues during subscription window).
    /// Caps at maturityTimestamp so the full-term interest equals the redemption coupon.
    function accruedInterestPerUnit(
        uint256 timestamp
    ) external view returns (uint256) {
        if (timestamp <= issueDate) return 0;
        uint256 effectiveTs = timestamp < maturityTimestamp
            ? timestamp
            : maturityTimestamp;

        uint256 elapsedSeconds = effectiveTs - issueDate;
        uint256 yearSeconds = dayCountConvention == DayCount.ACT_365
            ? 365 days
            : 360 days;
        return
            Math.mulDiv(
                faceValue,
                couponRateBps * elapsedSeconds,
                10_000 * yearSeconds
            );
    }

    /// @inheritdoc IBondToken
    /// @dev Mints bond units during the primary issuance flow.
    function mint(address to, uint256 amount) external {
        if (msg.sender != issuanceController) {
            revert UnauthorizedController(msg.sender);
        }

        _mint(to, amount);
    }

    /// @inheritdoc IBondToken
    /// @dev Burns bond units during redemption so payout can only be claimed once.
    function burn(address from, uint256 amount) external {
        if (msg.sender != issuanceController) {
            revert UnauthorizedController(msg.sender);
        }

        _burn(from, amount);
    }

    /// @inheritdoc IBondToken
    /// @dev Returns zero for mint and burn flows so issuance-controller operations can proceed,
    /// while all user-to-user transfers are delegated to the compliance module.
    function detectTransferRestriction(
        address from,
        address to,
        uint256 amount
    ) public view returns (uint8) {
        if (from == address(0) || to == address(0)) {
            return 0;
        }

        return
            IComplianceModule(complianceModule).checkTransfer(from, to, amount);
    }

    /// @inheritdoc IBondToken
    /// @dev Converts numeric restriction codes into stable human-readable messages for off-chain UIs.
    function messageForTransferRestriction(
        uint8 restrictionCode
    ) external pure returns (string memory) {
        if (restrictionCode == 0) return "SUCCESS";
        if (restrictionCode == 1) return "BOND_TOKEN_NOT_BOUND";
        if (restrictionCode == 2) return "SENDER_NOT_WHITELISTED";
        if (restrictionCode == 3) return "RECEIVER_NOT_WHITELISTED";
        if (restrictionCode == 4) return "INVALID_SENDER_ROLE";
        if (restrictionCode == 5) return "INVALID_RECEIVER_ROLE";
        if (restrictionCode == 6) return "INVALID_DIRECTION";
        if (restrictionCode == 7) return "TRANSFERS_PAUSED";
        return "UNKNOWN_RESTRICTION";
    }

    /// @dev Evaluates the compliance policy before every token state update.
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        uint8 restrictionCode = detectTransferRestriction(from, to, amount);
        if (restrictionCode != 0) {
            revert TransferRestricted(restrictionCode);
        }

        super._update(from, to, amount);
    }
}
