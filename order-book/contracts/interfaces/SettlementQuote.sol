// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Fee-aware settlement amounts from the taker's perspective.
/// @dev makerFeeAmount is denominated in inputToken and is deducted from the maker's gross proceeds.
struct SettlementQuote {
    /// @dev Token supplied by the taker and received as gross proceeds by the maker.
    address inputToken;
    /// @dev Principal supplied by the taker before any taker fee added to the input.
    uint256 grossInputAmount;
    /// @dev Taker fee added on top of grossInputAmount; zero when the taker fee uses outputToken.
    uint256 inputFeeAmount;
    /// @dev Exact amount the taker must supply: grossInputAmount + inputFeeAmount.
    uint256 totalInputAmount;
    /// @dev Token received by the taker.
    address outputToken;
    /// @dev Taker output before any taker fee deducted from the output.
    uint256 grossOutputAmount;
    /// @dev Taker fee deducted from grossOutputAmount; zero when the taker fee uses inputToken.
    uint256 outputFeeAmount;
    /// @dev Exact amount received by the taker: grossOutputAmount - outputFeeAmount.
    uint256 netOutputAmount;
    /// @dev Fee deducted from the maker's gross inputToken proceeds.
    uint256 makerFeeAmount;
}
