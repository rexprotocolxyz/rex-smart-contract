// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Declares immutable fee-rate ceilings for controllers used by an order book.
/// @dev Order books validate these ceilings against their own immutable fee caps before accepting a controller.
interface IFeeControllerFeeCaps {
    function maximumMakerFeeBps() external view returns (uint16);

    function maximumTakerFeeBps() external view returns (uint16);
}
