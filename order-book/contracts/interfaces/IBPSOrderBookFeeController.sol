// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeRole} from "./FeeRole.sol";
import {IGovernedOrderBookFeeController} from "./IGovernedOrderBookFeeController.sol";
import {TakerFeeToken} from "./TakerFeeToken.sol";

/// @notice Read interface for a governed order-book fee controller that prices fees in basis points.
/// @dev Clients can use feeBpsForOrder to display the live effective rate. quoteOrderFee remains authoritative
///      for the resulting fee token, recipient, and amount.
interface IBPSOrderBookFeeController is IGovernedOrderBookFeeController {
    /// @notice Denominator used to convert fee basis points into a fraction.
    function bpsDenominator() external view returns (uint256);

    /// @notice Default maker fee rate used when the maker has no override.
    function makerFeeBps() external view returns (uint16);

    /// @notice Default taker fee rate used when neither the taker nor settlement recipient has an override.
    function takerFeeBps() external view returns (uint16);

    /// @notice Token denomination used for taker fees.
    function takerFeeToken() external view returns (TakerFeeToken);

    /// @notice Account that receives collected fees.
    function feeRecipient() external view returns (address);

    /// @notice Returns an explicitly configured account rate, including a zero-fee exemption.
    function feeBpsOverrideOf(address account, FeeRole feeRole) external view returns (bool isSet, uint16 feeBps);

    /// @notice Returns an account's override when set, otherwise the default rate for the role.
    function feeBpsFor(address account, FeeRole feeRole) external view returns (uint16);

    /// @notice Returns the live effective rate for one maker or taker fee in an order settlement.
    /// @dev Maker fees use the maker's rate. Taker fees use the settlement recipient's override when set,
    ///      otherwise the taker's rate. A zero settlement recipient cannot supply an override.
    function feeBpsForOrder(address maker, address taker, address settlementRecipient, FeeRole feeRole)
        external
        view
        returns (uint16);
}
