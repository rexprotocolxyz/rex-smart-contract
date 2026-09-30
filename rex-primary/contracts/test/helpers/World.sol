// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../../src/REXPrimary.sol";
import "../../src/PruvExecutor.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/INavOracle.sol";
import "../mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {MockRWAConversion} from "../mocks/MockRWAConversion.sol";
import {perSecondSchedule} from "./TestSchedule.sol";

/// @notice SC13 §1.3 -- both chains on one mocked mailbox, parameterised by a `Config` so a value-path
/// suite runs at NAV != 1, with Pruv fees, and with an 18-decimal home stablecoin. `_relay` plays the
/// Hyperlane relayer: it reads a dispatched instruction, delivers the paired tokens in the
/// destination's local units, then processes the message.
abstract contract World is Test {
    struct Config {
        uint256 nav;
        uint8 feeKind;
        uint256 feeValue;
        uint8 homeUsdcDecimals;
        uint8 homeWrwaDecimals;
    }

    uint32 internal constant PRUV_DOMAIN = 7336;
    uint256 internal constant SUB_FULFILL = 1 hours;
    uint256 internal constant REDEEM_FULFILL = 10 days;
    /// @dev The live value (config-values.md): a percentage fee never trips it (F-A3).
    uint256 internal constant EXEC_SLIPPAGE_BPS = 5000;

    MockMailbox internal mailbox;
    MockERC20 internal usdc;
    MockCollateralWarpRoute internal usdcRoute;
    MockSyntheticWarpRoute internal pusdcRoute;
    MockRWAToken internal vault;
    MockRWAConversion internal conversion;
    MockCollateralWarpRoute internal pruvWrwaRoute;
    MockSyntheticWarpRoute internal homeWrwaRoute;
    MockNavOracle internal navOracle;
    REXPrimary internal rex;
    PruvExecutor internal exec;
    address internal pruvFeeRecipient = makeAddr("pruvFeeRecipient");

    function _config() internal pure virtual returns (Config memory);

    receive() external payable {}

    function setUp() public virtual {
        Config memory c = _config();
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);

        usdc = new MockERC20("USDC", c.homeUsdcDecimals);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        pusdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        pusdcRoute.setGasQuote(0);

        conversion = new MockRWAConversion(c.nav);
        vault = new MockRWAToken(address(pusdcRoute));
        vault.setConversion(address(conversion));
        vault.setFeeRecipient(pruvFeeRecipient);
        vault.setFee(true, c.feeKind, c.feeValue);
        vault.setFee(false, c.feeKind, c.feeValue);
        pruvWrwaRoute = new MockCollateralWarpRoute(IERC20(address(vault)));
        pruvWrwaRoute.setGasQuote(0);
        homeWrwaRoute = new MockSyntheticWarpRoute("wRWA", c.homeWrwaDecimals);
        homeWrwaRoute.setGasQuote(0);

        navOracle = new MockNavOracle(c.nav);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(homeWrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 11 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        exec = _deployExecutor();
        rex.enrollRemote(PRUV_DOMAIN, _b32(address(exec)));
        exec.enrollRemote(PRUV_DOMAIN, _b32(address(rex)));
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad(); // vacuous close (minimum 0) -> EpochBased, no batch
    }

    /// @dev The one place the executor is constructed, so a constructor change edits one line here.
    function _deployExecutor() internal virtual returns (PruvExecutor) {
        return new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL,
            EXEC_SLIPPAGE_BPS,
            REDEEM_FULFILL,
            conversion,
            0,
            0
        );
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _usd(uint256 whole) internal view returns (uint256) {
        return whole * 10 ** usdc.decimals();
    }

    function _wrwa(uint256 whole) internal view returns (uint256) {
        return whole * 10 ** homeWrwaRoute.decimals();
    }

    function _pusd(uint256 whole) internal pure returns (uint256) {
        return whole * 1e6;
    }

    function _usdUnit() internal view returns (uint256) {
        return 10 ** (usdc.decimals() - 6);
    }

    function _wrwaUnit() internal view returns (uint256) {
        return 10 ** (homeWrwaRoute.decimals() - 6);
    }

    function _subInstr(uint64 batchId) internal view returns (bytes32 id) {
        (, id,,) = rex.batchLeg(batchId, false);
    }

    function _redeemInstr(uint64 batchId) internal view returns (bytes32 id) {
        (, id,,) = rex.batchLeg(batchId, true);
    }

    /// @notice Deliver the tokens paired with instruction `id` in the destination's local units, then
    /// process the instruction. Returns the local amount delivered. Wire amounts are micro-units.
    function _relay(bytes32 id) internal returns (uint256 delivered) {
        (bytes32 recipient,,, bytes memory body,,) = mailbox.messageOf(id);
        Instruction memory instr = Codec.decode(body);
        address to = address(uint160(uint256(recipient)));
        if (to == address(exec)) {
            delivered = instr.amount; // PRUV USDC and shares are 6-decimal: one micro-unit is one unit
            if (instr.kind == RequestKind.Subscribe) {
                pusdcRoute.deliverTokens(recipient, delivered);
            } else {
                deal(address(vault), address(pruvWrwaRoute), vault.balanceOf(address(pruvWrwaRoute)) + delivered);
                pruvWrwaRoute.deliverTokens(recipient, delivered);
            }
        } else if (instr.kind == RequestKind.Subscribe || instr.kind == RequestKind.RedeemAborted) {
            delivered = instr.amount * _wrwaUnit();
            homeWrwaRoute.deliverTokens(recipient, delivered);
        } else {
            delivered = instr.amount * _usdUnit();
            uint256 held = usdc.balanceOf(address(usdcRoute));
            if (held < delivered) usdc.mint(address(usdcRoute), delivered - held);
            usdcRoute.deliverTokens(recipient, delivered);
        }
        mailbox.process(id);
    }

    /// @notice The issuer's off-chain sale: fund the vault with exactly what redeeming `shares` pays out
    /// in total (receiver plus Pruv's fee).
    function _fundVaultFor(uint256 shares) internal {
        pusdcRoute.deliverTokens(_b32(address(vault)), vault.convertToAssets(shares));
    }

    function _subscribe(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function _requestRedeem(address who, uint256 amount) internal returns (uint256 id) {
        homeWrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(homeWrwaRoute)).approve(address(rex), amount);
        id = rex.requestRedeem(amount);
        vm.stopPrank();
    }
}

abstract contract DefaultConfig is World {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1e18, feeKind: 0, feeValue: 0, homeUsdcDecimals: 6, homeWrwaDecimals: 6});
    }
}

abstract contract NavDriftConfig is World {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1.0512e18, feeKind: 0, feeValue: 0, homeUsdcDecimals: 6, homeWrwaDecimals: 6});
    }
}

abstract contract PercentFeeConfig is World {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1.0512e18, feeKind: 1, feeValue: 0.005e18, homeUsdcDecimals: 6, homeWrwaDecimals: 6});
    }
}

/// @dev Fixed fee 1 USDC; every e2e batch is >= 100 USDC, far above 2F (F-A3's safe zone).
abstract contract FixedFeeConfig is World {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1.0512e18, feeKind: 2, feeValue: 1e6, homeUsdcDecimals: 6, homeWrwaDecimals: 6});
    }
}

abstract contract Decimals18Config is World {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1.0512e18, feeKind: 1, feeValue: 0.005e18, homeUsdcDecimals: 18, homeWrwaDecimals: 6});
    }
}
