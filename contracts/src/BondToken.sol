// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    InvalidBondConfig, InvalidIssueDate, UnauthorizedController, TransferRestricted, ZeroAddress
} from "./libraries/BondErrors.sol";
import { IComplianceModule } from "./interfaces/IComplianceModule.sol";
import { IBondToken } from "./interfaces/IBondToken.sol";
import { BondCategory, CouponFrequency, DayCount } from "./types/BondTypes.sol";

/// @title BondToken
/// @notice ERC20 representation of a single bond series with accrual and compliance hooks.
/// @dev Decimal model:
///        - bondAmount is denominated in 10^decimals() bond units;
///        - faceValue is denominated in settlementToken smallest units;
///        - principalOf / accruedInterestFor return values in settlementToken smallest units.
///      AUDIT-FIX(N13): settlementTokenDecimals is captured immutably and verified against the
///      live ERC20 metadata at construction; downstream pricing uses principalOf / accruedInterestFor
///      so callers no longer mix bondDecimals with quote/settlement decimals manually. The
///      BondMath.scaleAmount helper remains available for future cross-decimal use cases.
contract BondToken is ERC20, IBondToken {
    address public immutable settlementToken;
    address public immutable complianceModule;
    address public immutable issuanceController;
    address public immutable issuer;
    uint256 public immutable faceValue;
    uint256 public immutable couponRateBps;
    uint256 public immutable maturityTimestamp;
    uint256 public immutable issueDate;
    DayCount public immutable dayCountConvention;
    CouponFrequency public immutable couponFrequency;
    BondCategory public immutable bondCategory;
    bytes12 public immutable isin;
    uint8 private immutable _tokenDecimals;
    // AUDIT-FIX(N13): settlement token decimals captured at construction and exposed via view.
    uint8 private immutable _settlementTokenDecimals;

    struct ConstructorParams {
        address issuer;
        string name;
        string symbol;
        uint8 decimals;
        uint256 faceValue;
        uint256 couponRateBps;
        uint256 maturityTimestamp;
        address settlementToken;
        // AUDIT-FIX(N13): explicit settlement decimals to be cross-checked against the ERC20 metadata.
        uint8 settlementTokenDecimals;
        address complianceModule;
        address issuanceController;
        uint256 issueDate;
        DayCount dayCountConvention;
        CouponFrequency couponFrequency;
        BondCategory bondCategory;
        bytes12 isin;
    }

    constructor(ConstructorParams memory params_) ERC20(params_.name, params_.symbol) {
        if (
            params_.issuer == address(0) || params_.settlementToken == address(0)
                || params_.complianceModule == address(0) || params_.issuanceController == address(0)
        ) revert ZeroAddress();
        if (params_.faceValue == 0) revert InvalidBondConfig("faceValue must be > 0");
        if (params_.couponRateBps > 10_000) revert InvalidBondConfig("couponRateBps must be <= 10000");
        if (params_.maturityTimestamp <= block.timestamp) {
            revert InvalidBondConfig("maturityTimestamp must be in the future");
        }
        if (params_.issueDate < block.timestamp) revert InvalidBondConfig("issueDate must not be in the past");
        if (params_.issueDate >= params_.maturityTimestamp) {
            revert InvalidIssueDate(params_.issueDate, params_.maturityTimestamp);
        }
        if (params_.decimals > 18) revert InvalidBondConfig("decimals must be <= 18");
        // AUDIT-FIX(N13): structurally validate settlement token decimals against the live ERC20 metadata.
        if (params_.settlementTokenDecimals > 18) revert InvalidBondConfig("settlementTokenDecimals must be <= 18");
        try IERC20Metadata(params_.settlementToken).decimals() returns (uint8 actualDecimals) {
            if (actualDecimals != params_.settlementTokenDecimals) {
                revert InvalidBondConfig("settlementTokenDecimals mismatch");
            }
        } catch {
            revert InvalidBondConfig("settlementToken decimals() unavailable");
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
        _settlementTokenDecimals = params_.settlementTokenDecimals;
    }

    function decimals() public view override returns (uint8) { return _tokenDecimals; }

    /// @inheritdoc IBondToken
    function settlementTokenDecimals() external view returns (uint8) { return _settlementTokenDecimals; }

    /// @inheritdoc IBondToken
    /// @dev AUDIT-FIX(N7): defer the division to preserve precision. Returns total accrued
    ///      interest in settlement token smallest units for the given bondAmount and timestamp.
    ///      Replaces the legacy lossy `accruedInterestPerUnit` (removed in v0.3.0). To get the
    ///      historical "per-unit" value pass `bondAmount = 10**decimals()`; the result is
    ///      mathematically equivalent and strictly higher precision.
    function accruedInterestFor(uint256 bondAmount, uint256 timestamp) external view returns (uint256) {
        if (bondAmount == 0 || timestamp <= issueDate) return 0;
        uint256 effectiveTs = timestamp < maturityTimestamp ? timestamp : maturityTimestamp;
        uint256 elapsedSeconds = effectiveTs - issueDate;
        uint256 yearSeconds = dayCountConvention == DayCount.ACT_365 ? 365 days : 360 days;
        // total = bondAmount * faceValue * couponRateBps * elapsed
        //       / (10_000 * yearSeconds * 10**bondDecimals)
        // Use Math.mulDiv to keep a 512-bit intermediate and avoid early truncation.
        uint256 numeratorB = couponRateBps * elapsedSeconds;
        uint256 denominator = (10_000 * yearSeconds) * (10 ** uint256(_tokenDecimals));
        return Math.mulDiv(bondAmount * faceValue, numeratorB, denominator);
    }

    /// @inheritdoc IBondToken
    /// @dev AUDIT-FIX(N13): centralizes principal computation in settlement token smallest units.
    function principalOf(uint256 bondAmount) external view returns (uint256) {
        if (bondAmount == 0) return 0;
        return Math.mulDiv(bondAmount, faceValue, 10 ** uint256(_tokenDecimals));
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != issuanceController) revert UnauthorizedController(msg.sender);
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != issuanceController) revert UnauthorizedController(msg.sender);
        _burn(from, amount);
    }

    function detectTransferRestriction(address from, address to, uint256 amount) public view returns (uint8) {
        if (from == address(0) || to == address(0)) return 0;
        return IComplianceModule(complianceModule).checkTransfer(from, to, amount, msg.sender);
    }

    function detectTransferRestriction(address from, address to, uint256 amount, address operator)
        public
        view
        returns (uint8)
    {
        if (from == address(0) || to == address(0)) return 0;
        return IComplianceModule(complianceModule).checkTransfer(from, to, amount, operator);
    }

    function messageForTransferRestriction(uint8 restrictionCode) external pure returns (string memory) {
        if (restrictionCode == 0) return "SUCCESS";
        if (restrictionCode == 1) return "BOND_TOKEN_NOT_BOUND";
        if (restrictionCode == 2) return "SENDER_NOT_WHITELISTED";
        if (restrictionCode == 3) return "RECEIVER_NOT_WHITELISTED";
        if (restrictionCode == 4) return "INVALID_SENDER_ROLE";
        if (restrictionCode == 5) return "INVALID_RECEIVER_ROLE";
        if (restrictionCode == 6) return "INVALID_DIRECTION";
        if (restrictionCode == 7) return "TRANSFERS_PAUSED";
        if (restrictionCode == 8) return "UNAUTHORIZED_OPERATOR";
        return "UNKNOWN_RESTRICTION";
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint8 restrictionCode = detectTransferRestriction(from, to, amount);
        if (restrictionCode != 0) revert TransferRestricted(restrictionCode);
        super._update(from, to, amount);
    }
}
