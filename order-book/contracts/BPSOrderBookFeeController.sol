// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MINIMUM_FEE_CONTROLLER_DELAY, MAXIMUM_FEE_CONTROLLER_DELAY} from "./FeeControllerDelayBounds.sol";
import {FeeQuote} from "./interfaces/FeeQuote.sol";
import {FeeRole} from "./interfaces/FeeRole.sol";
import {IBPSOrderBookFeeController} from "./interfaces/IBPSOrderBookFeeController.sol";
import {IFeeControllerTimelock} from "./interfaces/IFeeControllerTimelock.sol";
import {Side} from "./interfaces/Side.sol";
import {TakerFeeToken} from "./interfaces/TakerFeeToken.sol";

/// @notice BPS fee controller whose configuration changes are governed by an on-chain timelock.
/// @dev Maker fees are always charged in the maker's proceeds token. Taker fees use the configured base or quote token.
contract BPSOrderBookFeeController is IBPSOrderBookFeeController, TimelockController {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint16 public override makerFeeBps;
    uint16 public override takerFeeBps;
    uint16 public immutable override maximumMakerFeeBps;
    uint16 public immutable override maximumTakerFeeBps;
    TakerFeeToken public override takerFeeToken;
    address public override feeRecipient;

    mapping(address account => mapping(FeeRole feeRole => uint16 storedFeeBps)) private _feeBpsOverrides;

    error ZeroAddress();
    error ZeroMinimumDelay();
    error MinimumDelayOutOfBounds(uint256 delay, uint256 minimumDelay, uint256 maximumDelay);
    error MinimumDelayImmutable();
    error OnlyTimelock(address caller);
    error InvalidFeeConfiguration(uint16 makerFeeBps, uint16 takerFeeBps);
    error InvalidFeeBpsOverride(uint16 feeBps);

    event FeeBpsUpdated(
        uint16 previousMakerFeeBps, uint16 newMakerFeeBps, uint16 previousTakerFeeBps, uint16 newTakerFeeBps
    );
    event FeeBpsOverrideUpdated(address indexed account, FeeRole indexed feeRole, uint16 feeBps);
    event FeeBpsOverrideCleared(address indexed account, FeeRole indexed feeRole);
    event TakerFeeTokenUpdated(TakerFeeToken previousToken, TakerFeeToken newToken);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);

    constructor(
        uint16 initialMakerFeeBps,
        uint16 initialTakerFeeBps,
        uint16 maximumMakerFeeBps_,
        uint16 maximumTakerFeeBps_,
        TakerFeeToken initialTakerFeeToken,
        address initialFeeRecipient,
        uint256 minimumDelay,
        address proposer
    ) TimelockController(minimumDelay, _singleton(proposer), _singleton(address(0)), address(0)) {
        if (proposer == address(0) || initialFeeRecipient == address(0) || initialFeeRecipient == address(this)) {
            revert ZeroAddress();
        }
        if (minimumDelay == 0) revert ZeroMinimumDelay();
        if (minimumDelay < MINIMUM_FEE_CONTROLLER_DELAY || minimumDelay > MAXIMUM_FEE_CONTROLLER_DELAY) {
            revert MinimumDelayOutOfBounds(minimumDelay, MINIMUM_FEE_CONTROLLER_DELAY, MAXIMUM_FEE_CONTROLLER_DELAY);
        }
        if (maximumMakerFeeBps_ >= BPS_DENOMINATOR || maximumTakerFeeBps_ >= BPS_DENOMINATOR) {
            revert InvalidFeeConfiguration(maximumMakerFeeBps_, maximumTakerFeeBps_);
        }
        maximumMakerFeeBps = maximumMakerFeeBps_;
        maximumTakerFeeBps = maximumTakerFeeBps_;
        _setFeeBps(initialMakerFeeBps, initialTakerFeeBps);
        takerFeeToken = initialTakerFeeToken;
        feeRecipient = initialFeeRecipient;
    }

    modifier onlyTimelock() {
        if (msg.sender != address(this)) revert OnlyTimelock(msg.sender);
        _;
    }

    function getMinDelay() public view override(IFeeControllerTimelock, TimelockController) returns (uint256) {
        return super.getMinDelay();
    }

    function bpsDenominator() external pure override returns (uint256) {
        return BPS_DENOMINATOR;
    }

    /// @notice Updates the default fee rates through the timelock.
    function setFeeBps(uint16 newMakerFeeBps, uint16 newTakerFeeBps) external onlyTimelock {
        _setFeeBps(newMakerFeeBps, newTakerFeeBps);
    }

    /// @notice Sets an account-specific maker or taker rate through the timelock.
    /// @dev A zero rate is a valid fee exemption; the +1 storage encoding distinguishes it from no override.
    ///      Maker overrides apply to the maker. Taker overrides apply to either the paying taker or the taker's
    ///      settlement recipient according to the precedence documented on quoteOrderFee.
    function setFeeBpsOverride(address account, FeeRole feeRole, uint16 feeBps) external onlyTimelock {
        if (account == address(0)) revert ZeroAddress();
        uint16 maximumFeeBps = feeRole == FeeRole.MAKER ? maximumMakerFeeBps : maximumTakerFeeBps;
        if (feeBps > maximumFeeBps) revert InvalidFeeBpsOverride(feeBps);
        _feeBpsOverrides[account][feeRole] = feeBps + 1;
        emit FeeBpsOverrideUpdated(account, feeRole, feeBps);
    }

    /// @notice Clears an account-specific rate through the timelock.
    function clearFeeBpsOverride(address account, FeeRole feeRole) external onlyTimelock {
        if (account == address(0)) revert ZeroAddress();
        delete _feeBpsOverrides[account][feeRole];
        emit FeeBpsOverrideCleared(account, feeRole);
    }

    /// @notice Updates whether taker fees are charged in base or quote token through the timelock.
    function setTakerFeeToken(TakerFeeToken newTakerFeeToken) external onlyTimelock {
        TakerFeeToken previousToken = takerFeeToken;
        takerFeeToken = newTakerFeeToken;
        emit TakerFeeTokenUpdated(previousToken, newTakerFeeToken);
    }

    /// @notice Updates the fee recipient through the timelock.
    function setFeeRecipient(address newFeeRecipient) external onlyTimelock {
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert ZeroAddress();
        address previousRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(previousRecipient, newFeeRecipient);
    }

    function feeBpsOverrideOf(address account, FeeRole feeRole)
        external
        view
        override
        returns (bool isSet, uint16 feeBps)
    {
        uint16 storedFeeBps = _feeBpsOverrides[account][feeRole];
        return storedFeeBps == 0 ? (false, 0) : (true, storedFeeBps - 1);
    }

    function feeBpsFor(address account, FeeRole feeRole) public view override returns (uint16) {
        uint16 storedFeeBps = _feeBpsOverrides[account][feeRole];
        if (storedFeeBps != 0) return storedFeeBps - 1;
        return feeRole == FeeRole.MAKER ? makerFeeBps : takerFeeBps;
    }

    function feeBpsForOrder(address maker, address taker, address settlementRecipient, FeeRole feeRole)
        public
        view
        override
        returns (uint16)
    {
        if (feeRole == FeeRole.MAKER) return feeBpsFor(maker, feeRole);
        uint16 recipientOverride = _feeBpsOverrides[settlementRecipient][feeRole];
        if (settlementRecipient != address(0) && recipientOverride != 0) return recipientOverride - 1;
        return feeBpsFor(taker, feeRole);
    }

    /// @notice Quotes one basis-point fee using the maker, payer, and output-destination context.
    /// @dev Maker fees use the maker's override. Taker fees use an explicit settlementRecipient override first,
    ///      even when a different taker pays; otherwise they use the taker's override or the default taker rate.
    ///      A recipient discount is intentionally transferable only by sending that recipient the trade output.
    ///      Each quote independently rounds down to the fee token's smallest unit. Remainders are not carried across
    ///      partial fills, so the sum of fees for split fills can be lower than the fee for one aggregate fill.
    function quoteOrderFee(
        address maker,
        address taker,
        address settlementRecipient,
        Side side,
        FeeRole feeRole,
        address baseToken,
        uint256 baseTokenAmount,
        address quoteToken,
        uint256 quoteTokenAmount
    ) external view override returns (FeeQuote[] memory quotes) {
        if (baseToken == address(0) || quoteToken == address(0)) revert ZeroAddress();

        uint16 feeBps = feeBpsForOrder(maker, taker, settlementRecipient, feeRole);
        if (feeBps == 0) return new FeeQuote[](0);

        (address token, uint256 amount) =
            _feeTokenAndAmount(side, feeRole, baseToken, baseTokenAmount, quoteToken, quoteTokenAmount);
        quotes = new FeeQuote[](1);
        quotes[0] =
            FeeQuote({token: token, recipient: feeRecipient, amount: Math.mulDiv(amount, feeBps, BPS_DENOMINATOR)});
    }

    function _feeTokenAndAmount(
        Side side,
        FeeRole feeRole,
        address baseToken,
        uint256 baseTokenAmount,
        address quoteToken,
        uint256 quoteTokenAmount
    ) private view returns (address token, uint256 amount) {
        if (feeRole == FeeRole.MAKER) {
            return side == Side.SELL ? (quoteToken, quoteTokenAmount) : (baseToken, baseTokenAmount);
        }
        return takerFeeToken == TakerFeeToken.BASE ? (baseToken, baseTokenAmount) : (quoteToken, quoteTokenAmount);
    }

    function _setFeeBps(uint16 newMakerFeeBps, uint16 newTakerFeeBps) private {
        if (
            newMakerFeeBps > maximumMakerFeeBps || newTakerFeeBps > maximumTakerFeeBps
                || uint256(newMakerFeeBps) + newTakerFeeBps > BPS_DENOMINATOR
        ) {
            revert InvalidFeeConfiguration(newMakerFeeBps, newTakerFeeBps);
        }

        uint16 previousMakerFeeBps = makerFeeBps;
        uint16 previousTakerFeeBps = takerFeeBps;
        makerFeeBps = newMakerFeeBps;
        takerFeeBps = newTakerFeeBps;
        emit FeeBpsUpdated(previousMakerFeeBps, newMakerFeeBps, previousTakerFeeBps, newTakerFeeBps);
    }

    /// @notice Disables inherited timelock-delay updates.
    /// @dev Keeping the reviewed deployment delay immutable prevents later governance from shortening the reaction window.
    function updateDelay(uint256) public pure override {
        revert MinimumDelayImmutable();
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
