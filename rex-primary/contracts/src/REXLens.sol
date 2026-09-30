// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IREXLens} from "@rex-shared/IREXLens.sol";
import {CLASS_RED_EPOCH} from "@rex-shared/Receipt.sol";
import {REXPrimary} from "./REXPrimary.sol";

/// @notice See `IREXLens`. No state, no owner (ADR-011: versioned by redeployment).
contract REXLens is IREXLens {
    function previewRedeem(address rex, uint256 wrwa) external view returns (uint256 usdcOut, uint256 fee) {
        REXPrimary r = REXPrimary(rex);
        uint256 nav = r.navOracle().nav();
        uint256 usdcScale = 10 ** IERC20Metadata(address(r.usdc())).decimals();
        uint256 wrwaScale = 10 ** IERC20Metadata(address(r.wrwaRoute())).decimals();
        uint256 gross = Math.mulDiv(wrwa * usdcScale, nav, 1e18 * wrwaScale);
        uint64 epoch = r.currentEpochId();
        (uint256 totalIn,,,,) = r.epochSide(epoch, CLASS_RED_EPOCH);
        uint16 bps = totalIn == 0 ? r.redemptionFeeBps() : r.redemptionFeeOf(epoch);
        fee = Math.mulDiv(gross, bps, 10_000);
        usdcOut = gross - fee;
    }

    function shutDownBlockers(address rex)
        external
        view
        returns (bool windowElapsed, uint64 outstandingSub, uint64 outstandingRedeem)
    {
        REXPrimary r = REXPrimary(rex);
        uint64 start = r.windDownStart();
        windowElapsed = start != 0 && block.timestamp >= start + r.windDownWindow();
        outstandingSub = r.outstandingSubBatches();
        outstandingRedeem = r.outstandingRedeemBatches();
    }
}
