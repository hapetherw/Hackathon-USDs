// SPDX-License-Identifier: agpl-3.0
//pragma solidity ^0.8.0;
pragma solidity ^0.6.12;

interface ICurve2Pool {
    function get_virtual_price() external view returns (uint256);

    //function add_liquidity(uint256[3] calldata _amounts, uint256 _min) external payable;
    function add_liquidity(uint256[2] calldata _amounts, uint256 _min) external;

    function balances(uint256) external view returns (uint256);

    function calc_token_amount(uint256[2] calldata _amounts, bool _deposit)
        external
        view
        returns (uint256);

    function remove_liquidity_one_coin(
        uint256 _amount,
        int128 _index,
        uint256 _minAmount,
        address _receiver
    ) external returns (uint256);

    function remove_liquidity(
        uint256 _amount,
        uint256[3] calldata _minWithdrawAmounts
    ) external;

    function calc_withdraw_one_coin(uint256 _amount, int128 _index)
        external
        view
        returns (uint256);

    function coins(uint256 _index) external view returns (address);
}
