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
contract BondToken is ERC20, IBondToken {
    address public immutable settlementToken;
    address public immutable complianceModule;
    address public immutable issuanceController;
    address public immutable issuer;
    uint256 public immutable faceValue;
    uint256 public immutable couponRateBps;
    uint256 public immutable maturityTimestamp;
    /// @notice Interest accrual start date, typically set after the subscription window closes.
    uint256 public immutable issueDate;
    DayCount public immutable dayCountConvention;
    CouponFrequency public immutable couponFrequency;
    BondCategory public immutable bondCategory;
    bytes12 public immutable isin;
    uint8 private immutable _tokenDecimals;

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

    constructor(ConstructorParams memory params_) ERC20(params_.name, params_.symbol) {
        if (
            params_.issuer == address(0) || params_.settlementToken == address(0)
                || params_.complianceModule == address(0) || params_.issuanceController == address(0)
        ) {
            revert ZeroAddress();
        }
        if (params_.faceValue == 0) revert InvalidBondConfig("faceValue must be > 0");
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
            revert InvalidIssueDate(params_.issueDate, params_.maturityTimestamp);
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
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @inheritdoc IBondToken
    /// @dev Returns 0 before issueDate; caps at maturityTimestamp.
    function accruedInterestPerUnit(uint256 timestamp) external view returns (uint256) {
        if (timestamp <= issueDate) return 0;
        uint256 effectiveTs = timestamp < maturityTimestamp ? timestamp : maturityTimestamp;
        uint256 elapsedSeconds = effectiveTs - issueDate;
        uint256 yearSeconds = dayCountConvention == DayCount.ACT_365 ? 365 days : 360 days;
        return Math.mulDiv(faceValue, couponRateBps * elapsedSeconds, 10_000 * yearSeconds);
    }

    /// @inheritdoc IBondToken
    function mint(address to, uint256 amount) external {
        if (msg.sender != issuanceController) revert UnauthorizedController(msg.sender);
        _mint(to, amount);
    }

    /// @inheritdoc IBondToken
    function burn(address from, uint256 amount) external {
        if (msg.sender != issuanceController) revert UnauthorizedController(msg.sender);
        _burn(from, amount);
    }

    /// @inheritdoc IBondToken
    /// @dev Mint/burn (from/to == address(0)) bypass compliance checks.
    function detectTransferRestriction(address from, address to, uint256 amount) public view returns (uint8) {
        if (from == address(0) || to == address(0)) return 0;
        return IComplianceModule(complianceModule).checkTransfer(from, to, amount, msg.sender);
    }

    /// @dev Off-chain overload: pass the intended operator to preview transfer eligibility.
    function detectTransferRestriction(address from, address to, uint256 amount, address operator)
        public
        view
        returns (uint8)
    {
        if (from == address(0) || to == address(0)) return 0;
        return IComplianceModule(complianceModule).checkTransfer(from, to, amount, operator);
    }

    /// @inheritdoc IBondToken
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
