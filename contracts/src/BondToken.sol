// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {UnauthorizedController, TransferRestricted, ZeroAddress} from "./libraries/BondErrors.sol";
import {IComplianceModule} from "./interfaces/IComplianceModule.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";

contract BondToken is ERC20, IBondToken {
    address public immutable settlementToken;
    address public immutable complianceModule;
    address public immutable issuanceController;
    address public immutable issuer;
    uint256 public immutable faceValue;
    uint256 public immutable couponRateBps;
    uint256 public immutable maturityTimestamp;

    uint8 private immutable _tokenDecimals;

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
            issuer_ == address(0) || settlementToken_ == address(0) || complianceModule_ == address(0)
                || issuanceController_ == address(0)
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
    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    /// @inheritdoc IBondToken
    function mint(address to, uint256 amount) external {
        if (msg.sender != issuanceController) {
            revert UnauthorizedController(msg.sender);
        }

        _mint(to, amount);
    }

    /// @inheritdoc IBondToken
    function burn(address from, uint256 amount) external {
        if (msg.sender != issuanceController) {
            revert UnauthorizedController(msg.sender);
        }

        _burn(from, amount);
    }

    /// @inheritdoc IBondToken
    function detectTransferRestriction(address from, address to, uint256 amount)
        public
        view
        returns (uint8)
    {
        if (from == address(0) || to == address(0)) {
            return 0;
        }

        return IComplianceModule(complianceModule).checkTransfer(from, to, amount);
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
        return "UNKNOWN_RESTRICTION";
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint8 restrictionCode = detectTransferRestriction(from, to, amount);
        if (restrictionCode != 0) {
            revert TransferRestricted(restrictionCode);
        }

        super._update(from, to, amount);
    }
}
