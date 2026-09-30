// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice A fee amount and the account designated to receive it.
struct FeeQuote {
    address token;
    address recipient;
    uint256 amount;
}
