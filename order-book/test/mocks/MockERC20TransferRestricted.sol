// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20TransferRestricted is ERC20 {
    error TransfersPaused();
    error RecipientBlocked(address recipient);

    bool public transfersPaused;
    mapping(address recipient => bool blocked) public blockedRecipient;

    constructor() ERC20("MockERC20TransferRestricted", "TR20M") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setTransfersPaused(bool paused) external {
        transfersPaused = paused;
    }

    function setRecipientBlocked(address recipient, bool blocked) external {
        blockedRecipient[recipient] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (transfersPaused) revert TransfersPaused();
            if (blockedRecipient[to]) revert RecipientBlocked(to);
        }
        super._update(from, to, value);
    }
}
