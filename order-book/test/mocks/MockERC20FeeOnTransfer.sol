// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20FeeOnTransfer is ERC20 {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public taxedSender;
    uint16 public transferTaxBps;

    constructor() ERC20("MockERC20FeeOnTransfer", "MFOT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setTransferTax(address taxedSender_, uint16 transferTaxBps_) external {
        taxedSender = taxedSender_;
        transferTaxBps = transferTaxBps_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0) || from != taxedSender || transferTaxBps == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxAmount = amount * transferTaxBps / BPS_DENOMINATOR;
        super._update(from, to, amount - taxAmount);
        super._update(from, address(0), taxAmount);
    }
}
