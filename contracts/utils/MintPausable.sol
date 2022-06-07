// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/utils/Context.sol";

contract MintPausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event MintPaused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event MintUnpaused(address account);

    bool private _mintPaused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() internal {
        _mintPaused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function mintPaused() public view returns (bool) {
        return _mintPaused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenMintNotPaused() {
        require(!_mintPaused, "MintPausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenMintPaused() {
        require(_mintPaused, "MintPausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _mintPause() internal whenMintNotPaused {
        _mintPaused = true;
        emit MintPaused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _mintUnpause() internal whenMintPaused {
        _mintPaused = false;
        emit MintUnpaused(_msgSender());
    }
}
