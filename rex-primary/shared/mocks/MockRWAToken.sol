// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockValueSource {
    function value() external view returns (uint256);
}

/// @notice Pruv vault test double. Defaults (no conversion, no fees, 6-decimal shares) reproduce the
/// pre-SC13 mock exactly, so existing suites are unchanged. The knobs reproduce the verified vault
/// source and the fork measurements in `docs/reviews/2026-09-15-money-path-research/track-a-findings.md`
/// §1.4: `convertToAssets` floors; a percentage fee is `amount * v / (v + 1e18)` rounded up on the
/// total; a fixed fee is flat per call; a redeem pays out exactly `convertToAssets(shares)`, split
/// between the receiver and the fee recipient.
contract MockRWAToken is ERC20 {
    using SafeERC20 for IERC20;

    uint8 public constant FEE_NONE = 0;
    uint8 public constant FEE_PERCENT = 1;
    uint8 public constant FEE_FIXED = 2;

    struct Fee {
        uint8 kind;
        uint256 value;
    }

    error DepositRejected();
    error WithdrawalsBlocked();
    error FeePercentageTooHigh();
    error FeeRecipientZero();

    address public immutable assetToken;
    uint8 private _shareDecimals = 6;
    /// @dev `value()` source; zero means a fixed 1e18.
    address public conversion;
    Fee public entryFee;
    Fee public exitFee;
    address public feeRecipient;
    /// @dev Models a vault that refuses the deposit (revoked credential, paused vault, cap reached).
    bool public rejectDeposits;
    /// @dev Models the executor losing its withdrawal rights (the 2026-09-15 whitelist incident).
    bool public withdrawalsBlocked;
    /// @dev Receiver payout in bps of the net amount (1e4 = exact). Below 1e4 models the vault paying
    /// less than the oracle says, which is what the executor's slippage floor exists to catch.
    uint256 public redeemRateBps = 1e4;

    constructor(address a) ERC20("wRWA", "wRWA") {
        assetToken = a;
    }

    function decimals() public view override returns (uint8) {
        return _shareDecimals;
    }

    function setShareDecimals(uint8 d) external {
        _shareDecimals = d;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function setConversion(address c) external {
        conversion = c;
    }

    function setFee(bool entry, uint8 kind, uint256 value) external {
        if (kind == FEE_PERCENT && value > 1e18) revert FeePercentageTooHigh();
        if (entry) entryFee = Fee(kind, value);
        else exitFee = Fee(kind, value);
    }

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setRejectDeposits(bool on) external {
        rejectDeposits = on;
    }

    function setWithdrawalsBlocked(bool on) external {
        withdrawalsBlocked = on;
    }

    function setRedeemRateBps(uint256 bps) external {
        redeemRateBps = bps;
    }

    function adminBurn(address owner, uint256 amount) external {
        _burn(owner, amount);
    }

    function _nav() internal view returns (uint256) {
        return conversion == address(0) ? 1e18 : IMockValueSource(conversion).value();
    }

    function _assetScale() internal view returns (uint256) {
        return 10 ** IERC20Metadata(assetToken).decimals();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares * _assetScale(), _nav(), 1e18 * 10 ** decimals());
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets * 10 ** decimals(), 1e18, _nav() * _assetScale());
    }

    function _feeOnTotal(Fee memory f, uint256 amount) internal pure returns (uint256) {
        if (f.kind == FEE_FIXED) return f.value;
        if (f.kind == FEE_PERCENT) return Math.mulDiv(amount, f.value, f.value + 1e18, Math.Rounding.Ceil);
        return 0;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets - _feeOnTotal(entryFee, assets));
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 total = convertToAssets(shares);
        return total - _feeOnTotal(exitFee, total);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (rejectDeposits) revert DepositRejected();
        uint256 fee = _feeOnTotal(entryFee, assets);
        shares = convertToShares(assets - fee); // a fixed fee above `assets` underflows, as on chain
        IERC20(assetToken).safeTransferFrom(msg.sender, address(this), assets);
        _payFee(fee);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (withdrawalsBlocked) revert WithdrawalsBlocked();
        uint256 total = convertToAssets(shares);
        uint256 fee = _feeOnTotal(exitFee, total);
        uint256 net = total - fee; // a fixed fee above the batch's assets underflows, as on chain
        _burn(owner, shares);
        assets = net * redeemRateBps / 1e4;
        IERC20(assetToken).safeTransfer(receiver, assets);
        _payFee(fee);
    }

    function _payFee(uint256 fee) internal {
        if (fee == 0) return;
        if (feeRecipient == address(0)) revert FeeRecipientZero();
        IERC20(assetToken).safeTransfer(feeRecipient, fee);
    }
}
