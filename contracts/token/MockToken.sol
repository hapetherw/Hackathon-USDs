// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MockToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals
    ) public ERC20(name_, symbol_) {
        _setupDecimals(decimals);
        uint256 amount = 10000000000 * (10 ** uint(decimals));
         _mint(_msgSender(), amount);
    }
}
