// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    UnauthorizedController,
    TransferRestricted,
    ZeroAddress
} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";

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

    /// @notice Coupon rate expressed in basis points.
    uint256 public immutable couponRateBps;

    /// @notice Unix timestamp after which redemption claims become available.
    uint256 public immutable maturityTimestamp;

    /// @dev Cached decimals value so each bond series can expose custom precision.
    uint8 private immutable _tokenDecimals;

    /// @param issuer_ Issuer address recorded for the bond series.
    /// @param name_ ERC-20 token name.
    /// @param symbol_ ERC-20 token symbol.
    /// @param decimals_ Token decimals used for bond accounting.
    /// @param faceValue_ Face value per whole bond unit.
    /// @param couponRateBps_ Coupon rate in basis points.
    /// @param maturityTimestamp_ Redemption maturity timestamp.
    /// @param settlementToken_ Settlement token used by the lifecycle flows.
    /// @param complianceModule_ Bound compliance module for transfer checks.
    /// @param issuanceController_ Issuance controller allowed to mint and burn.
    constructor(
        address issuer_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 faceValue_,
        uint256 couponRateBps_,
        uint256 maturityTimestamp_,
        address settlementToken_,
        address complianceModule_,
        address issuanceController_
    ) ERC20(name_, symbol_) {
        if (
            issuer_ == address(0) ||
            settlementToken_ == address(0) ||
            complianceModule_ == address(0) ||
            issuanceController_ == address(0)
        ) {
            revert ZeroAddress();
        }

        issuer = issuer_;
        settlementToken = settlementToken_;
        complianceModule = complianceModule_;
        issuanceController = issuanceController_;
        faceValue = faceValue_;
        couponRateBps = couponRateBps_;
        maturityTimestamp = maturityTimestamp_;
        _tokenDecimals = decimals_;
    }

    /// @inheritdoc ERC20
    /// @dev Returns the immutable decimals configured for this bond series.
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
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
